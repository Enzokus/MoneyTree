import 'dart:math' as math;

final _nameWords = RegExp(r'[a-zа-яё0-9]+', caseSensitive: false);

String normalizedService(String? value) => _nameWords
    .allMatches((value ?? '').toLowerCase().replaceAll('ё', 'е'))
    .map((match) => match[0]!)
    .join(' ');

String limitText(String value, int length) =>
    String.fromCharCodes(value.runes.take(length));

class SubscriptionService {
  SubscriptionService(Map<String, dynamic> row)
    : id = row['id'] as String,
      name = row['name'] as String,
      category = row['category'] as String,
      icon = row['icon'] as String,
      aliases = List<String>.from(row['aliases'] as List);

  final String id, name, category, icon;
  final List<String> aliases;
  Iterable<String> get terms => [name, ...aliases].map(normalizedService);
}

class ServiceDirectory {
  ServiceDirectory(this.services);
  final List<SubscriptionService> services;

  SubscriptionService? lookup(String? input, {bool text = false}) {
    if (text) return matchDescriptor(input)?.$1;
    final query = normalizedService(input);
    if (query.isEmpty) return null;
    for (final service in services) {
      for (final term in service.terms) {
        if (query == term) return service;
      }
    }
    return null;
  }

  (SubscriptionService, String)? matchDescriptor(String? value) {
    if (value == null) return null;
    final words = _nameWords.allMatches(value).toList();
    final normalized = words.map((word) => normalizedService(word[0])).toList();
    final query = normalized.join(' ');
    (SubscriptionService, String)? best;
    var longest = 0;
    for (final service in services) {
      for (final term in service.terms) {
        if (term.isEmpty) continue;
        if (term == query) return (service, value.trim());
        if (term.length <= longest ||
            {'start', 'wink', 'premier'}.contains(term) ||
            !' $query '.contains(' $term ')) {
          continue;
        }
        final count = term.split(' ').length;
        for (var i = 0; i <= words.length - count; i++) {
          if (normalized.skip(i).take(count).join(' ') == term) {
            best = (
              service,
              value.substring(words[i].start, words[i + count - 1].end),
            );
            longest = term.length;
            break;
          }
        }
      }
    }
    return best;
  }

  bool sameSubscription(Map<String, dynamic> a, Map<String, dynamic> b) {
    String identity(dynamic value) =>
        lookup(value?.toString())?.id ?? normalizedService(value?.toString());
    final left = identity(a['name']);
    final planA = normalizedService(a['plan_name']?.toString());
    final planB = normalizedService(b['plan_name']?.toString());
    return left.isNotEmpty &&
        left == identity(b['name']) &&
        (planA.isEmpty || planB.isEmpty || planA == planB) &&
        (a['currency'] ?? 'RUB') == (b['currency'] ?? 'RUB');
  }
}

String isoDay(DateTime date) => date.toIso8601String().substring(0, 10);

DateTime calendarDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

const recurringPeriods = {
  'daily': 'Каждый день',
  'weekly': 'Каждую неделю',
  'monthly': 'Каждый месяц',
  'quarterly': 'Каждые 3 месяца',
  'yearly': 'Каждый год',
};

DateTime advanceCharge(DateTime date, String period, int anchorDay) {
  final days = {'daily': 1, 'weekly': 7}[period];
  if (days != null) return DateTime.utc(date.year, date.month, date.day + days);
  final months = {'monthly': 1, 'quarterly': 3, 'yearly': 12}[period] ?? 1;
  final last = DateTime.utc(date.year, date.month + months + 1, 0).day;
  return DateTime.utc(
    date.year,
    date.month + months,
    math.min(anchorDay, last),
  );
}

DateTime upcomingCharge(
  DateTime date,
  String period,
  int anchorDay,
  DateTime now,
) {
  final today = calendarDay(now);
  date = calendarDay(date);
  if (period == 'daily' && date.isBefore(today)) return today;
  while (date.isBefore(today)) {
    date = advanceCharge(date, period, anchorDay);
  }
  return date;
}

final printedDate = RegExp(
  r'(?<!\d)(\d\s*\d)\s*\.\s*(\d\s*\d)\s*\.\s*(\d{4}|\d{2})(?!\d)',
);

DateTime? parsePrintedDate(Match? match) {
  if (match == null) return null;
  final day = int.parse(match[1]!.replaceAll(RegExp(r'\s'), ''));
  final month = int.parse(match[2]!.replaceAll(RegExp(r'\s'), ''));
  final yearText = match[3]!;
  final year = int.parse(yearText) + (yearText.length == 2 ? 2000 : 0);
  final date = DateTime.utc(year, month, day);
  return date.month == month && date.day == day ? date : null;
}

String? periodFromText(String text) {
  final value = text.toLowerCase().replaceAll('ё', 'е');
  for (final (period, pattern) in const [
    ('quarterly', r'квартал|(?<!\d)3\s*мес|(?<!\d)90\s*дн|quarter'),
    (
      'yearly',
      r'годов|ежегод|(?:на|в|каждый)\s+год|(?<!\d)12\s*мес|(?<!\d)365\s*дн|annual|year',
    ),
    ('weekly', r'недел|(?<!\d)7\s*дн|week'),
    ('monthly', r'месяц|ежемесяч|(?<!\d)30\s*дн|month'),
    ('daily', r'ежеднев|каждый день|в день|daily|per day'),
  ]) {
    if (RegExp(pattern).hasMatch(value)) return period;
  }
  return null;
}

String? _field(String text, String label) => RegExp(
  '^\\s*(?:$label)\\s*[:—–-]\\s*([^\\r\\n]{1,120})',
  caseSensitive: false,
  multiLine: true,
).firstMatch(text)?[1]?.trim();

final _pricePattern = RegExp(
  r'(?<![\d.,])([0-9]+(?:[ \u00a0\u202f][0-9]{3})*(?:[.,][0-9]{1,2})?)'
  r'\s*(₽|руб(?:лей|ля|\.)?|RUB|USD|EUR|€|\$)(?![a-zа-я])',
  caseSensitive: false,
);

String? _paymentNotificationMerchant(String text) {
  final operation = RegExp(
    r'^\s*(?:покупка|оплата|purchase)(?:\s+по карте)?\s*[: ]*([^\r\n]+)',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(text)?[1];
  if (operation == null) return null;
  final price = _pricePattern.firstMatch(operation);
  if (price == null) return null;
  final suffix = operation.substring(price.end).trimLeft();
  final prefix = operation.substring(0, price.start);
  final merchant = (normalizedService(prefix).isEmpty ? suffix : prefix)
      .replaceFirst(RegExp(r'^(?:в|у)\s+', caseSensitive: false), '')
      .split(
        RegExp(
          r'[.;,]?\s+(?:карта|баланс|остаток|доступно|card|balance)(?![a-zа-яё])',
          caseSensitive: false,
        ),
      )
      .first
      .replaceAll(RegExp(r'^[\s:;,.-]+|[\s:;,.-]+$'), '');
  return merchant.isEmpty ||
          !RegExp(r'[a-zа-яё]', caseSensitive: false).hasMatch(merchant)
      ? null
      : merchant;
}

String? _bareMerchant(String text) {
  final value = text.trim();
  final pattern = RegExp(
    r'^(?:[a-zа-яё0-9._*-]{2,120}|[a-zа-яё0-9]+[._*][ a-zа-яё0-9._*-]{1,118})$',
    caseSensitive: false,
  );
  return pattern.hasMatch(value) &&
          RegExp(r'[a-zа-яё]', caseSensitive: false).hasMatch(value)
      ? value
      : null;
}

Map<String, dynamic> sharedSubscriptionDraft(
  String text,
  ServiceDirectory directory,
) {
  final serviceText =
      _field(text, 'сервис|подписка|service|subscription') ??
      RegExp(
        r'подписка на ([a-zа-яё][^\n,.;:]{0,59}?)(?=\s+(?:оплачена|продлена|активна|действует|истекает)|[\n,.;:]|$)',
        caseSensitive: false,
      ).firstMatch(text)?[1]?.trim();
  final merchant =
      _field(
        text,
        'торговая точка|магазин|продавец|получатель(?: платежа)?|название в выписке|банковское название|merchant(?: name)?|descriptor',
      ) ??
      _paymentNotificationMerchant(text) ??
      _bareMerchant(text);
  final matched =
      directory.matchDescriptor(merchant ?? serviceText ?? text) ??
      (merchant != null ? directory.matchDescriptor(serviceText) : null);
  final service = matched?.$1;
  final original = merchant ?? serviceText ?? matched?.$2;
  final suggestedName = service?.name ?? serviceText ?? original;
  final period = periodFromText(text);
  final bank = _field(text, 'банк|bank');
  final priceText = _field(text, 'сумма|стоимость|цена|итого|к оплате|amount');
  final price =
      _pricePattern.firstMatch(priceText ?? '') ??
      _pricePattern.firstMatch(text);
  final currency = switch (price?[2]?.toUpperCase()) {
    'USD' || '\$' => 'USD',
    'EUR' || '€' => 'EUR',
    _ => 'RUB',
  };
  final explicitDate = _field(
    text,
    'следующее списание|дата продления|действует до|оплачено до|next payment',
  );
  final dateText =
      explicitDate ??
      RegExp(
        r'(?:продление|действует до|списание|оплачено до)\s+\d{2}\.\d{2}\.\d{2,4}',
        caseSensitive: false,
      ).firstMatch(text)?[0];
  final printed = parsePrintedDate(printedDate.firstMatch(dateText ?? ''));
  final next = printed ?? DateTime.tryParse(dateText ?? '');
  final paidText = _field(text, 'дата оплаты|последнее списание|paid on') ?? '';
  final paid =
      parsePrintedDate(printedDate.firstMatch(paidText)) ??
      DateTime.tryParse(paidText);
  final predicted =
      next ??
      (paid != null && period != null
          ? advanceCharge(paid, period, paid.day)
          : null);
  return {
    'source': 'shared',
    'name': suggestedName == null ? null : limitText(suggestedName, 120),
    if (original != null) 'bank_merchant': limitText(original, 300),
    'category': service?.category,
    'plan_name': _field(text, 'тариф|план|plan'),
    'amount': price?[1]
        ?.replaceAll(RegExp(r'\s|\u00a0|\u202f'), '')
        .replaceAll(',', '.'),
    'currency': currency,
    if (bank != null) 'bank_name': limitText(bank, 80),
    if (paid != null) 'last_payment_date': isoDay(paid),
    'period': ?period,
    if (predicted != null) 'next_charge_date': isoDay(predicted),
  };
}
