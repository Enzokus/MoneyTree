import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class ReminderService {
  ReminderService._();
  static final instance = ReminderService._();
  final plugin = FlutterLocalNotificationsPlugin();
  bool ready = false;

  Future<void> init() async {
    tzdata.initializeTimeZones();
    await updateTimeZone();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    ready = true;
  }

  Future<void> updateTimeZone() async {
    final zone = await FlutterTimezone.getLocalTimezone().timeout(
      const Duration(seconds: 5),
    );
    tz.setLocalLocation(tz.getLocation(zone.identifier));
  }

  Future<bool> requestPermission() async {
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final ios = plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ??
        await ios?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
  }

  DateTime advance(DateTime d, String period, int anchorDay) {
    if (period == 'weekly') return d.add(const Duration(days: 7));
    final months = {'monthly': 1, 'quarterly': 3, 'yearly': 12}[period] ?? 1;
    final firstNext = DateTime(d.year, d.month + months, 1);
    final lastDay = DateTime(firstNext.year, firstNext.month + 1, 0).day;
    return DateTime(firstNext.year, firstNext.month, min(anchorDay, lastDay));
  }

  Future<void> sync(
    List<Map<String, dynamic>> subscriptions,
    Map<String, dynamic>? profile,
  ) async {
    if (!ready) return;
    await plugin.cancelAll();
    final settings = Map<String, dynamic>.from(profile?['reminders'] ?? {});
    final hour = (settings['hour'] as num?)?.toInt() ?? 10;
    final minute = (settings['minute'] as num?)?.toInt() ?? 0;
    final days = List<int>.from(settings['days_before'] ?? [3, 1]);
    var count = 0;
    for (final sub in subscriptions.where((s) => s['status'] == 'active')) {
      if (count >= 60) break;
      final date = DateTime.tryParse(sub['next_charge_date']?.toString() ?? '');
      if (date == null) continue;
      final location = tz.local;
      var charge = date;
      for (var cycle = 0; cycle < 3 && count < 60; cycle++) {
        for (final day in days) {
          final remindDate = charge.subtract(Duration(days: day));
          final at = tz.TZDateTime(
            location,
            remindDate.year,
            remindDate.month,
            remindDate.day,
            hour,
            minute,
          );
          if (!at.isAfter(tz.TZDateTime.now(location)) || count >= 60) continue;
          final key = '${sub['id']}:$cycle:$day';
          final id =
              sha256
                  .convert(utf8.encode(key))
                  .bytes
                  .take(4)
                  .fold<int>(0, (value, byte) => (value << 8) | byte) &
              0x7fffffff;
          await plugin.zonedSchedule(
            id: id,
            title: day == 0
                ? 'Сегодня списание: ${sub['name']}'
                : 'Скоро списание: ${sub['name']}',
            body:
                '${sub['amount']} ${sub['currency'] == 'RUB' ? '₽' : sub['currency']} · ${charge.day}.${charge.month}.${charge.year}',
            scheduledDate: at,
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'payments',
                'Напоминания о подписках',
                channelDescription: 'Предстоящие платежи по подпискам',
                importance: Importance.high,
                priority: Priority.high,
              ),
              iOS: DarwinNotificationDetails(),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
          count++;
        }
        charge = advance(
          charge,
          sub['period']?.toString() ?? 'monthly',
          (sub['anchor_day'] as num?)?.toInt() ?? date.day,
        );
      }
    }
  }
}
