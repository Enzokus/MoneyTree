import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:subscription_tree/api.dart';
import 'package:subscription_tree/main.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Map<String, dynamic> subscription(
  String name,
  DateTime date, {
  String status = 'active',
  String amount = '100',
  String currency = 'RUB',
}) => {
  'name': name,
  'next_charge_date': date.toIso8601String().split('T').first,
  'status': status,
  'period': 'monthly',
  'amount': amount,
  'currency': currency,
};

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await initializeDateFormatting('ru');
  });

  testWidgets(
    'Shows the original descriptor and clears the fallback on focus',
    (tester) async {
      final api = ApiClient();
      addTearDown(api.dispose);
      Future<void> open(String title) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionForm(
              key: ValueKey(title),
              api: api,
              draft: {'name': title, 'bank_merchant': 'BANK*STREAM'},
            ),
          ),
        ),
      );
      await open('Стриминг');
      expect(find.text('Стриминг'), findsOneWidget);
      expect(find.text('BANK*STREAM'), findsOneWidget);

      await open('BANK*STREAM');
      final field = find.byType(TextField).first;
      TextField input() => tester.widget<TextField>(field);
      expect(input().decoration!.hintText, 'BANK*STREAM');
      expect(input().controller!.text, isEmpty);
      await tester.tap(field);
      await tester.pump();
      expect(input().focusNode!.hasFocus, isTrue);
      expect(input().decoration!.hintText, isNull);
      expect(input().controller!.text, isEmpty);
      await tester.enterText(field, 'Мой сервис');
      await tester.pump();
      expect(find.text('Мой сервис'), findsOneWidget);
      expect(find.text('BANK*STREAM'), findsOneWidget);
    },
  );

  test('Includes today and the last day in 28, 29, 30 and 31 day months', () {
    for (final now in [
      DateTime(2026, 2, 14),
      DateTime(2028, 2, 14),
      DateTime(2026, 4, 14),
      DateTime(2026, 12, 14),
    ]) {
      final last = DateTime(now.year, now.month + 1, 0);
      final rows = subscriptionsThisMonth([
        subscription('Next month', DateTime(now.year, now.month + 1, 1)),
        subscription('Last day', last),
        subscription('Paused', now, status: 'paused'),
        subscription('Cancelled', now, status: 'cancelled'),
        subscription('Today', now),
        subscription('Already charged', DateTime(now.year, now.month, 1)),
      ], now: now);
      expect(rows.map((s) => s['name']), ['Today', 'Last day']);
    }
  });

  test('Rolls cached dates forward and preserves the month-end anchor', () {
    final row = subscription('Month end', DateTime(2028, 1, 31));
    row['anchor_day'] = 31;
    expect(chargeDate(row, now: DateTime(2028, 2, 10)), DateTime(2028, 2, 29));
    expect(subscriptionsThisMonth([row], now: DateTime(2028, 2, 10)), [row]);
  });

  testWidgets('Subscriptions combine status and text search in Russian', (
    tester,
  ) async {
    final api = ApiClient();
    addTearDown(api.dispose);
    api.subscriptions = [
      subscription('Музыка', DateTime.now(), status: 'paused'),
      subscription('Видео', DateTime.now(), status: 'paused'),
      subscription('Музыка 2', DateTime.now(), status: 'cancelled'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SubscriptionsPage(api: api)),
      ),
    );
    expect(find.textContaining('paused'), findsNothing);
    expect(find.textContaining('Отменена'), findsOneWidget);
    await tester.tap(find.text('Все'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Приостановленные').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'музыка');
    await tester.pumpAndSettle();
    expect(find.text('Музыка'), findsOneWidget);
    expect(find.text('Видео'), findsNothing);
    expect(find.text('Музыка 2'), findsNothing);
  });

  testWidgets('Tree totals and lists the same subscriptions in date order', (
    tester,
  ) async {
    final now = tz.TZDateTime.now(tz.local);
    final last = DateTime(now.year, now.month + 1, 0);
    final api = ApiClient();
    api.subscriptions = [
      subscription('Last day', last, amount: '250'),
      subscription(
        'Outside month',
        DateTime(now.year, now.month + 1, 1),
        amount: '999',
      ),
      subscription('Today', now, amount: '100'),
      subscription('Paused', now, status: 'paused', amount: '999'),
      subscription('Foreign currency', last, currency: 'USD'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TreePage(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('До конца месяца'), findsOneWidget);
    expect(find.text('350.00 ₽'), findsOneWidget);
    expect(find.text('3 подписок'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final tiles = tester.widgetList<SubscriptionTile>(
      find.byType(SubscriptionTile),
    );
    expect(tiles.map((tile) => tile.data['name']), [
      'Today',
      'Last day',
      'Foreign currency',
    ]);
    expect(find.text('Outside month'), findsNothing);
    expect(find.text('Paused'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dispose();
  });
}
