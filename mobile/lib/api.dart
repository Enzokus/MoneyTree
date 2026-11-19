import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'reminders.dart';
import 'bank_statements.dart';
import 'subscription_intake.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000',
);
const yandexClientId = String.fromEnvironment('YANDEX_CLIENT_ID');
const yandexRedirectUri = String.fromEnvironment(
  'YANDEX_REDIRECT_URI',
  defaultValue: 'subscriptiontree://oauth',
);

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class ApiClient extends ChangeNotifier {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  final _storage = const FlutterSecureStorage();
  Timer? _retryTimer;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool _reloading = false;
  bool _authenticating = false;
  Future<void>? _refreshing;
  String get _deviceTimezone {
    try {
      return tz.local.name;
    } catch (_) {
      return "UTC";
    }
  }

  Future<void> _renewTokens() => _refreshing ??= _performRefresh();
  Future<void> _performRefresh() async {
    try {
      final tokens = await _rawPost("/auth/refresh", {
        "refresh_token": _refresh,
      });
      await _setTokens(tokens);
    } finally {
      _refreshing = null;
    }
  }

  int _revision = 0;
  List<Map<String, dynamic>> _pending = [];
  Map<StatementBank, DateTime> _statementDates = {};
  Map<String, StatementPayment> _statementPayments = {};
  Set<String> _statementFiles = {};

  Map<StatementBank, DateTime> get statementDates =>
      Map.unmodifiable(_statementDates);
  Iterable<StatementPayment> get statementPayments => _statementPayments.values;
  bool importedStatement(String fingerprint) =>
      _statementFiles.contains(fingerprint);

  ServiceDirectory get services => ServiceDirectory(
    _rows(profile?['services'] ?? []).map(SubscriptionService.new).toList(),
  );

  Future<void> addStatement(BankStatement statement) async {
    if (importedStatement(statement.fingerprint)) return;
    final oldDate = _statementDates[statement.bank];
    final dates = {
      ..._statementDates,
      if (oldDate == null || statement.coveredThrough.isAfter(oldDate))
        statement.bank: statement.coveredThrough,
    };
    final payments = {..._statementPayments};
    for (final payment in statement.payments) {
      payments.putIfAbsent(payment.key, () => payment);
    }
    payments.removeWhere(
      (_, p) => dates[p.bank]!.difference(p.date).inDays > 550,
    );
    final files = {..._statementFiles, statement.fingerprint};
    if (files.length > 128) files.remove(files.first);
    final previousDates = _statementDates;
    final previousPayments = _statementPayments;
    final previousFiles = _statementFiles;
    _statementDates = dates;
    _statementPayments = payments;
    _statementFiles = files;
    try {
      await _persist();
    } catch (_) {
      _statementDates = previousDates;
      _statementPayments = previousPayments;
      _statementFiles = previousFiles;
      rethrow;
    }
    notifyListeners();
  }

  String? _accountId(String? token) {
    try {
      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(token!.split('.')[1])),
        ),
      );
      return payload['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  String get _cacheKey {
    final id = _accountId(_access);
    return id == null ? 'offline_account_v1' : 'offline_account_v1_$id';
  }

  bool get canOpen => signedIn;
  int get pendingCount => _pending.length;

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  List<Map<String, dynamic>> _rows(dynamic value) =>
      (value as List).map((e) => Map<String, dynamic>.from(e)).toList();

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(
      _cacheKey,
      jsonEncode({
        'subscriptions': subscriptions,
        'catalog': catalog,
        'recommendations': recommendations,
        'profile': profile,
        'pending': _pending,
        'statement_dates': {
          for (final entry in _statementDates.entries)
            entry.key.name: isoDay(entry.value),
        },
        'statement_payments': _statementPayments.values
            .map((p) => p.toJson())
            .toList(),
        'statement_files': _statementFiles.toList(),
      }),
    );
    if (!ok) {
      throw const ApiException('Не удалось сохранить данные на телефоне');
    }
  }

  Future<void> _restore({bool migrateLegacy = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null) {
      final legacy = migrateLegacy ? prefs.getString('subscriptions') : null;
      subscriptions = legacy == null ? [] : _rows(jsonDecode(legacy));
      catalog = [];
      recommendations = [];
      profile = null;
      _pending = [];
      _statementDates = {};
      _statementPayments = {};
      _statementFiles = {};
      return;
    }
    final data = jsonDecode(raw) as Map<String, dynamic>;
    subscriptions = _rows(data['subscriptions'] ?? []);
    catalog = _rows(data['catalog'] ?? []);
    recommendations = _rows(data['recommendations'] ?? []);
    profile = data['profile'] == null
        ? null
        : Map<String, dynamic>.from(data['profile']);
    _pending = _rows(data['pending'] ?? []);
    _statementDates = {
      for (final entry in (data['statement_dates'] as Map? ?? {}).entries)
        StatementBank.values.byName(entry.key as String): calendarDay(
          DateTime.parse(entry.value as String),
        ),
    };
    _statementPayments = {
      for (final payment in (data['statement_payments'] as List? ?? []).map(
        (p) => StatementPayment.fromJson(p as List),
      ))
        payment.key: payment,
    };
    _statementFiles = Set<String>.from(data['statement_files'] as List? ?? []);
  }

  Future<void> _syncReminders() async {
    try {
      await ReminderService.instance.sync(subscriptions, profile);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _client.close();
    super.dispose();
  }

  String? _access;
  String? _refresh;
  List<Map<String, dynamic>> subscriptions = [];
  List<Map<String, dynamic>> recommendations = [];
  List<Map<String, dynamic>> catalog = [];
  Map<String, dynamic>? profile;
  bool loading = true;
  bool offline = false;
  bool needsSignIn = false;

  bool get signedIn => _refresh != null;

  Future<void> init() async {
    _access = await _storage.read(key: 'access');
    _refresh = await _storage.read(key: 'refresh');
    if (signedIn) await _restore(migrateLegacy: true);
    offline = signedIn;
    loading = false;
    await _syncReminders();
    notifyListeners();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (signedIn) unawaited(reload());
    });
    if (signedIn) unawaited(reload());
  }

  Future<void> loginWithPassword(String identifier, String password) => _signIn(
    () => _rawPost('/auth/login', {
      'identifier': identifier,
      'password': password,
    }),
  );

  Future<String> requestRegistrationCode(String identifier) async {
    final response = await _rawPost('/auth/register/start', {
      'identifier': identifier,
    }, timeout: const Duration(seconds: 30));
    return response['challenge_id'] as String;
  }

  Future<void> completeRegistration(
    String challengeId,
    String code,
    String password,
  ) => _signIn(
    () => _rawPost('/auth/register/complete', {
      'challenge_id': challengeId,
      'code': code,
      'password': password,
    }),
  );

  Future<void> loginYandex() => _signIn(_authenticateYandex);

  Future<void> _signIn(
    Future<Map<String, dynamic>> Function() authenticate,
  ) async {
    if (_reloading || _authenticating) {
      throw const ApiException('Дождитесь завершения синхронизации или входа.');
    }
    _authenticating = true;
    try {
      final tokens = await authenticate();
      final accountId = _accountId(tokens['access_token'] as String);
      if (accountId == null) {
        throw const ApiException('Сервер вернул некорректную сессию');
      }
      final wasSignedIn = signedIn;
      if (wasSignedIn && _accountId(_access) != accountId) {
        throw const ApiException(
          'Войдите в текущий аккаунт для продолжения синхронизации',
        );
      }
      await _setTokens(tokens);
      if (!wasSignedIn) await _restore();
      needsSignIn = false;
    } finally {
      _authenticating = false;
      notifyListeners();
    }
    await reload();
  }

  Future<Map<String, dynamic>> _authenticateYandex() async {
    if (yandexClientId.isEmpty) {
      throw const ApiException('Не задан YANDEX_CLIENT_ID');
    }
    final random = Random.secure();
    final verifier = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final state = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final uri = Uri.https('oauth.yandex.ru', '/authorize', {
      'response_type': 'code',
      'client_id': yandexClientId,
      'redirect_uri': yandexRedirectUri,
      'scope': 'login:info login:email',
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    final result = await FlutterWebAuth2.authenticate(
      url: uri.toString(),
      callbackUrlScheme: 'subscriptiontree',
    );
    final callback = Uri.parse(result);
    if (callback.queryParameters['state'] != state ||
        callback.queryParameters['code'] == null) {
      throw const ApiException('Вход не завершён');
    }
    return _rawPost('/auth/yandex/exchange', {
      'code': callback.queryParameters['code'],
      'code_verifier': verifier,
      'redirect_uri': yandexRedirectUri,
    });
  }

  Future<void> _setTokens(Map<String, dynamic> tokens) async {
    _access = tokens['access_token'] as String;
    _refresh = tokens['refresh_token'] as String;
    await _storage.write(key: 'access', value: _access);
    await _storage.write(key: 'refresh', value: _refresh);
    if (!_authenticating) notifyListeners();
  }

  Future<http.Response> _request(
    String method,
    String path, [
    Object? body,
    bool retry = true,
  ]) async {
    if (!signedIn) {
      throw const ApiException(
        'Эта функция требует входа и подключения к серверу.',
      );
    }
    final uri = Uri.parse('$apiBaseUrl$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_access != null) 'Authorization': 'Bearer $_access',
    };
    final encoded = body == null ? null : jsonEncode(body);
    late http.Response response;
    try {
      switch (method) {
        case 'GET':
          response = await _client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 10));
        case 'POST':
          response = await _client
              .post(uri, headers: headers, body: encoded)
              .timeout(const Duration(seconds: 10));
        case 'PUT':
          response = await _client
              .put(uri, headers: headers, body: encoded)
              .timeout(const Duration(seconds: 10));
        case 'DELETE':
          response = await _client
              .delete(uri, headers: headers)
              .timeout(const Duration(seconds: 10));
        default:
          throw const ApiException('Unknown method');
      }
    } catch (_) {
      throw const ApiException('Сервер недоступен');
    }
    if (response.statusCode == 401 && retry && _refresh != null) {
      try {
        await _renewTokens();
        return await _request(method, path, body, false);
      } on ApiException catch (error) {
        // A network outage must not erase the session or offline edits.
        if (error.statusCode == 401) {
          needsSignIn = true;
          throw const ApiException(
            'Сессия истекла. Войдите снова. Локальные данные сохранены.',
          );
        }
        rethrow;
      }
    }
    if (response.statusCode >= 400) {
      throw ApiException(
        'Ошибка ${response.statusCode}: ${utf8.decode(response.bodyBytes)}',
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  Future<Map<String, dynamic>> _rawPost(
    String path,
    Object body, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$apiBaseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode >= 400) {
        if (path.startsWith('/auth/register/')) {
          final message = switch (response.statusCode) {
            400 => 'Код неверный или больше не действует',
            409 => 'Этот телефон или почта уже зарегистрированы',
            422 => 'Проверьте данные для регистрации',
            429 => 'Слишком много запросов. Попробуйте позже',
            502 => 'Не удалось отправить код. Попробуйте ещё раз',
            503 => 'Отправка кодов этим способом пока недоступна',
            _ => 'Ошибка регистрации: ${response.statusCode}',
          };
          throw ApiException(message, statusCode: response.statusCode);
        }
        throw ApiException(
          response.statusCode == 401 && path == '/auth/login'
              ? 'Неверный телефон, почта или пароль'
              : 'Ошибка входа: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('Сервер недоступен');
    }
  }

  Future<dynamic> get(String path) async =>
      jsonDecode(utf8.decode((await _request('GET', path)).bodyBytes));
  Future<dynamic> post(String path, Object body) async =>
      jsonDecode(utf8.decode((await _request('POST', path, body)).bodyBytes));
  Future<dynamic> put(String path, Object body) async =>
      jsonDecode(utf8.decode((await _request('PUT', path, body)).bodyBytes));
  Future<void> delete(String path) async => _request('DELETE', path);

  Future<void> reload() async {
    if (!signedIn || needsSignIn || _reloading || _authenticating) return;
    _reloading = true;
    try {
      for (final op in List<Map<String, dynamic>>.from(_pending)) {
        if (!_pending.contains(op)) continue;
        if (op['kind'] == 'save') {
          if (op['create'] == true) {
            final saved = await post('/subscriptions', {
              ...Map<String, dynamic>.from(op['value']),
              'id': op['id'],
            });
            if (saved is Map &&
                saved['id'] != null &&
                saved['id'] != op['id']) {
              _pending.removeWhere((item) => item['id'] == op['id']);
              subscriptions = [
                ...subscriptions.where(
                  (s) => s['id'] != op['id'] && s['id'] != saved['id'],
                ),
                Map<String, dynamic>.from(saved),
              ];
            }
          } else {
            try {
              await put('/subscriptions/${op['id']}', op['value']);
            } on ApiException catch (error) {
              if (error.statusCode != 409) rethrow;
              final serverRows = _rows(await get('/subscriptions'));
              subscriptions = [
                ...subscriptions.where((s) => s['id'] != op['id']),
                ...serverRows.where((s) => s['id'] == op['id']),
              ];
            }
          }
        } else if (op['kind'] == 'delete') {
          try {
            await delete('/subscriptions/${op['id']}');
          } on ApiException catch (error) {
            if (error.statusCode != 404) rethrow;
          }
        } else if (op['kind'] == 'reminders') {
          await put('/me/reminders', op['value']);
        }
        _pending.removeWhere((item) => item['operation'] == op['operation']);
        await _persist();
      }
      final revision = _revision;
      final results = await Future.wait([
        get('/me'),
        get(
          '/subscriptions?timezone=${Uri.encodeQueryComponent(_deviceTimezone)}',
        ),
        get('/recommendations'),
        get('/catalog'),
      ]);
      // Do not overwrite changes made while requests were in flight.
      if (_revision == revision && _pending.isEmpty) {
        profile = Map<String, dynamic>.from(results[0]);
        subscriptions = _rows(results[1]);
        recommendations = _rows(results[2]);
        catalog = _rows(results[3]);
        await _persist();
      }
      offline = false;
      await _syncReminders();
    } catch (_) {
      offline = true;
    } finally {
      _reloading = false;
      notifyListeners();
    }
  }

  Future<void> saveSubscription(
    Map<String, dynamic> value, {
    String? id,
  }) async {
    if (_authenticating) {
      throw const ApiException('Дождитесь завершения входа.');
    }
    final key = id ?? _uuid();
    final directory = services;
    final original = subscriptions.where((s) => s['id'] == id).firstOrNull;
    if (subscriptions.any(
      (s) =>
          s['id'] != key &&
          directory.sameSubscription(s, value) &&
          (original == null || !directory.sameSubscription(s, original)),
    )) {
      throw const ApiException('Такая подписка уже есть в списке.');
    }
    final row = {
      ...value,
      'id': key,
      'source': value['source'] ?? original?['source'] ?? 'manual',
      'anchor_day':
          value['anchor_day'] ?? DateTime.parse(value['next_charge_date']).day,
    };
    subscriptions = [...subscriptions.where((s) => s['id'] != key), row];
    _pending.add({
      'operation': _uuid(),
      'kind': 'save',
      'id': key,
      'create': id == null,
      'value': value,
    });
    await _localChanged();
    try {
      await ReminderService.instance.requestPermission();
    } catch (_) {}
    await _syncReminders();
  }

  Future<void> removeSubscription(String id) async {
    if (_authenticating) {
      throw const ApiException('Дождитесь завершения входа.');
    }
    subscriptions = subscriptions.where((s) => s['id'] != id).toList();
    _pending.add({'operation': _uuid(), 'kind': 'delete', 'id': id});
    await _localChanged();
  }

  Future<void> saveReminders(Map<String, dynamic> settings) async {
    if (_authenticating) {
      throw const ApiException('Дождитесь завершения входа.');
    }
    profile = {...?profile, 'reminders': settings};
    _pending.add({
      'operation': _uuid(),
      'kind': 'reminders',
      'value': settings,
    });
    await _localChanged();
  }

  Future<void> _localChanged() async {
    _revision++;
    recommendations = [];
    await _persist();
    await _syncReminders();
    notifyListeners();
    unawaited(reload());
  }

  Future<void> logout() async {
    if (_reloading || _authenticating || _pending.isNotEmpty) {
      throw const ApiException(
        'Дождитесь синхронизации изменений перед выходом.',
      );
    }
    if (_refresh != null) {
      try {
        await post('/auth/logout', {'refresh_token': _refresh});
      } catch (_) {}
    }
    if (_pending.isNotEmpty) {
      throw const ApiException(
        'Есть несинхронизированные изменения. Подключитесь к серверу перед выходом.',
      );
    }
    await clearSession();
  }

  Future<void> clearSession() async {
    final previousKey = _cacheKey;
    needsSignIn = false;
    offline = false;
    _access = null;
    _refresh = null;
    profile = null;
    subscriptions = [];
    recommendations = [];
    catalog = [];
    _pending = [];
    _statementDates = {};
    _statementPayments = {};
    _statementFiles = {};
    await _storage.delete(key: 'access');
    await _storage.delete(key: 'refresh');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('subscriptions');
    await prefs.remove(previousKey);
    try {
      await ReminderService.instance.plugin.cancelAll();
    } catch (_) {}
    notifyListeners();
  }
}
