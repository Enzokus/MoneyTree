import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input_validation.dart';

import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/timezone.dart' as tz;

import 'api.dart';
import 'reminders.dart';
import 'tree_art.dart';

const background = Color(0xFF0D0718);
const surface = Color(0xFF20112F);
const violet = Color(0xFFA45CFF);
const pink = Color(0xFFFF4EAF);
const pale = Color(0xFFF8E8FF);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  try {
    await ReminderService.instance.init().timeout(const Duration(seconds: 8));
  } catch (error, stack) {
    debugPrint('Reminder initialization failed: $error\n$stack');
  }
  runApp(const SubscriptionTreeApp());
}

class SubscriptionTreeApp extends StatefulWidget {
  const SubscriptionTreeApp({super.key});
  @override
  State<SubscriptionTreeApp> createState() => _SubscriptionTreeAppState();
}

class _SubscriptionTreeAppState extends State<SubscriptionTreeApp>
    with WidgetsBindingObserver {
  final api = ApiClient();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshDeviceTimeZone();
    }
  }

  Future<void> refreshDeviceTimeZone() async {
    try {
      await ReminderService.instance.updateTimeZone();
    } catch (error) {
      debugPrint('Timezone refresh failed: $error');
    }
    if (api.canOpen) await api.reload();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: api,
    builder: (_, _) => MaterialApp(
      title: 'Денежное дерево',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: pink,
          secondary: violet,
          surface: surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: pale,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
        cardTheme: CardThemeData(
          color: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      home: api.loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : api.canOpen
          ? HomePage(api: api)
          : LoginPage(api: api),
    ),
  );
}

void errorSnack(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(error.toString())));
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, this.reauthenticate = false});
  final ApiClient api;
  final bool reauthenticate;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _byPhone = true;
  bool _busy = false;
  bool _showPassword = false;
  bool _registering = false;
  String? _challengeId;

  String get _identifier => _byPhone ? '+7${_phone.text}' : _email.text.trim();

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    await _run(() async {
      final challengeId = _challengeId;
      if (!_registering) {
        await widget.api.loginWithPassword(_identifier, _password.text);
        if (mounted && widget.reauthenticate) Navigator.of(context).pop();
      } else if (challengeId == null) {
        await _requestCode();
      } else {
        await widget.api.completeRegistration(
          challengeId,
          _code.text,
          _password.text,
        );
      }
    });
  }

  Future<void> _requestCode() async {
    final challengeId = await widget.api.requestRegistrationCode(_identifier);
    if (!mounted) return;
    _code.clear();
    setState(() => _challengeId = challengeId);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) errorSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changeMode() {
    _password.clear();
    _code.clear();
    setState(() {
      _registering = !_registering;
      _challengeId = null;
      _showPassword = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.reauthenticate ? AppBar(title: const Text('Вход')) : null,
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF170927), Color(0xFF3A103B), background],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.spa, size: 72, color: pink),
                    const SizedBox(height: 16),
                    Text(
                      _registering ? 'Регистрация' : 'Денежное дерево',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: pale,
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (_challengeId == null) ...[
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('Телефон')),
                          ButtonSegment(value: false, label: Text('Почта')),
                        ],
                        selected: {_byPhone},
                        showSelectedIcon: false,
                        onSelectionChanged: _busy
                            ? null
                            : (selection) =>
                                  setState(() => _byPhone = selection.single),
                      ),
                      const SizedBox(height: 16),
                      if (_byPhone)
                        TextFormField(
                          key: const ValueKey('login-phone'),
                          controller: _phone,
                          enabled: !_busy,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [RussianPhoneInputFormatter()],
                          decoration: const InputDecoration(
                            labelText: 'Номер телефона',
                            prefixText: '+7 ',
                          ),
                          validator: (value) =>
                              RegExp(r'^[0-9]{10}$').hasMatch(value ?? '')
                              ? null
                              : 'Введите 10 цифр номера',
                        )
                      else
                        TextFormField(
                          key: const ValueKey('login-email'),
                          controller: _email,
                          enabled: !_busy,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Электронная почта',
                          ),
                          validator: (value) =>
                              RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                  .hasMatch((value ?? '').trim())
                              ? null
                              : 'Введите адрес электронной почты',
                        ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_showPassword,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _enter(),
                        validator: (value) {
                          final length = (value ?? '').runes.length;
                          if (length == 0) return 'Введите пароль';
                          if (_registering && (length < 12 || length > 256)) {
                            return 'Пароль должен содержать от 12 до 256 символов';
                          }
                          return null;
                        },
                        decoration: InputDecoration(
                          labelText: 'Пароль',
                          helperText: _registering
                              ? 'Минимум 12 символов'
                              : null,
                          suffixIcon: IconButton(
                            tooltip: _showPassword
                                ? 'Скрыть пароль'
                                : 'Показать пароль',
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                          ),
                        ),
                      ),
                    ] else ...[
                      Text(
                        _byPhone
                            ? 'Отправили SMS с кодом на $_identifier'
                            : 'Отправили письмо с кодом на $_identifier',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('registration-code'),
                        controller: _code,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Код из 6 цифр',
                        ),
                        onFieldSubmitted: (_) => _enter(),
                        validator: (value) => (value ?? '').length == 6
                            ? null
                            : 'Введите 6 цифр кода',
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _enter,
                      child: Text(
                        _busy
                            ? 'Подождите…'
                            : !_registering
                            ? 'Войти'
                            : _challengeId == null
                            ? 'Получить код'
                            : 'Подтвердить и войти',
                      ),
                    ),
                    if (_challengeId != null) ...[
                      TextButton(
                        onPressed: _busy ? null : () => _run(_requestCode),
                        child: const Text('Отправить код ещё раз'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _challengeId = null),
                        child: const Text('Изменить данные'),
                      ),
                    ],
                    if (!_registering) ...[
                      const OutlinedButton(
                        onPressed: null,
                        child: Text('Войти через Яндекс ID'),
                      ),
                      const Text(
                        'Яндекс ID пока недоступен',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                    if (!widget.reauthenticate && _challengeId == null)
                      TextButton(
                        onPressed: _busy ? null : _changeMode,
                        child: Text(
                          _registering
                              ? 'У меня уже есть аккаунт'
                              : 'Создать аккаунт',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api});
  final ApiClient api;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selected = 1;
  @override
  Widget build(BuildContext context) {
    final pages = [
      AiPage(api: widget.api),
      TreePage(api: widget.api),
      SubscriptionsPage(api: widget.api),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['Рекомендации', 'Денежное дерево', 'Подписки'][selected]),
        actions: [
          if (widget.api.pendingCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Tooltip(
                message: 'Ожидают синхронизации: ${widget.api.pendingCount}',
                child: const Icon(Icons.sync, color: Colors.orangeAccent),
              ),
            ),
          if (widget.api.offline)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.cloud_off, color: Colors.orangeAccent),
            ),
          PopupMenuButton<String>(
            tooltip: 'Меню',
            onSelected: (choice) async {
              switch (choice) {
                case 'manual':
                  await showSubscriptionForm(context, widget.api);
                  break;
                case 'connect':
                  await showIntegrations(context, widget.api);
                  break;
                case 'settings':
                  await showSettings(context, widget.api);
                  break;
                case 'login':
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          LoginPage(api: widget.api, reauthenticate: true),
                    ),
                  );
                  break;
                case 'logout':
                  try {
                    await widget.api.logout();
                  } catch (error) {
                    if (context.mounted) errorSnack(context, error);
                  }
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'manual',
                child: Text('Добавить вручную'),
              ),
              const PopupMenuItem(
                value: 'connect',
                child: Text('Подключить сервис'),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Text('Уведомления'),
              ),
              if (widget.api.needsSignIn)
                const PopupMenuItem(value: 'login', child: Text('Войти снова')),
              const PopupMenuItem(value: 'logout', child: Text('Выйти')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: widget.api.reload,
        child: pages[selected],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: surface,
        indicatorColor: const Color(0xFF512366),
        selectedIndex: selected,
        onDestinationSelected: (value) => setState(() => selected = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'ИИ',
          ),
          NavigationDestination(
            icon: Icon(Icons.spa_outlined),
            selectedIcon: Icon(Icons.spa),
            label: 'Дерево',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Подписки',
          ),
        ],
      ),
    );
  }
}

String money(dynamic value, [String currency = 'RUB']) =>
    '${value.toString()} ${currency == 'RUB' ? '₽' : currency}';
DateTime chargeDate(Map<String, dynamic> s, {DateTime? now}) {
  now ??= tz.TZDateTime.now(tz.local);
  var date = DateTime.tryParse(s['next_charge_date']?.toString() ?? '') ?? now;
  if (s['status'] != 'active') return date;
  final today = DateTime.utc(now.year, now.month, now.day);
  final anchor = (s['anchor_day'] as num?)?.toInt() ?? date.day;
  while (DateTime.utc(date.year, date.month, date.day).isBefore(today)) {
    if (s['period'] == 'weekly') {
      date = date.add(const Duration(days: 7));
    } else {
      final months =
          {'monthly': 1, 'quarterly': 3, 'yearly': 12}[s['period']] ?? 1;
      final first = DateTime(date.year, date.month + months, 1);
      final last = DateTime(first.year, first.month + 1, 0).day;
      date = DateTime(first.year, first.month, math.min(anchor, last));
    }
  }
  return date;
}

int daysUntil(Map<String, dynamic> s) {
  final now = tz.TZDateTime.now(tz.local);
  final date = chargeDate(s);
  return DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
}

String readableDate(Map<String, dynamic> s) =>
    DateFormat('d MMMM yyyy', 'ru').format(chargeDate(s));
String periodName(String? period) =>
    const {
      'weekly': 'неделя',
      'monthly': 'месяц',
      'quarterly': '3 месяца',
      'yearly': 'год',
    }[period] ??
    '';

List<Map<String, dynamic>> subscriptionsThisMonth(
  List<Map<String, dynamic>> subscriptions, {
  DateTime? now,
}) {
  final today = now ?? tz.TZDateTime.now(tz.local);
  final rows = subscriptions.where((s) {
    if (s['status'] != 'active') return false;
    final date = chargeDate(s, now: today);
    return date.year == today.year && date.month == today.month;
  }).toList();
  rows.sort(
    (a, b) => chargeDate(a, now: today).compareTo(chargeDate(b, now: today)),
  );
  return rows;
}

class TreePage extends StatefulWidget {
  const TreePage({super.key, required this.api});
  final ApiClient api;
  @override
  State<TreePage> createState() => _TreePageState();
}

class _TreePageState extends State<TreePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();
  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final soon = subscriptionsThisMonth(widget.api.subscriptions);
    final total = soon
        .where((s) => s['currency'] == 'RUB')
        .fold<double>(
          0,
          (sum, s) => sum + (double.tryParse(s['amount'].toString()) ?? 0),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        if (widget.api.offline)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Офлайн: данные и изменения сохраняются на устройстве',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          ),
        const Text(
          'Ваши подписки растут вместе с вами',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        Container(
          height: 390,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: Colors.black,
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final rect = treeImageRect(constraints.biggest);
                    return Stack(
                      children: [
                        Positioned.fromRect(
                          rect: rect,
                          child: Image.asset(
                            treeAsset,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              AnimatedBuilder(
                animation: animation,
                builder: (context, _) => LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      for (var i = 0; i < math.min(soon.length, 14); i++)
                        _leaf(soon[i], i, constraints.biggest, animation.value),
                    ],
                  ),
                ),
              ),
              if (soon.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 160),
                    child: Text(
                      'До конца месяца списаний нет',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'До конца месяца',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  money(total.toStringAsFixed(2)),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: pale,
                  ),
                ),
                Text(
                  '${soon.length} подписок',
                  style: const TextStyle(color: Colors.white60),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (soon.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('До конца месяца списаний нет.'),
          ),
        for (final s in soon)
          SubscriptionTile(
            data: s,
            onTap: () => showSubscriptionForm(context, widget.api, existing: s),
          ),
      ],
    );
  }

  Widget _leaf(Map<String, dynamic> s, int i, Size area, double progress) {
    final anchor = treeLeafAnchors[i];
    final rect = treeImageRect(area);
    final point = Offset(
      rect.left + anchor.dx * rect.width,
      rect.top + anchor.dy * rect.height,
    );
    final falling = daysUntil(s) <= 3;
    final fall = falling ? Curves.easeIn.transform(progress) : 0.0;
    return Positioned(
      left: point.dx - leafBase.dx * leafImageSize,
      top: point.dy - leafBase.dy * leafImageSize,
      child: Transform.translate(
        offset: Offset(
          fall * (i.isEven ? 24 : -24),
          fall * (treeGroundY(area) - point.dy),
        ),
        child: GestureDetector(
          onTap: () => showSubscriptionForm(context, widget.api, existing: s),
          child: Tooltip(
            message: '${s['name']} · ${readableDate(s)}',
            child: Transform.rotate(
              alignment: Alignment(leafBase.dx * 2 - 1, leafBase.dy * 2 - 1),
              angle: (i.isEven ? -1 : 1) * (.28 + fall),
              child: Image.asset(
                leafAsset,
                width: leafImageSize,
                height: leafImageSize,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key, required this.api});
  final ApiClient api;
  @override
  Widget build(BuildContext context) {
    final rows = [...api.subscriptions]
      ..sort((a, b) {
        final status = (a['status'] == 'active' ? 0 : 1).compareTo(
          b['status'] == 'active' ? 0 : 1,
        );
        return status != 0 ? status : chargeDate(a).compareTo(chargeDate(b));
      });
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (api.needsSignIn)
          const Text(
            'Войдите снова через меню, чтобы синхронизировать изменения',
            style: TextStyle(color: Colors.orangeAccent),
          )
        else if (api.offline)
          const Text(
            'Офлайн: можно добавлять и изменять подписки',
            style: TextStyle(color: Colors.orangeAccent),
          ),
        if (api.subscriptions.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.add_circle_outline, size: 48, color: pink),
                  const SizedBox(height: 12),
                  const Text('Подписок пока нет'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => showSubscriptionForm(context, api),
                    child: const Text('Добавить подписку'),
                  ),
                ],
              ),
            ),
          ),
        for (final s in rows)
          SubscriptionTile(
            data: s,
            onTap: () => showSubscriptionForm(context, api, existing: s),
          ),
      ],
    );
  }
}

class SubscriptionTile extends StatelessWidget {
  const SubscriptionTile({super.key, required this.data, required this.onTap});
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF612671),
        child: Text(
          (data['name']?.toString().isNotEmpty ?? false)
              ? data['name'].toString()[0].toUpperCase()
              : '?',
          style: const TextStyle(color: pale),
        ),
      ),
      title: Text(data['name']?.toString() ?? ''),
      subtitle: Text(
        '${data['plan_name'] ?? periodName(data['period']?.toString())} · ${readableDate(data)}${data['status'] != 'active' ? ' · ${data['status']}' : ''}',
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            money(data['amount'], data['currency']?.toString() ?? 'RUB'),
            style: const TextStyle(fontWeight: FontWeight.bold, color: pale),
          ),
          Text(
            data['status'] == 'active'
                ? (daysUntil(data) == 0
                      ? 'Сегодня'
                      : 'Через ${daysUntil(data)} дн.')
                : 'Неактивна',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class AiPage extends StatefulWidget {
  const AiPage({super.key, required this.api});
  final ApiClient api;
  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final question = TextEditingController();
  String? answer;
  bool busy = false;
  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> ask() async {
    if (question.text.trim().isEmpty) return;
    setState(() => busy = true);
    try {
      final result = await widget.api.post('/assistant/ask', {
        'question': question.text.trim(),
      });
      setState(() => answer = result['answer']?.toString());
    } catch (e) {
      if (mounted) errorSnack(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Спросите о подписках и расходах',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: question,
        hintLocales: const [Locale('ru'), Locale('en')],
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(
          hintText: 'На чём я могу сэкономить?',
          suffixIcon: IconButton(
            onPressed: busy ? null : ask,
            icon: const Icon(Icons.send),
          ),
        ),
      ),
      if (busy) const LinearProgressIndicator(),
      if (answer != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text(answer!),
          ),
        ),
      const SizedBox(height: 22),
      const Text(
        'Возможные альтернативы',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      if (widget.api.recommendations.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              'Проверенных более дешёвых альтернатив пока нет. Добавьте подписки или пополните каталог тарифов.',
            ),
          ),
        ),
      for (final recommendation in widget.api.recommendations)
        RecommendationCard(data: recommendation),
      const SizedBox(height: 18),
      const Text(
        'Тарифы в каталоге',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      for (final plan in widget.api.catalog)
        Card(
          child: ListTile(
            title: Text('${plan['service_name']} · ${plan['plan_name']}'),
            subtitle: Text(
              '${periodName(plan['period']?.toString())} · проверено ${plan['checked_at']}',
            ),
            trailing: Text(
              money(plan['amount'], plan['currency']?.toString() ?? 'RUB'),
            ),
            onTap: () => launchUrl(
              Uri.parse(plan['source_url'].toString()),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
    ],
  );
}

class RecommendationCard extends StatelessWidget {
  const RecommendationCard({super.key, required this.data});
  final Map<String, dynamic> data;
  @override
  Widget build(BuildContext context) {
    final plan = Map<String, dynamic>.from(data['alternative']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${data['current_service']} → ${plan['service_name']}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '${plan['plan_name']} · ${money(plan['amount'])} / ${periodName(plan['period']?.toString())}',
            ),
            if ((plan['period_options'] as List?)?.length != null &&
                (plan['period_options'] as List).length > 1)
              Text(
                'Доступные периоды: ${(plan['period_options'] as List).map((option) => '${periodName(option['period']?.toString())} — ${money(option['amount'])}').join(', ')}',
              ),
            Text(
              'Возможная экономия: ${money(data['monthly_saving_rub'])} в месяц',
              style: const TextStyle(color: Color(0xFFB9F2D2)),
            ),
            Text(
              'Проверено ${plan['checked_at']}${plan['price_is_current'] == false ? ' · цену нужно уточнить' : ''}',
              style: const TextStyle(color: Colors.white60),
            ),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse(plan['source_url'].toString()),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('Источник цены'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showIntegrations(BuildContext context, ApiClient api) async {
  try {
    final data = await api.get('/integrations');
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 44, color: violet),
            const SizedBox(height: 12),
            const Text(
              'Подключение сервиса',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              data['message']?.toString() ?? 'Доступных подключений пока нет.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                showSubscriptionForm(context, api);
              },
              child: const Text('Добавить вручную'),
            ),
          ],
        ),
      ),
    );
  } catch (e) {
    if (context.mounted) errorSnack(context, e);
  }
}

Future<void> showSettings(BuildContext context, ApiClient api) async {
  final initial = Map<String, dynamic>.from(
    api.profile?['reminders'] ??
        {
          'hour': 10,
          'minute': 0,
          'days_before': [3, 1],
        },
  );
  var hour = initial['hour'] as int? ?? 10;
  var minute = initial['minute'] as int? ?? 0;
  var days = List<int>.from(initial['days_before'] ?? [3, 1]);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          MediaQuery.viewInsetsOf(sheet).bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Напоминания',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            for (final day in [3, 1, 0])
              CheckboxListTile(
                value: days.contains(day),
                title: Text(
                  day == 0 ? 'В день оплаты' : 'За $day дн. до оплаты',
                ),
                onChanged: (value) => setSheet(() {
                  if (value == true) {
                    days.add(day);
                  } else {
                    days.remove(day);
                  }
                }),
              ),
            ListTile(
              title: const Text('Время уведомления'),
              trailing: Text(
                '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
              ),
              onTap: () async {
                final picked = await showTimePicker(
                  context: sheet,
                  initialTime: TimeOfDay(hour: hour, minute: minute),
                );
                if (picked != null) {
                  setSheet(() {
                    hour = picked.hour;
                    minute = picked.minute;
                  });
                }
              },
            ),
            FilledButton(
              onPressed: days.isEmpty
                  ? null
                  : () async {
                      try {
                        await ReminderService.instance.requestPermission();
                        await api.saveReminders({
                          'hour': hour,
                          'minute': minute,
                          'days_before': days,
                        });
                        await api.reload();
                        if (sheet.mounted) Navigator.pop(sheet);
                      } catch (e) {
                        if (sheet.mounted) errorSnack(sheet, e);
                      }
                    },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showSubscriptionForm(
  BuildContext context,
  ApiClient api, {
  Map<String, dynamic>? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SubscriptionForm(api: api, existing: existing),
  );
}

class SubscriptionForm extends StatefulWidget {
  const SubscriptionForm({super.key, required this.api, this.existing});
  final ApiClient api;
  final Map<String, dynamic>? existing;
  @override
  State<SubscriptionForm> createState() => _SubscriptionFormState();
}

class _SubscriptionFormState extends State<SubscriptionForm> {
  final formKey = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: widget.existing?['name']?.toString() ?? '',
  );
  late final plan = TextEditingController(
    text: widget.existing?['plan_name']?.toString() ?? '',
  );
  late final category = TextEditingController(
    text: widget.existing?['category']?.toString() ?? '',
  );
  late final amount = TextEditingController(
    text: widget.existing?['amount']?.toString() ?? '',
  );
  late String period = widget.existing?['period']?.toString() ?? 'monthly';
  late String status = widget.existing?['status']?.toString() ?? 'active';
  late DateTime nextDate = widget.existing == null
      ? DateTime.now()
      : chargeDate(widget.existing!);
  late int anchorDay =
      (widget.existing?['anchor_day'] as num?)?.toInt() ?? nextDate.day;
  bool busy = false;
  @override
  void dispose() {
    name.dispose();
    plan.dispose();
    category.dispose();
    amount.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await ReminderService.instance.updateTimeZone();
      await widget.api.saveSubscription({
        'name': name.text.trim(),
        'plan_name': plan.text.trim().isEmpty ? null : plan.text.trim(),
        'category': category.text.trim().isEmpty
            ? null
            : category.text.trim().toLowerCase(),
        'amount': amount.text.trim().replaceAll(',', '.'),
        'currency': 'RUB',
        'period': period,
        'next_charge_date': DateFormat('yyyy-MM-dd').format(nextDate),
        'anchor_day': anchorDay,
        'timezone': tz.local.name,
        'status': status,
      }, id: widget.existing?['id']?.toString());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) errorSnack(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      8,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: SingleChildScrollView(
      child: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null
                  ? 'Новая подписка'
                  : 'Редактировать подписку',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: name,
              hintLocales: const [Locale('ru'), Locale('en')],
              decoration: const InputDecoration(labelText: 'Сервис'),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Укажите сервис' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: plan,
              hintLocales: const [Locale('ru'), Locale('en')],
              decoration: const InputDecoration(
                labelText: 'Тариф (необязательно)',
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: category,
              hintLocales: const [Locale('ru'), Locale('en')],
              decoration: const InputDecoration(
                labelText: 'Категория, например музыка',
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: amount,
              decoration: const InputDecoration(labelText: 'Цена, ₽'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [PriceInputFormatter()],
              validator: validatePrice,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: period,
              decoration: const InputDecoration(labelText: 'Период'),
              items: const [
                DropdownMenuItem(value: 'weekly', child: Text('Каждую неделю')),
                DropdownMenuItem(value: 'monthly', child: Text('Каждый месяц')),
                DropdownMenuItem(
                  value: 'quarterly',
                  child: Text('Каждые 3 месяца'),
                ),
                DropdownMenuItem(value: 'yearly', child: Text('Каждый год')),
              ],
              onChanged: (v) => setState(() => period = v!),
            ),
            const SizedBox(height: 10),
            ListTile(
              tileColor: surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Следующее списание'),
              subtitle: Text(DateFormat('d MMMM yyyy', 'ru').format(nextDate)),
              trailing: const Icon(Icons.event),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: nextDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (d != null) {
                  setState(() {
                    nextDate = d;
                    anchorDay = d.day;
                  });
                }
              },
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Статус'),
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('Активна')),
                  DropdownMenuItem(
                    value: 'paused',
                    child: Text('Приостановлена'),
                  ),
                  DropdownMenuItem(value: 'cancelled', child: Text('Отменена')),
                ],
                onChanged: (v) => setState(() => status = v!),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Сохраняем…' : 'Сохранить'),
            ),
            if (widget.existing != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await widget.api.removeSubscription(
                            widget.existing!['id'].toString(),
                          );
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) errorSnack(context, e);
                        }
                      },
                child: const Text(
                  'Удалить',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
