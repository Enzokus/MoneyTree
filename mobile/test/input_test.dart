import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:subscription_tree/api.dart';
import 'package:subscription_tree/main.dart';
import 'package:subscription_tree/input_validation.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

class RegistrationTestApi extends ApiClient {
  List<String>? credentials;

  @override
  Future<void> register(String identifier, String password) async {
    credentials = [identifier, password];
  }
}

class AccountMenuTestApi extends ApiClient {
  int deletions = 0;
  int logouts = 0;

  @override
  Future<void> deleteAccount() async {
    deletions++;
  }

  @override
  Future<void> logout() async {
    logouts++;
  }
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  testWidgets('Login displays the Russian prefix and offers email', (
    tester,
  ) async {
    final api = ApiClient();
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: api)));
    final phone = find.byKey(const ValueKey('login-phone'));
    await tester.tap(phone);
    await tester.pumpAndSettle();
    expect(find.text('9870000001'), findsNothing);
    await tester.enterText(phone, '987');
    await tester.pumpAndSettle();
    expect(find.text('+7 '), findsOneWidget);
    expect(find.text('987'), findsOneWidget);
    for (final number in ['8 (987) 000-00-01', '+7 (987) 000-00-01']) {
      await tester.enterText(phone, number);
      expect(
        tester.widget<TextFormField>(phone).controller!.text,
        '9870000001',
      );
    }
    final yandex = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Войти через Яндекс ID'),
    );
    expect(yandex.onPressed, isNull);
    expect(find.text('Продолжить без интернета'), findsNothing);
    await tester.tap(find.text('Почта'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-email')), findsOneWidget);
    expect(phone, findsNothing);
  });

  for (final byPhone in [true, false]) {
    testWidgets(
      'Registration accepts ${byPhone ? 'phone' : 'email'} and a password',
      (tester) async {
        final api = RegistrationTestApi();
        addTearDown(api.dispose);
        await tester.pumpWidget(MaterialApp(home: LoginPage(api: api)));
        await tester.tap(find.text('Создать аккаунт'));
        await tester.pumpAndSettle();
        if (!byPhone) {
          await tester.tap(find.text('Почта'));
          await tester.pumpAndSettle();
        }
        final contact = find.byKey(
          ValueKey(byPhone ? 'login-phone' : 'login-email'),
        );
        await tester.enterText(
          contact,
          byPhone ? '9121234567' : 'user@example.org',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Пароль'),
          'Good test password',
        );
        await tester.tap(find.text('Зарегистрироваться'));
        await tester.pumpAndSettle();
        expect(api.credentials, [
          byPhone ? '+79121234567' : 'user@example.org',
          'Good test password',
        ]);
        expect(find.byKey(const ValueKey('registration-code')), findsNothing);
      },
    );
  }

  testWidgets('Account menu displays red actions and confirms deletion', (
    tester,
  ) async {
    final api = AccountMenuTestApi();
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(home: HomePage(api: api)));
    final menu = find.byTooltip('Меню');
    final logout = find.text('Выйти из аккаунта');
    final deleteAccount = find.text('Удалить аккаунт');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(logout).style?.color, Colors.redAccent);
    expect(tester.widget<Text>(deleteAccount).style?.color, Colors.redAccent);
    await tester.tap(logout);
    await tester.pumpAndSettle();
    expect(api.logouts, 1);
    expect(api.deletions, 0);

    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(deleteAccount);
    await tester.pumpAndSettle();
    expect(find.text('Удалить аккаунт?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(api.deletions, 0);

    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(deleteAccount);
    await tester.pumpAndSettle();
    await tester.tap(deleteAccount);
    await tester.pumpAndSettle();
    expect(api.deletions, 1);
  });

  testWidgets('Russian text is accepted and letters cannot enter price', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SubscriptionForm(api: ApiClient())),
      ),
    );
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Яндекс Плюс ё');
    expect(find.text('Яндекс Плюс ё'), findsOneWidget);
    await tester.enterText(fields.at(3), '299,90');
    expect(find.text('299,90'), findsOneWidget);
    await tester.enterText(fields.at(3), 'слово');
    expect(find.text('299,90'), findsOneWidget);
    expect(find.text('Часовой пояс'), findsNothing);
  });

  test('Prices reject invalid values and accept both decimal separators', () {
    for (final price in ['0', '299,90', '299.90']) {
      expect(validatePrice(price), isNull);
    }
    for (final price in ['', 'NaN', 'Infinity', '-1', '1.234', 'цена']) {
      expect(validatePrice(price), isNotNull);
    }
  });
}
