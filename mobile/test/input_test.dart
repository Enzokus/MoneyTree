import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:subscription_tree/api.dart';
import 'package:subscription_tree/main.dart';
import 'package:subscription_tree/input_validation.dart';

class RegistrationTestApi extends ApiClient {
  String? identifier;
  List<String>? confirmation;

  @override
  Future<String> requestRegistrationCode(String identifier) async {
    this.identifier = identifier;
    return 'challenge-id';
  }

  @override
  Future<void> completeRegistration(
    String challengeId,
    String code,
    String password,
  ) async {
    confirmation = [challengeId, code, password];
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('ru'));

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
      'Registration confirms ${byPhone ? 'phone' : 'email'} by code',
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
        await tester.tap(find.text('Получить код'));
        await tester.pumpAndSettle();
        expect(api.identifier, byPhone ? '+79121234567' : 'user@example.org');
        expect(contact, findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('registration-code')),
          '012345',
        );
        await tester.tap(find.text('Подтвердить и войти'));
        await tester.pumpAndSettle();
        expect(api.confirmation, [
          'challenge-id',
          '012345',
          'Good test password',
        ]);
      },
    );
  }

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
