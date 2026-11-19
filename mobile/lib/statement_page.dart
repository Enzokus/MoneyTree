import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'api.dart';
import 'bank_statements.dart';
import 'subscription_intake.dart';

class StatementPage extends StatefulWidget {
  const StatementPage({super.key, required this.api, required this.onReview});

  final ApiClient api;
  final Future<void> Function(BuildContext, Map<String, dynamic>) onReview;

  @override
  State<StatementPage> createState() => _StatementPageState();
}

class _StatementPageState extends State<StatementPage> {
  bool reading = false;
  bool allPayments = false;
  String query = '';
  String? notice;

  DateFormat get format => DateFormat('dd.MM.yyyy');

  Future<void> import() async {
    setState(() {
      reading = true;
      notice = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'PDF',
            extensions: ['pdf'],
            mimeTypes: ['application/pdf'],
            uniformTypeIdentifiers: ['com.adobe.pdf'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException('Выберите PDF-выписку размером до 20 МБ.');
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (widget.api.importedStatement(statementFingerprint(bytes))) {
        setState(() => notice = 'Эта выписка уже была импортирована.');
        return;
      }
      final statement = await readBankStatement(bytes);
      if (!mounted) return;
      await widget.api.addStatement(statement);
      if (mounted) {
        setState(() => notice = '${statement.bank.label}: выписка обработана.');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => notice = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => notice = 'Не удалось прочитать PDF. Выберите текстовую выписку без пароля.',
        );
      }
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.api,
    builder: (context, _) {
      final api = widget.api;
      final directory = api.services;
      final filter = normalizedService(query);
      final coverage = api.statementDates;
      final candidates = allPayments
          ? const <StatementCandidate>[]
          : findStatementSubscriptions(
                  api.statementPayments,
                  coverage,
                  directory,
                )
                .where(
                  (item) => normalizedService(
                    '${item.name} ${item.latest.merchant} ${item.latest.bank.label}',
                  ).contains(filter),
                )
                .toList();
      final payments = allPayments
          ? (api.statementPayments
                .where(
                  (payment) => normalizedService(
                    '${payment.merchant} ${payment.bank.label}',
                  ).contains(filter),
                )
                .toList()
              ..sort((a, b) => b.date.compareTo(a.date)))
          : const <StatementPayment>[];
      final sections = [
        for (final (kind, heading) in const [
          (CandidateKind.recognized, 'Распознанные сервисы'),
          (CandidateKind.suspicious, 'Частые платежи на одинаковую сумму'),
          (CandidateKind.inactive, 'Потенциально неактивные'),
        ])
          (heading, candidates.where((item) => item.kind == kind).toList()),
      ];
      final rows = <Widget Function()>[
        () => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.file_open_outlined),
                onPressed: reading ? null : import,
                label: Text(reading ? 'Анализируем…' : 'Выбрать PDF-выписку'),
              ),
              if (reading) const LinearProgressIndicator(),
              if (notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(notice!, semanticsLabel: notice),
                ),
              if (coverage.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Поддерживаются текстовые PDF-выписки Сбера и Т-Банка.',
                  ),
                ),
              for (final entry in coverage.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${entry.key.label} · выписка по ${format.format(entry.value)}\n'
                    'Следующая выписка с ${format.format(entry.value.add(const Duration(days: 1)))}',
                  ),
                ),
              if (coverage.isNotEmpty) ...[
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Найденные')),
                    ButtonSegment(value: true, label: Text('Платежи')),
                  ],
                  selected: {allPayments},
                  onSelectionChanged: (value) =>
                      setState(() => allPayments = value.single),
                ),
                const SizedBox(height: 10),
                TextField(
                  decoration: InputDecoration(
                    labelText: allPayments
                        ? 'Поиск по платежам'
                        : 'Поиск по найденным',
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => query = value),
                ),
              ],
            ],
          ),
        ),
        if (coverage.isNotEmpty && candidates.isEmpty && payments.isEmpty)
          () => Text(
            allPayments
                ? 'Платежи не найдены.'
                : 'Подходящих подписок не найдено.',
          ),
        for (final (heading, entries) in sections)
          if (entries.isNotEmpty) ...[
            () => Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text(
                heading,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final candidate in entries)
              () => candidateTile(context, candidate),
          ],
        for (final payment in payments)
          () {
            final service = directory.lookup(payment.merchant, text: true);
            return candidateTile(
              context,
              StatementCandidate(
                payment,
                service,
                CandidateKind.suspicious,
                null,
                1,
                payment.date.day,
              ),
              showPattern: false,
            );
          },
      ];
      return Scaffold(
        appBar: AppBar(title: const Text('Импорт выписки')),
        body: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: rows.length,
          itemBuilder: (context, index) => rows[index](),
        ),
      );
    },
  );

  Widget candidateTile(
    BuildContext context,
    StatementCandidate candidate, {
    bool showPattern = true,
  }) {
    final payment = candidate.latest;
    final draft = candidate.draft();
    final forecast = DateTime.tryParse(
      draft['next_charge_date']?.toString() ?? '',
    );
    final exists = widget.api.subscriptions.any(
      (row) => widget.api.services.sameSubscription(row, draft),
    );
    final amount = (payment.kopecks / 100).toStringAsFixed(2);
    final currency = payment.currency == 'RUB' ? '₽' : payment.currency;
    return Card(
      child: ListTile(
        title: Text(candidate.name),
        subtitle: Text(
          [
            '${payment.bank.label} · $amount $currency · ${format.format(payment.date)}',
            if (showPattern && candidate.kind == CandidateKind.inactive)
              'Потенциально неактивная',
            if (showPattern && candidate.count > 1)
              'Операции (${candidate.count})',
            if (showPattern && candidate.period != null)
              recurringPeriods[candidate.period]!,
            if (showPattern &&
                forecast != null &&
                candidate.kind != CandidateKind.inactive)
              'Следующее списание ≈ ${format.format(forecast)}',
            if (showPattern && candidate.period == null)
              'Проверьте период и дату',
            if (exists) 'Есть подписка с таким названием',
          ].join('\n'),
        ),
        trailing: Icon(exists ? Icons.check : Icons.add_circle_outline),
        onTap: () => widget.onReview(context, draft),
      ),
    );
  }
}
