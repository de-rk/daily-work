/// 本地持久化：按日期存储时间块任务 + 设置 + 已触发状态
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppStore {
  static const _kSchedules = 'schedules';
  static const _kLead = 'leadMinutes';
  static const _kEndRemind = 'endRemind';
  static const _kAlarmOn = 'alarmOn';
  static const _kFired = 'firedKeys';

  Future<SharedPreferences> _p() => SharedPreferences.getInstance();

  // ---------- 任务 ----------
  Future<Map<String, List<TaskBlock>>> loadAll() async {
    final p = await _p();
    final raw = p.getString(_kSchedules);
    if (raw == null) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) {
      final list = (v as List)
          .map((e) => TaskBlock.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.startMin.compareTo(b.startMin));
      return MapEntry(k, list);
    });
  }

  Future<List<TaskBlock>> loadDay(DateTime date) async =>
      (await loadAll())[dateKey(date)] ?? const [];

  Future<void> upsert(DateTime date, TaskBlock task) async {
    final all = await loadAll();
    final key = dateKey(date);
    final list = [...(all[key] ?? const [])];
    final idx = list.indexWhere((t) => t.id == task.id);
    if (idx >= 0) {
      list[idx] = task;
    } else {
      list.add(task);
    }
    list.sort((a, b) => a.startMin.compareTo(b.startMin));
    all[key] = list;
    await _saveAll(all);
  }

  Future<void> removeTask(DateTime date, String id) async {
    final all = await loadAll();
    final key = dateKey(date);
    if (all[key] != null) {
      all[key] = all[key]!.where((t) => t.id != id).toList();
      await _saveAll(all);
    }
  }

  Future<void> _saveAll(Map<String, List<TaskBlock>> all) async {
    final p = await _p();
    final encoded = all.map((k, v) => MapEntry(k, v.map((t) => t.toJson()).toList()));
    await p.setString(_kSchedules, jsonEncode(encoded));
  }

  // ---------- 设置 ----------
  Future<(int, bool, bool)> loadSettings() async {
    final p = await _p();
    return (
      p.getInt(_kLead) ?? 5,
      p.getBool(_kEndRemind) ?? false,
      p.getBool(_kAlarmOn) ?? true,
    );
  }

  Future<void> saveSettings({int? lead, bool? endRemind, bool? alarmOn}) async {
    final p = await _p();
    if (lead != null) await p.setInt(_kLead, lead);
    if (endRemind != null) await p.setBool(_kEndRemind, endRemind);
    if (alarmOn != null) await p.setBool(_kAlarmOn, alarmOn);
  }

  // ---------- 前台提醒已触发状态 ----------
  Future<Set<String>> loadFired(String date) async {
    final p = await _p();
    final all = jsonDecode(p.getString(_kFired) ?? '{}') as Map<String, dynamic>;
    return (all[date] as List? ?? const []).toSet().cast<String>();
  }

  Future<void> markFired(String date, String key) async {
    final p = await _p();
    final all = jsonDecode(p.getString(_kFired) ?? '{}') as Map<String, dynamic>;
    final list = (all[date] as List? ?? const []).toList();
    if (!list.contains(key)) {
      list.add(key);
      all[date] = list;
      await p.setString(_kFired, jsonEncode(all));
    }
  }
}
