import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pdfrx/pdfrx.dart';

import 'subscription_intake.dart';

enum StatementBank {
  sber('Сбербанк'),
  tbank('Т-Банк');

  const StatementBank(this.label);
  final String label;
}

class StatementPayment {
  const StatementPayment(
    this.key,
    this.bank,
    this.date,
    this.merchant,
    this.kopecks,
    this.currency,
  );

  factory StatementPayment.fromJson(List<dynamic> data) => StatementPayment(
    data[0] as String,
    StatementBank.values.byName(data[1] as String),
    calendarDay(DateTime.parse(data[2] as String)),
    data[3] as String,
    data[4] as int,
    data[5] as String,
  );

  final String key, merchant, currency;
  final StatementBank bank;
  final DateTime date;
  final int kopecks;

  List<Object> toJson() => [
    key,
    bank.name,
    isoDay(date),
    merchant,
    kopecks,
    currency,
  ];
}

class BankStatement {
  const BankStatement(
    this.bank,
    this.coveredThrough,
    this.fingerprint,
    this.payments,
  );
  final StatementBank bank;
  final DateTime coveredThrough;
  final String fingerprint;
  final List<StatementPayment> payments;
}

class _Glyph {
  const _Glyph(this.char, this.left, this.right, this.y);
  final String char;
  final double left, right, y;
}

class _Line {
  _Line(this.y);
  final double y;
  final glyphs = <_Glyph>[];

  String between([double left = 0, double right = 600]) {
    final result = StringBuffer();
    _Glyph? previous;
    for (final glyph in glyphs) {
      if (glyph.left < left || glyph.left >= right) continue;
      if (previous != null && glyph.left - previous.right > 1.4) {
        result.write(' ');
      }
      result.write(glyph.char);
      previous = glyph;
    }
    return result
        .toString()
        .replaceAll(RegExp(r'\s+|[\u00a0\u202f]'), ' ')
        .trim();
  }
}

List<_Line> _orderedLines(PdfPageRawText pageText, double width) {
  final glyphs = <_Glyph>[];
  for (
    var i = 0;
    i < pageText.fullText.length && i < pageText.charRects.length;
    i++
  ) {
    final char = pageText.fullText[i];
    final box = pageText.charRects[i];
    if (char == '\r' || char == '\n' || (box.isEmpty && char.trim().isEmpty)) {
      continue;
    }
    glyphs.add(
      _Glyph(char, box.left * 595 / width, box.right * 595 / width, box.bottom),
    );
  }
  glyphs.sort((a, b) => b.y.compareTo(a.y));
  final lines = <_Line>[];
  for (final glyph in glyphs) {
    // PDFium reports glyph bounds. Punctuation and digits on one row have different bottoms.
    if (lines.isEmpty || (lines.last.y - glyph.y).abs() > 5.2) {
      lines.add(_Line(glyph.y));
    }
    lines.last.glyphs.add(glyph);
  }
  for (final line in lines) {
    line.glyphs.sort((a, b) => a.left.compareTo(b.left));
  }
  return lines;
}

String statementFingerprint(Uint8List bytes) =>
    sha256.convert(bytes).toString();

final _operationTime = RegExp(r'\d{2}:\d{2}');
final _bankAmount = RegExp(
  r'^([+−-])?\s*([\d ]+[,.]\d{2})\s*(₽|RUB|\$|USD|€|EUR)?$',
  caseSensitive: false,
);
final _ignoredOperation = RegExp(
  r'перевод|пополнен|снятие наличных|внесение наличных|возврат|кэшб[еэ]к|'
  r'cashback|cash withdrawal|money transfer|начисление процент|сбп\s+перевод',
  caseSensitive: false,
);

String _merchant(String description) => description
    .split(
      RegExp(
        r'\.?\s*операция\s+по\s+карте|\b(?:RUS|RUSSIA)\b',
        caseSensitive: false,
      ),
    )
    .first
    .replaceAll(RegExp(r'\*{2,}\d+|\+?\d{7,}'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r'[.,;:]+$'), '');

String _description(List<_Line> lines, int index, double left) {
  const right = 385.0;
  final value = StringBuffer(lines[index].between(left, right));
  for (var i = index + 1; i < lines.length && i <= index + 3; i++) {
    final line = lines[i];
    if (line.between(0, left).isNotEmpty ||
        line.between(right).isNotEmpty ||
        (lines[i - 1].y - line.y) > 15) {
      break;
    }
    value.write(' ${line.between(left, right)}');
  }
  return value.toString();
}

Future<BankStatement> readBankStatement(Uint8List bytes) async {
  if (bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('Выберите PDF-выписку размером до 20 МБ.');
  }
  final fingerprint = statementFingerprint(bytes);
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openData(bytes, sourceName: fingerprint);
  try {
    if (document.pages.length > 150) {
      throw const FormatException('Выберите выписку объёмом до 150 страниц.');
    }
    final firstPage = document.pages.firstOrNull;
    final firstText = await firstPage?.loadText();
    final firstLines = firstText == null
        ? <_Line>[]
        : _orderedLines(firstText, firstPage!.width);
    final header = firstLines.take(28).map((l) => l.between()).toList();
    final rawHeader = firstText?.fullText.split('\n').take(40).join('\n') ?? '';
    final head = '$rawHeader\n${header.join('\n')}'.toLowerCase().replaceAll(
      'ё',
      'е',
    );
    final bankMarkers = head.replaceAll(RegExp(r'[^a-zа-я]'), '');
    final bank = switch (bankMarkers) {
      final h when h.contains('выпискаподоговору') && h.contains('балансна') =>
        StatementBank.tbank,
      final h
          when h.contains('выписка') &&
              (h.contains('сбербанк') ||
                  h.contains('sberbankru') ||
                  h.contains('сберкарт')) =>
        StatementBank.sber,
      _ => throw const FormatException(
        'Формат выписки не распознан. Выберите текстовую PDF-выписку Сбера или Т-Банка.',
      ),
    };
    final sber = bank == StatementBank.sber;
    final coverage =
        header
            .where(
              (line) => line.toLowerCase().startsWith(
                sber ? 'за период' : 'баланс на',
              ),
            )
            .expand(printedDate.allMatches)
            .map(parsePrintedDate)
            .whereType<DateTime>()
            .toList()
          ..sort();
    final payments = <StatementPayment>[];
    final repeatCounts = <String, int>{};
    DateTime? lastOperation;
    var recognized = false;
    final bankCurrency = sber && head.contains('доллар сша')
        ? 'USD'
        : sber && head.contains('евро')
        ? 'EUR'
        : 'RUB';
    var card = '';
    for (final page in document.pages) {
      final List<_Line> lines;
      if (page.pageNumber == 1) {
        lines = firstLines;
      } else {
        final text = await page.loadText();
        if (text == null) continue;
        lines = _orderedLines(text, page.width);
      }
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final full = line.between();
        final cardHeader = RegExp(
          r'Операции\s+по\s+карте\s*№\s*([\d* ]+)',
          caseSensitive: false,
        ).firstMatch(full);
        if (cardHeader != null) card = cardHeader[1]!.replaceAll(' ', '');
        final date = parsePrintedDate(
          printedDate.matchAsPrefix(line.between(30, 90)),
        );
        if (date == null) continue;
        final timing = line.between(90, sber ? 145 : 205);
        final time =
            _operationTime.stringMatch(sber ? timing : line.between(30, 130)) ??
            '';
        if (sber ? time.isEmpty : printedDate.firstMatch(timing) == null) {
          continue;
        }
        final value = _bankAmount.firstMatch(
          sber ? line.between(385, 486) : line.between(480, 550),
        );
        if (value == null) continue;
        recognized = true;
        if (lastOperation == null || date.isAfter(lastOperation)) {
          lastOperation = date;
        }
        if (value[1] == '+') continue;
        final number = value[2]!.replaceAll(RegExp(r'[ ,.]+'), '');
        final cents = int.tryParse(number);
        if (cents == null || cents <= 0) continue;
        String category = '',
            description,
            authorization = '',
            paymentCard = card;
        if (sber) {
          category = line.between(145, 385);
          if (i + 1 >= lines.length) continue;
          final detail = lines[i + 1];
          if (printedDate.matchAsPrefix(detail.between(30, 90)) == null ||
              _operationTime.hasMatch(detail.between(90, 145))) {
            continue;
          }
          authorization = detail.between(90, 145);
          description = _description(lines, i + 1, 145);
          paymentCard =
              RegExp(r'\*{2,}(\d{4})').firstMatch(description)?[1] ?? '';
        } else {
          description = _description(lines, i, 205);
        }
        if (_ignoredOperation.hasMatch('$category $description')) continue;
        final merchant = _merchant(description);
        if (normalizedService(merchant).isEmpty) continue;
        final currency = switch (value[3]?.toUpperCase()) {
          'USD' || '\$' => 'USD',
          'EUR' || '€' => 'EUR',
          _ => bankCurrency,
        };
        final identity =
            '${bank.name}|${isoDay(date)}|$time|$authorization|'
            '$paymentCard|${normalizedService(merchant)}|$cents|$currency';
        final ordinal = repeatCounts.update(
          identity,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
        final key = sha256
            .convert(utf8.encode('$identity|$ordinal'))
            .toString();
        payments.add(
          StatementPayment(key, bank, date, merchant, cents, currency),
        );
      }
    }
    final emptyStatement =
        coverage.isNotEmpty &&
        RegExp(
          r'операци[йи]\s+(?:не\s+было|отсутствуют)|операции\s+не\s+проводились',
        ).hasMatch(head);
    if (!recognized && !emptyStatement) {
      throw const FormatException(
        'Не удалось прочитать таблицу операций. Проверьте, что это полная текстовая выписка.',
      );
    }
    final end = coverage.isEmpty ? lastOperation! : coverage.last;
    return BankStatement(bank, end, fingerprint, payments);
  } finally {
    await document.dispose();
  }
}

enum CandidateKind { recognized, suspicious, inactive }

final _subscriptionDescriptor = RegExp(
  r'подписк[аиуеой]|\brecurring\b|\bsubscription\b',
  caseSensitive: false,
);
const _servicesWithSinglePurchases = {
  'kinopoisk',
  'okko',
  'ivi',
  'kion',
  'wink',
  'start',
  'premier',
  'litres',
};

class StatementCandidate {
  const StatementCandidate(
    this.latest,
    this.service,
    this.kind,
    this.period,
    this.count,
    this.anchorDay,
  );
  final StatementPayment latest;
  final SubscriptionService? service;
  final CandidateKind kind;
  final String? period;
  final int count, anchorDay;
  String get name => service?.name ?? latest.merchant;
  DateTime? get predictedDate =>
      period == null ? null : advanceCharge(latest.date, period!, anchorDay);

  Map<String, dynamic> draft() {
    var upcoming = predictedDate;
    if (upcoming != null && kind != CandidateKind.inactive) {
      upcoming = upcomingCharge(upcoming, period!, anchorDay, DateTime.now());
    }
    return {
      'name': name,
      'category': service?.category,
      'amount': (latest.kopecks / 100).toStringAsFixed(2),
      'currency': latest.currency,
      'bank_name': latest.bank.label,
      'last_payment_date': isoDay(latest.date),
      'source': 'statement',
      'period': ?period,
      if (upcoming != null) 'next_charge_date': isoDay(upcoming),
      'anchor_day': anchorDay,
      if (kind == CandidateKind.inactive) 'status': 'paused',
    };
  }
}

List<StatementCandidate> findStatementSubscriptions(
  Iterable<StatementPayment> payments,
  Map<StatementBank, DateTime> coverage,
  ServiceDirectory directory,
) {
  final groups = <String, List<StatementPayment>>{};
  for (final payment in payments) {
    final service = directory.lookup(payment.merchant, text: true);
    final identity =
        service?.id ??
        '${normalizedService(payment.merchant)}|${payment.kopecks}';
    groups
        .putIfAbsent(
          '${payment.bank.name}|${payment.currency}|$identity',
          () => [],
        )
        .add(payment);
  }
  final results = <StatementCandidate>[];
  for (final samples in groups.values) {
    samples.sort((a, b) => a.date.compareTo(b.date));
    final latest = samples.last;
    final service = directory.lookup(latest.merchant, text: true);
    final dates = samples.map((p) => p.date).toSet().toList();
    final (period, anchor) = _recurrence(dates);
    final knownSubscription =
        _subscriptionDescriptor.hasMatch(latest.merchant) ||
        (service != null &&
            (!_servicesWithSinglePurchases.contains(service.id) ||
                period != null));
    final sameAmount = samples.every(
      (payment) => payment.kopecks == latest.kopecks,
    );
    final frequent =
        dates.length >= 3 &&
        (period != null ||
            latest.date.difference(dates[dates.length - 3]).inDays <= 90);
    if (!knownSubscription && !(frequent && sameAmount)) continue;
    final expected = period == null
        ? latest.date
        : advanceCharge(latest.date, period, anchor);
    final stale =
        (coverage[latest.bank] ?? latest.date).difference(expected).inDays >=
            60 &&
        (period != null || knownSubscription);
    final kind = stale
        ? CandidateKind.inactive
        : knownSubscription
        ? CandidateKind.recognized
        : CandidateKind.suspicious;
    results.add(
      StatementCandidate(latest, service, kind, period, samples.length, anchor),
    );
  }
  results.sort((a, b) {
    final kind = a.kind.index.compareTo(b.kind.index);
    return kind != 0 ? kind : b.latest.date.compareTo(a.latest.date);
  });
  return results;
}

(String?, int) _recurrence(List<DateTime> dates) {
  final last = dates.last;
  if (dates.length < 2) return (null, last.day);
  final recent = dates.length > 7 ? dates.sublist(dates.length - 7) : dates;
  for (final (period, tolerance) in const [
    ('daily', 0),
    ('weekly', 1),
    ('monthly', 3),
    ('quarterly', 5),
    ('yearly', 7),
  ]) {
    final anchor = period == 'daily' || period == 'weekly'
        ? last.day
        : recent.map((d) => d.day).reduce((a, b) => a > b ? a : b);
    var streak = 0;
    for (var i = recent.length - 1; i > 0; i--) {
      final predicted = advanceCharge(recent[i - 1], period, anchor);
      if (recent[i].difference(predicted).inDays.abs() > tolerance) break;
      streak++;
    }
    if (streak >= (period == 'daily' || period == 'weekly' ? 2 : 1) &&
        (recent.length <= 3 || streak >= 2)) {
      return (period, anchor);
    }
  }
  return (null, last.day);
}
