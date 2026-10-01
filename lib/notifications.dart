/// 闹钟核心：flutter_local_notifications 定时通知，后台/锁屏均能触发
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'models.dart';

class AlarmService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    try {
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
      );
    } catch (e) {
      debugPrint('notifications init error: $e');
    }

    // Android 13+ 通知权限 / Android 12+ 精确闹钟权限（失败不阻塞启动）
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('requestNotificationsPermission error: $e');
    }
    try {
      await androidImpl?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('requestExactAlarmsPermission error: $e');
    }

    _ready = true;
  }

  /// 为某天的任务排定通知（开始前 lead 分钟 + 可选结束提醒）
  Future<void> scheduleTask(
    TaskBlock task,
    DateTime date, {
    required int leadMinutes,
    required bool endRemind,
  }) async {
    await cancelTask(task);
    await _schedule(
      id: task.startNotifId,
      date: date,
      minute: task.startMin - leadMinutes,
      title: '时间到 · 开始任务',
      body: '${task.title}\n${task.rangeLabel}',
    );
    if (endRemind) {
      await _schedule(
        id: task.endNotifId,
        date: date,
        minute: task.endMin,
        title: '任务结束',
        body: '「${task.title}」已到结束时间（${task.rangeLabel}）',
      );
    }
  }

  Future<void> cancelTask(TaskBlock task) async {
    await _plugin.cancel(task.startNotifId);
    await _plugin.cancel(task.endNotifId);
  }

  Future<void> cancelAll() => _plugin.cancelAll();

  /// 应用启动时重排所有今天及以后的提醒
  Future<void> rescheduleAll(
    Map<String, List<TaskBlock>> all, {
    required int leadMinutes,
    required bool endRemind,
  }) async {
    try {
      await cancelAll();
    } catch (e) {
      debugPrint('cancelAll error: $e');
    }
    final today = DateTime.now();
    for (final entry in all.entries) {
      final date = parseDateKey(entry.key);
      if (date.isBefore(DateTime(today.year, today.month, today.day))) continue;
      for (final t in entry.value) {
        try {
          await scheduleTask(t, date,
              leadMinutes: leadMinutes, endRemind: endRemind);
        } catch (e) {
          debugPrint('schedule error for "${t.title}": $e');
        }
      }
    }
  }

  Future<void> _schedule({
    required int id,
    required DateTime date,
    required int minute,
    required String title,
    required String body,
  }) async {
    if (minute < 0 || minute >= 48 * 60) return;
    final local = DateTime(date.year, date.month, date.day,
        minute ~/ 60, minute % 60);
    if (local.isBefore(DateTime.now().add(const Duration(seconds: 30)))) return;

    // 转成 UTC 绝对时间，避免时区库依赖
    final utc = local.toUtc();
    final when = tz.TZDateTime.utc(
        utc.year, utc.month, utc.day, utc.hour, utc.minute);

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'time_planner_alarm',
        '任务闹钟',
        channelDescription: '时间块任务到点提醒',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        playSound: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } on PlatformException catch (e) {
      // 精确闹钟权限被拒（Android 12+）时降级为非精确模式，保证提醒仍能触发
      debugPrint('exact schedule failed (${e.code}), fallback to inexact');
      try {
        await _plugin.zonedSchedule(
          id,
          title,
          body,
          when,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (e2) {
        debugPrint('inexact schedule also failed: $e2');
      }
    }
  }
}
