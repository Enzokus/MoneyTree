import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subscription_tree/reminders.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_timezone');

  setUp(() => tzdata.initializeTimeZones());
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    tz.setLocalLocation(tz.UTC);
  });

  test('Emulator GMT and legacy system timezone names are supported', () async {
    for (final identifier in ['GMT', 'Asia/Calcutta', 'Asia/Yekaterinburg']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => identifier);
      await ReminderService.instance.updateTimeZone();
      expect(tz.local.name, identifier);
    }
  });
}
