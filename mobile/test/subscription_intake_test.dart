import 'package:flutter_test/flutter_test.dart';
import 'package:subscription_tree/bank_statements.dart';
import 'package:subscription_tree/subscription_intake.dart';

final directory = ServiceDirectory([
  SubscriptionService({
    'id': 'plus',
    'name': 'Яндекс Плюс',
    'category': 'музыка',
    'icon': 'music',
    'aliases': ['yandex plus'],
  }),
]);

StatementPayment payment(String date, String merchant, int amount) =>
    StatementPayment(
      date,
      StatementBank.sber,
      DateTime.parse('${date}T00:00:00Z'),
      merchant,
      amount,
      'RUB',
    );

void main() {
  test(
    'Recognizes known service after a price change and preserves month-end',
    () {
      final result = findStatementSubscriptions(
        [
          payment('2026-01-31', 'YANDEX*PLUS', 19900),
          payment('2026-02-28', 'YANDEX*PLUS', 19900),
          payment('2026-03-31', 'YANDEX*PLUS', 29900),
        ],
        {StatementBank.sber: DateTime.utc(2026, 4, 1)},
        directory,
      ).single;
      expect(result.name, 'Яндекс Плюс');
      expect(result.kind, CandidateKind.recognized);
      expect(result.period, 'monthly');
      expect(result.latest.kopecks, 29900);
      expect(result.draft()['bank_merchant'], 'YANDEX*PLUS');
      expect(result.predictedDate, DateTime.utc(2026, 4, 30));
    },
  );

  test(
    'Recognizes a bank notification and preserves its original descriptor',
    () {
      final draft = sharedSubscriptionDraft(
        'Покупка 399 ₽ YM*YANDEX.PLUS. Карта **1234',
        directory,
      );
      expect(draft['name'], 'Яндекс Плюс');
      expect(draft['bank_merchant'], 'YM*YANDEX.PLUS');

      final unknown = sharedSubscriptionDraft(
        'Торговая точка: PAY*MYVPN\nСумма: 300 ₽',
        directory,
      );
      expect(unknown['name'], 'PAY*MYVPN');
      expect(unknown['bank_merchant'], 'PAY*MYVPN');
      final descriptorOnly = sharedSubscriptionDraft('PAY*MYVPN', directory);
      expect(descriptorOnly['name'], 'PAY*MYVPN');
      expect(descriptorOnly['bank_merchant'], 'PAY*MYVPN');
      final explicitService = sharedSubscriptionDraft(
        'Сервис: Мой VPN\nТорговая точка: PAY*MYVPN',
        directory,
      );
      expect(explicitService['name'], 'Мой VPN');
      expect(explicitService['bank_merchant'], 'PAY*MYVPN');
    },
  );

  test('Shows daily equal payments and lists old subscriptions last', () {
    final result = findStatementSubscriptions(
      [
        payment('2026-01-31', 'YANDEX*PLUS', 19900),
        payment('2026-02-28', 'YANDEX*PLUS', 19900),
        for (final date in ['2026-05-02', '2026-05-03', '2026-05-04'])
          payment(date, 'FunPay', 20000),
        payment('2026-05-04', 'Coffee', 30000),
      ],
      {StatementBank.sber: DateTime.utc(2026, 6, 2)},
      directory,
    );
    expect(result.map((item) => item.kind), [
      CandidateKind.suspicious,
      CandidateKind.inactive,
    ]);
    expect(result.first.period, 'daily');
    expect(result.last.draft()['status'], 'paused');
  });

  test(
    'Shared text yields editable subscription fields without a guessed date',
    () {
      final draft = sharedSubscriptionDraft(
        'Яндекс Плюс\nТариф: Семейный\n399 ₽ в месяц',
        directory,
      );
      expect(draft['name'], 'Яндекс Плюс');
      expect(draft['plan_name'], 'Семейный');
      expect(draft['amount'], '399');
      expect(draft['period'], 'monthly');
      expect(draft, isNot(contains('next_charge_date')));
      expect(draft, isNot(contains('text')));
    },
  );
}
