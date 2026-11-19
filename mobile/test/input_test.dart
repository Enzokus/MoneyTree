import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:subscription_tree/api.dart';
import 'package:subscription_tree/main.dart';
import 'package:subscription_tree/input_validation.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ru'));
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
