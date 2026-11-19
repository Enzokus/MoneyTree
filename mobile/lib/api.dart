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

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000',
);
const yandexClientId = String.fromEnvironment('YANDEX_CLIENT_ID');
const yandexRedirectUri = String.fromEnvironment(
  'YANDEX_REDIRECT_URI',
  defaultValue: 'subscriptiontree://oauth',
);
const devAuth = bool.fromEnvironment('DEV_AUTH');

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
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

  bool localOnly = false;
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
  String get _cacheKey {
    if (localOnly) return 'offline_guest_v1';
    try {
      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(_access!.split('.')[1])),
        ),
      );
      return 'offline_account_v1_${payload['sub']}';
    } catch (_) {
      return 'offline_account_v1';
    }
  }

  bool get canOpen => signedIn || localOnly;
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
      final legacy = localOnly || !migrateLegacy
          ? null
          : prefs.getString('subscriptions');
      subscriptions = legacy == null ? [] : _rows(jsonDecode(legacy));
      catalog = [];
      recommendations = [];
      profile = null;
      _pending = [];
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
  }

  Future<void> enterLocalMode() async {
    localOnly = true;
    offline = true;
    await _restore();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('local_mode', true);
    await _syncReminders();
    notifyListeners();
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

  bool get signedIn => _refresh != null;

  Future<void> init() async {
    _access = await _storage.read(key: 'access');
    _refresh = await _storage.read(key: 'refresh');
    final prefs = await SharedPreferences.getInstance();
    localOnly = !signedIn && (prefs.getBool('local_mode') ?? false);
    await _restore(migrateLegacy: signedIn);
    offline = true;
    loading = false;
    await _syncReminders();
    notifyListeners();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (signedIn && !localOnly) unawaited(reload());
    });
    if (signedIn) unawaited(reload());
  }

  Future<void> loginYandex() async {
    if (_reloading || _authenticating) {
      throw const ApiException('Дождитесь завершения синхронизации или входа.');
    }
    _authenticating = true;
    try {
      await _authenticateYandex();
    } finally {
      _authenticating = false;
      notifyListeners();
    }
    await reload();
  }

  Future<void> _authenticateYandex() async {
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
    final tokens = await _rawPost('/auth/yandex/exchange', {
      'code': callback.queryParameters['code'],
      'code_verifier': verifier,
      'redirect_uri': yandexRedirectUri,
    });
    localOnly = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('local_mode', false);
    await _setTokens(tokens);
    await _restore();
  }

  Future<void> loginDev() async {
    if (!devAuth || !kDebugMode) {
      throw const ApiException('Тестовый вход выключен');
    }
    if (_reloading || _authenticating) {
      throw const ApiException('Дождитесь завершения синхронизации или входа.');
    }
    _authenticating = true;
    try {
      final tokens = await _rawPost('/auth/dev', {});
      localOnly = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('local_mode', false);
      await _setTokens(tokens);
      await _restore();
    } finally {
      _authenticating = false;
      notifyListeners();
    }
    await reload();
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
    if (localOnly) {
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
        if (error.message == 'Ошибка входа: 401') {
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
      );
    }
    return response;
  }

  Future<Map<String, dynamic>> _rawPost(String path, Object body) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$apiBaseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode >= 400) {
        throw ApiException('Ошибка входа: ${response.statusCode}');
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
    if (localOnly || !signedIn || _reloading || _authenticating) return;
    _reloading = true;
    try {
      for (final op in List<Map<String, dynamic>>.from(_pending)) {
        if (op['kind'] == 'save') {
          if (op['create'] == true) {
            await post('/subscriptions', {
              ...Map<String, dynamic>.from(op['value']),
              'id': op['id'],
            });
          } else {
            await put('/subscriptions/${op['id']}', op['value']);
          }
        } else if (op['kind'] == 'delete') {
          try {
            await delete('/subscriptions/${op['id']}');
          } on ApiException catch (error) {
            if (!error.message.startsWith('Ошибка 404:')) rethrow;
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
    final row = {
      ...value,
      'id': key,
      'source': 'manual',
      'anchor_day':
          value['anchor_day'] ?? DateTime.parse(value['next_charge_date']).day,
    };
    subscriptions = [...subscriptions.where((s) => s['id'] != key), row];
    if (!localOnly) {
      _pending.add({
        'operation': _uuid(),
        'kind': 'save',
        'id': key,
        'create': id == null,
        'value': value,
      });
    }
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
    if (!localOnly) {
      _pending.add({'operation': _uuid(), 'kind': 'delete', 'id': id});
    }
    await _localChanged();
  }

  Future<void> saveReminders(Map<String, dynamic> settings) async {
    if (_authenticating) {
      throw const ApiException('Дождитесь завершения входа.');
    }
    profile = {...?profile, 'reminders': settings};
    if (!localOnly) {
      _pending.add({
        'operation': _uuid(),
        'kind': 'reminders',
        'value': settings,
      });
    }
    await _localChanged();
  }

  Future<void> _localChanged() async {
    _revision++;
    recommendations = [];
    await _persist();
    await _syncReminders();
    notifyListeners();
    if (!localOnly) unawaited(reload());
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
    final wasLocal = localOnly;
    final previousKey = _cacheKey;
    localOnly = false;
    _access = null;
    _refresh = null;
    profile = null;
    subscriptions = [];
    recommendations = [];
    catalog = [];
    _pending = [];
    await _storage.delete(key: 'access');
    await _storage.delete(key: 'refresh');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('local_mode', false);
    if (!wasLocal) {
      await prefs.remove('subscriptions');
      await prefs.remove(previousKey);
    }
    try {
      await ReminderService.instance.plugin.cancelAll();
    } catch (_) {}
    notifyListeners();
  }
}
