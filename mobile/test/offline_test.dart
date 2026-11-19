import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:subscription_tree/api.dart';
import 'package:subscription_tree/bank_statements.dart';

final subscription = <String, dynamic>{
  'name': 'Music',
  'amount': '299.90',
  'currency': 'RUB',
  'period': 'monthly',
  'next_charge_date': '2099-01-31',
  'status': 'active',
  'timezone': 'Europe/Moscow',
};
String access(String user) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({'sub': user})))}.signature';
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('Progress and overlapping statement rows persist locally without network payloads', () async {
    FlutterSecureStorage.setMockInitialValues({
      'access': access('alice'),
      'refresh': 'refresh',
    });
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      throw http.ClientException('offline');
    });
    final api = ApiClient(client: client);
    await api.init();
    await settle();
    final payment = StatementPayment(
      'test-row',
      StatementBank.sber,
      DateTime.utc(2026, 4, 15),
      'Test',
      100,
      'RUB',
    );
    await api.addStatement(
      BankStatement(StatementBank.sber, DateTime.utc(2026, 4, 16), 'pdf-1', [
        payment,
      ]),
    );
    await api.addStatement(
      BankStatement(StatementBank.sber, DateTime.utc(2026, 4, 17), 'pdf-2', [
        payment,
      ]),
    );
    await api.addStatement(
      BankStatement(StatementBank.sber, DateTime.utc(2026, 4, 12), 'old', []),
    );
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    api.dispose();

    final restored = ApiClient(
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    addTearDown(restored.dispose);
    await restored.init();
    expect(restored.importedStatement('pdf-1'), isTrue);
    expect(restored.statementPayments.single.key, payment.key);
    expect(
      restored.statementDates[StatementBank.sber],
      DateTime.utc(2026, 4, 17),
    );
  });

  test(
    'First launch needs sign-in, even with data from an old guest session',
    () async {
      SharedPreferences.setMockInitialValues({
        'local_mode': true,
        'offline_guest_v1': jsonEncode({
          'subscriptions': [subscription],
        }),
      });
      final api = ApiClient(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      addTearDown(api.dispose);
      await api.init();
      expect(api.canOpen, isFalse);
      expect(api.subscriptions, isEmpty);
      await expectLater(
        api.loginWithPassword('+79870000001', 'password'),
        throwsA(isA<ApiException>()),
      );
      expect(api.canOpen, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('offline_guest_v1'), isNotNull);
    },
  );

  test(
    'Account edits survive restart and synchronize when server returns',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'access': access('alice'),
        'refresh': 'refresh',
      });
      final api = ApiClient(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      await api.init();
      await settle();
      await api.saveSubscription(subscription);
      await settle();
      final id = api.subscriptions.single['id'];
      expect(api.pendingCount, 1);
      api.dispose();
      final server = <String, Map<String, dynamic>>{};
      final restored = ApiClient(
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/subscriptions') {
            final value = Map<String, dynamic>.from(jsonDecode(request.body));
            server[value['id']] = value;
            return http.Response(jsonEncode(value), 201);
          }
          if (request.url.path == '/me') {
            return http.Response('{"id":"alice"}', 200);
          }
          if (request.url.path == '/subscriptions') {
            return http.Response(jsonEncode(server.values.toList()), 200);
          }
          return http.Response('[]', 200);
        }),
      );
      addTearDown(restored.dispose);
      await restored.init();
      expect(restored.subscriptions.single['id'], id);
      await settle();
      await restored.reload();
      expect(restored.pendingCount, 0);
      expect(server.keys, [id]);
      expect(restored.offline, isFalse);
    },
  );

  test(
    'Refresh network failure preserves account, cache and pending edits',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'access': access('alice'),
        'refresh': 'refresh',
      });
      final api = ApiClient(
        client: MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            throw http.ClientException('offline');
          }
          return http.Response('{}', 401);
        }),
      );
      addTearDown(api.dispose);
      await api.init();
      await settle();
      await api.saveSubscription(subscription);
      await settle();
      expect(api.signedIn, isTrue);
      expect(api.subscriptions, hasLength(1));
      expect(api.pendingCount, 1);
      expect(api.offline, isTrue);
      await expectLater(api.logout(), throwsA(isA<ApiException>()));
    },
  );

  test('Account deletion clears local data only after server confirmation', () async {
    FlutterSecureStorage.setMockInitialValues({
      'access': access('alice'),
      'refresh': 'refresh',
    });
    var acceptDeletion = false;
    final api = ApiClient(
      client: MockClient((request) async {
        if (request.method == 'DELETE' && request.url.path == '/me') {
          expect(request.headers['authorization'], 'Bearer ${access('alice')}');
          if (acceptDeletion) return http.Response('{"ok":true}', 200);
        }
        throw http.ClientException('offline');
      }),
    );
    addTearDown(api.dispose);
    await api.init();
    await api.reload();
    await api.saveSubscription(subscription);
    await api.reload();

    await expectLater(api.deleteAccount(), throwsA(isA<ApiException>()));
    expect(api.signedIn, isTrue);
    expect(api.pendingCount, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('offline_account_v1_alice'), isNotNull);

    acceptDeletion = true;
    await api.deleteAccount();
    expect(api.signedIn, isFalse);
    expect(api.subscriptions, isEmpty);
    expect(api.pendingCount, 0);
    expect(prefs.getString('offline_account_v1_alice'), isNull);
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'access'), isNull);
    expect(await storage.read(key: 'refresh'), isNull);
  });

  test(
    'Reauthentication preserves the queue and requires the same account',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'access': access('alice'),
        'refresh': 'expired',
      });
      var acceptedUser = 'bob';
      var authenticated = false;
      final sent = <dynamic>[];
      final api = ApiClient(
        client: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            expect(jsonDecode(request.body), {
              'identifier': '+79870000001',
              'password': 'password',
            });
            authenticated = acceptedUser == 'alice';
            return http.Response(
              jsonEncode({
                'access_token': access(acceptedUser),
                'refresh_token': 'renewed',
              }),
              200,
            );
          }
          if (!authenticated) return http.Response('{}', 401);
          if (request.url.path == '/subscriptions' &&
              request.method == 'POST') {
            sent.add(jsonDecode(request.body));
          }
          if (request.url.path == '/me') return http.Response('{}', 200);
          return http.Response(jsonEncode(sent), 200);
        }),
      );
      addTearDown(api.dispose);
      await api.init();
      await settle();
      expect(api.needsSignIn, isTrue);
      await api.saveSubscription(subscription);
      expect(api.pendingCount, 1);
      await expectLater(
        api.loginWithPassword('+79870000001', 'password'),
        throwsA(isA<ApiException>()),
      );
      expect(api.pendingCount, 1);
      expect(sent, isEmpty);
      acceptedUser = 'alice';
      await api.loginWithPassword('+79870000001', 'password');
      expect(api.needsSignIn, isFalse);
      expect(api.pendingCount, 0);
      expect(sent.single['name'], 'Music');
    },
  );
}
