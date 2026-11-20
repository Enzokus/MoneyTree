import 'dart:async';
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
import 'statement_page.dart';
import 'subscription_intake.dart';
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
  final navigator = GlobalKey<NavigatorState>();
  static const intake = MethodChannel('moneytree/intake');
  final sharedText = <String>[];
  bool reviewingShare = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.addListener(reviewSharedText);
    intake.setMethodCallHandler((call) async {
      if (call.method == 'sharedTextAvailable') await takeSharedText();
    });
    unawaited(takeSharedText());
    api.init();
  }

  Future<void> takeSharedText() async {
    try {
      final texts = await intake.invokeListMethod<String>('takeSharedText');
      if (!mounted || texts == null) return;
      sharedText.addAll(texts.where((text) => text.trim().isNotEmpty));
      reviewSharedText();
    } on MissingPluginException {
      // This host has no system share target.
    } on PlatformException {
      // Keep the normal app usable if the system share inbox is unavailable.
    }
  }

  void reviewSharedText() {
    if (reviewingShare || !api.canOpen || api.loading || sharedText.isEmpty) {
      return;
    }
    reviewingShare = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final context = navigator.currentContext;
        if (!mounted || !api.canOpen || context == null) return;
        final draft = sharedSubscriptionDraft(
          sharedText.removeAt(0),
          api.services,
        );
        await showSubscriptionForm(context, api, draft: draft);
      } finally {
        reviewingShare = false;
        if (mounted && navigator.currentContext != null) reviewSharedText();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    intake.setMethodCallHandler(null);
    api.removeListener(reviewSharedText);
    api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(takeSharedText());
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
      navigatorKey: navigator,
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
  bool _byPhone = true;
  bool _busy = false;
  bool _showPassword = false;
  bool _registering = false;

  String get _identifier => _byPhone ? '+7${_phone.text}' : _email.text.trim();

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      if (_registering) {
        await widget.api.register(_identifier, _password.text);
      } else {
        await widget.api.loginWithPassword(_identifier, _password.text);
        if (mounted && widget.reauthenticate) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) errorSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changeMode() {
    _password.clear();
    setState(() {
      _registering = !_registering;
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
                        helperText: _registering ? 'Минимум 12 символов' : null,
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
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _enter,
                      child: Text(
                        _busy
                            ? 'Подождите…'
                            : _registering
                            ? 'Зарегистрироваться'
                            : 'Войти',
                      ),
                    ),
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
                    if (!widget.reauthenticate)
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
  bool _deletingAccount = false;

  Future<void> _confirmAccountDeletion() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Удалить аккаунт?'),
        content: const Text(
          'Аккаунт и все его подписки будут удалены без возможности восстановления.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text(
              'Удалить аккаунт',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _deletingAccount = true);
    try {
      await widget.api.deleteAccount();
    } catch (error) {
      if (mounted) errorSnack(context, error);
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

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
            enabled: !_deletingAccount,
            onSelected: (choice) async {
              switch (choice) {
                case 'manual':
                  await showSubscriptionForm(context, widget.api);
                  break;
                case 'statement':
                  await showStatementImport(context, widget.api);
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
                case 'delete_account':
                  await _confirmAccountDeletion();
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'manual',
                child: Text('Добавить вручную'),
              ),
              const PopupMenuItem(
                value: 'statement',
                child: Text('Импортировать выписку'),
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
              const PopupMenuItem(
                value: 'logout',
                child: Text(
                  'Выйти из аккаунта',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
              const PopupMenuItem(
                value: 'delete_account',
                child: Text(
                  'Удалить аккаунт',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
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
  final anchor = (s['anchor_day'] as num?)?.toInt() ?? date.day;
  final upcoming = upcomingCharge(
    date,
    s['period']?.toString() ?? 'monthly',
    anchor,
    now,
  );
  return DateTime(upcoming.year, upcoming.month, upcoming.day);
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
      'daily': 'день',
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
            service: widget.api.services.lookup(s['name']?.toString()),
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

Future<void> showStatementImport(BuildContext context, ApiClient api) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StatementPage(
          api: api,
          onReview: (context, draft) =>
              showSubscriptionForm(context, api, draft: draft),
        ),
      ),
    );

String statusName(Object? status) => switch (status) {
  'paused' => 'Приостановлена',
  'cancelled' => 'Отменена',
  _ => 'Активна',
};

class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key, required this.api});
  final ApiClient api;
  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  String status = 'all';
  String query = '';

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    final directory = api.services;
    final rows =
        api.subscriptions.where((row) {
          final service = directory.lookup(row['name']?.toString());
          final searchText = normalizedService(
            [
              row['name'],
              row['plan_name'],
              row['category'],
              row['bank_name'],
              row['bank_merchant'],
              ...?service?.aliases,
            ].whereType<String>().join(' '),
          );
          return (status == 'all' || status == row['status']) &&
              searchText.contains(normalizedService(query));
        }).toList()..sort((a, b) {
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
        FilledButton.icon(
          onPressed: () => showStatementImport(context, api),
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Импортировать выписку'),
        ),
        OutlinedButton.icon(
          onPressed: () => showSubscriptionForm(context, api),
          icon: const Icon(Icons.add),
          label: const Text('Добавить вручную'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: status,
          decoration: const InputDecoration(labelText: 'Статус подписок'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('Все')),
            DropdownMenuItem(value: 'active', child: Text('Активные')),
            DropdownMenuItem(value: 'paused', child: Text('Приостановленные')),
            DropdownMenuItem(value: 'cancelled', child: Text('Отменённые')),
          ],
          onChanged: (value) => setState(() => status = value!),
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Поиск по подпискам',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          Center(
            child: Text(
              api.subscriptions.isEmpty
                  ? 'Подписок пока нет'
                  : 'Подписки не найдены',
            ),
          ),
        for (final s in rows)
          SubscriptionTile(
            data: s,
            service: directory.lookup(s['name']?.toString()),
            onTap: () => showSubscriptionForm(context, api, existing: s),
          ),
      ],
    );
  }
}

class SubscriptionTile extends StatelessWidget {
  const SubscriptionTile({
    super.key,
    required this.data,
    required this.onTap,
    this.service,
  });
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  final SubscriptionService? service;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF612671),
        child: service != null
            ? Icon(serviceIcon(service!.icon), color: pale)
            : Text(
                (data['name']?.toString().isNotEmpty ?? false)
                    ? data['name'].toString()[0].toUpperCase()
                    : '?',
                style: const TextStyle(color: pale),
              ),
      ),
      title: Text(data['name']?.toString() ?? ''),
      subtitle: Text(
        '${data['plan_name'] ?? periodName(data['period']?.toString())} · '
        '${data['status'] == 'active' ? readableDate(data) : statusName(data['status'])}',
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
  Map<String, dynamic>? draft,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        SubscriptionForm(api: api, existing: existing, draft: draft),
  );
}

class SubscriptionForm extends StatefulWidget {
  const SubscriptionForm({
    super.key,
    required this.api,
    this.existing,
    this.draft,
  });
  final ApiClient api;
  final Map<String, dynamic>? existing;
  final Map<String, dynamic>? draft;
  @override
  State<SubscriptionForm> createState() => _SubscriptionFormState();
}

class _SubscriptionFormState extends State<SubscriptionForm> {
  final formKey = GlobalKey<FormState>();
  Map<String, dynamic>? get initial => widget.existing ?? widget.draft;
  late final bankMerchant = initial?['bank_merchant']?.toString().trim() ?? '';
  late final fallbackName = limitText(bankMerchant, 120);
  late var service = widget.api.services.lookup(initial?['name']?.toString());
  late final name = TextEditingController(
    text: initial?['name'] == fallbackName
        ? ''
        : initial?['name']?.toString() ?? '',
  );
  late final nameFocus = FocusNode()..addListener(updateNameFocus);
  void updateNameFocus() {
    if (!nameFocus.hasFocus &&
        name.text.trim().isEmpty &&
        name.text.isNotEmpty) {
      name.clear();
    }
    setState(() {});
  }

  late final plan = TextEditingController(
    text: initial?['plan_name']?.toString() ?? '',
  );
  late final category = TextEditingController(
    text: initial?['category']?.toString() ?? service?.category ?? '',
  );
  late final amount = TextEditingController(
    text: initial?['amount']?.toString() ?? '',
  );
  late final bank = TextEditingController(
    text: initial?['bank_name']?.toString() ?? '',
  );
  late String? period =
      initial?['period']?.toString() ??
      (widget.draft == null ? 'monthly' : null);
  late String status = initial?['status']?.toString() ?? 'active';
  late String currency = initial?['currency']?.toString() ?? 'RUB';
  late DateTime? nextDate = widget.existing != null
      ? chargeDate(widget.existing!)
      : widget.draft != null
      ? DateTime.tryParse(initial?['next_charge_date']?.toString() ?? '')
      : DateTime.now();
  late int anchorDay =
      (initial?['anchor_day'] as num?)?.toInt() ??
      nextDate?.day ??
      DateTime.now().day;
  bool busy = false;
  bool datePicked = false;
  @override
  void dispose() {
    name.dispose();
    nameFocus.dispose();
    plan.dispose();
    category.dispose();
    amount.dispose();
    bank.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!formKey.currentState!.validate()) return;
    if (nextDate == null) {
      errorSnack(context, 'Укажите дату следующего списания.');
      return;
    }
    setState(() => busy = true);
    try {
      await ReminderService.instance.updateTimeZone();
      await widget.api.saveSubscription({
        'name': name.text.trim().isEmpty
            ? fallbackName
            : service?.name ?? name.text.trim(),
        'plan_name': plan.text.trim().isEmpty ? null : plan.text.trim(),
        'category': category.text.trim().isEmpty
            ? null
            : category.text.trim().toLowerCase(),
        'amount': amount.text.trim().replaceAll(',', '.'),
        'currency': currency,
        'period': period,
        'next_charge_date': isoDay(nextDate!),
        'anchor_day': anchorDay,
        'timezone': tz.local.name,
        'status': status,
        'source': initial?['source'] ?? 'manual',
        'bank_name': bank.text.trim().isEmpty ? null : bank.text.trim(),
        if (bankMerchant.isNotEmpty) 'bank_merchant': bankMerchant,
        if (initial?['last_payment_date'] != null)
          'last_payment_date': initial!['last_payment_date'],
      }, id: widget.existing?['id']?.toString());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) errorSnack(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void updateService(String value) {
    final matched = widget.api.services.lookup(value);
    if (category.text.trim().isEmpty || category.text == service?.category) {
      category.text = matched?.category ?? '';
    }
    setState(() => service = matched);
  }

  void updatePeriod(String? value) {
    setState(() {
      period = value;
      final paid = DateTime.tryParse(
        initial?['last_payment_date']?.toString() ?? '',
      );
      if (!datePicked &&
          value != null &&
          paid != null &&
          (nextDate == null || widget.draft?['source'] == 'statement')) {
        anchorDay = paid.day;
        final first = advanceCharge(paid, value, anchorDay);
        nextDate = status == 'active'
            ? upcomingCharge(first, value, anchorDay, DateTime.now())
            : first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = normalizedService(name.text);
    final suggestions = query.isEmpty || service != null
        ? const <SubscriptionService>[]
        : widget.api.services.services
              .where((s) => s.terms.any((term) => term.startsWith(query)))
              .take(5);
    return Padding(
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
                    ? widget.draft == null
                          ? 'Новая подписка'
                          : 'Проверьте подписку'
                    : 'Редактировать подписку',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: name,
                focusNode: nameFocus,
                hintLocales: const [Locale('ru'), Locale('en')],
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: 'Сервис',
                  floatingLabelBehavior: fallbackName.isEmpty
                      ? FloatingLabelBehavior.auto
                      : FloatingLabelBehavior.always,
                  counterText: '',
                  hintText:
                      fallbackName.isNotEmpty &&
                          !nameFocus.hasFocus &&
                          name.text.isEmpty
                      ? fallbackName
                      : null,
                  hintStyle: Theme.of(context).textTheme.bodyLarge,
                  prefixIcon: service == null
                      ? null
                      : Icon(serviceIcon(service!.icon)),
                ),
                onChanged: updateService,
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) && fallbackName.isEmpty
                    ? 'Укажите сервис'
                    : null,
              ),
              if (bankMerchant.isNotEmpty &&
                  (name.text.isNotEmpty || nameFocus.hasFocus))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    bankMerchant,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (suggestions.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final suggestion in suggestions)
                      ActionChip(
                        avatar: Icon(serviceIcon(suggestion.icon), size: 18),
                        label: Text(suggestion.name),
                        onPressed: () {
                          name.text = suggestion.name;
                          updateService(suggestion.name);
                        },
                      ),
                  ],
                ),
              const SizedBox(height: 10),
              TextFormField(
                controller: plan,
                maxLength: 120,
                hintLocales: const [Locale('ru'), Locale('en')],
                decoration: const InputDecoration(
                  labelText: 'Тариф (необязательно)',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: category,
                maxLength: 80,
                hintLocales: const [Locale('ru'), Locale('en')],
                decoration: const InputDecoration(
                  labelText: 'Категория, например музыка',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: amount,
                decoration: InputDecoration(
                  labelText: 'Цена',
                  suffixIcon: DropdownButton<String>(
                    value: currency,
                    padding: const EdgeInsets.only(right: 12),
                    items: [
                      for (final code in {'RUB', 'USD', 'EUR', currency})
                        DropdownMenuItem(value: code, child: Text(code)),
                    ],
                    onChanged: (value) => setState(() => currency = value!),
                  ),
                ),
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
                items: [
                  for (final entry in recurringPeriods.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                validator: (value) => value == null ? 'Выберите период' : null,
                onChanged: updatePeriod,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: bank,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Банк (необязательно)',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              ListTile(
                tileColor: surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: const Text('Следующее списание'),
                subtitle: Text(
                  nextDate == null
                      ? 'Выберите дату'
                      : DateFormat('d MMMM yyyy', 'ru').format(nextDate!),
                ),
                trailing: const Icon(Icons.event),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: nextDate ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2200),
                  );
                  if (d != null) {
                    setState(() {
                      nextDate = d;
                      anchorDay = d.day;
                      datePicked = true;
                    });
                  }
                },
              ),
              if (initial != null) ...[
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
                    DropdownMenuItem(
                      value: 'cancelled',
                      child: Text('Отменена'),
                    ),
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
}

IconData serviceIcon(String key) => switch (key) {
  'music' => Icons.music_note,
  'movie' => Icons.movie_outlined,
  'book' => Icons.menu_book,
  'telegram' => Icons.send,
  'prime' => Icons.stars_outlined,
  _ => Icons.subscriptions_outlined,
};
