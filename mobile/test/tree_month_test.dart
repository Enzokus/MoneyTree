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
