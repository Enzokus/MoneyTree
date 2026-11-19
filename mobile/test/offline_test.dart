import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:subscription_tree/api.dart';

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

  test(
    'Local first launch, edits, reminders and restart need no server',
    () async {
      var requests = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          requests++;
          throw http.ClientException('offline');
        }),
      );
      await api.init();
      await api.enterLocalMode();
      await api.saveSubscription(subscription);
      final id = api.subscriptions.single['id'] as String;
      await api.saveSubscription({...subscription, 'name': 'Updated'}, id: id);
      await api.saveReminders({
        'hour': 9,
        'minute': 15,
        'days_before': [1],
      });
      expect(api.pendingCount, 0);
      api.dispose();
      final restored = ApiClient();
      addTearDown(restored.dispose);
      await restored.init();
      expect(restored.canOpen, isTrue);
      expect(restored.localOnly, isTrue);
      expect(restored.subscriptions.single['name'], 'Updated');
      expect(restored.profile!['reminders']['hour'], 9);
      await restored.removeSubscription(id);
      expect(restored.subscriptions, isEmpty);
      expect(requests, 0);
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

  test('Guest data remains separate from account data', () async {
    final guest = ApiClient();
    await guest.init();
    await guest.enterLocalMode();
    await guest.saveSubscription(subscription);
    await guest.logout();
    guest.dispose();
    FlutterSecureStorage.setMockInitialValues({
      'access': access('bob'),
      'refresh': 'refresh',
    });
    final account = ApiClient(
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    addTearDown(account.dispose);
    await account.init();
    expect(account.subscriptions, isEmpty);
    await settle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('offline_guest_v1'), isNotNull);
  });
}
