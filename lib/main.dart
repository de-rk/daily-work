import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'notifications.dart';
import 'store.dart';

final AppStore store = AppStore();
final AlarmService alarms = AlarmService();

const primaryColor = Color(0xFF5B7CFF);
const bg = Color(0xFFF5F6FA);

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '时间规划',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: primaryColor),
          scaffoldBackgroundColor: bg,
        ),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime _date = DateTime.now();
  List<TaskBlock> _tasks = [];
  bool _loaded = false;

  int _lead = 5;
  bool _endRemind = false;
  bool _alarmOn = true;
  bool? _notifEnabled;

  Timer? _ticker;
  Set<String> _fired = {};
  DateTime _lastTick = DateTime.now();
  bool _alarming = false;

  static const leadOptions = [0, 5, 10, 15, 30];

  static String leadLabel(int v) =>
      v <= 0 ? '准时提醒' : '提前 $v 分钟';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await alarms.init();
      final (lead, endRemind, alarmOn) = await store.loadSettings();
      final notifEnabled = await alarms.notificationsEnabled();
      setState(() {
        _lead = lead;
        _endRemind = endRemind;
        _alarmOn = alarmOn;
        _notifEnabled = notifEnabled;
      });
      _fired = await store.loadFired(dateKey(DateTime.now()));
      await _refreshTasks();
      if (_alarmOn) {
        await alarms.rescheduleAll(await store.loadAll(),
            leadMinutes: _lead, endRemind: _endRemind);
      }
    } catch (e) {
      debugPrint('bootstrap error: $e');
    } finally {
      if (mounted) setState(() => _loaded = true);
      _ticker ??=
          Timer.periodic(const Duration(seconds: 10), (_) => _onTick());
    }
  }

  Future<void> _refreshTasks() async {
    final tasks = await store.loadDay(_date);
    if (mounted) setState(() => _tasks = tasks);
  }

  void _onTick() {
    final now = DateTime.now();
    if (_date != DateTime(now.year, now.month, now.day)) return;
    if (now.isBefore(_lastTick.add(const Duration(seconds: 8)))) {
      _lastTick = now;
    }
    setState(() {}); // 刷新进度条/状态
    _checkForegroundAlarm(now);
  }

  /// 前台到点：弹窗 + 连续震动（后台交给系统通知）
  Future<void> _checkForegroundAlarm(DateTime now) async {
    if (_alarming || !_alarmOn) return;
    final nowMin = now.hour * 60 + now.minute + now.second / 60;
    for (final t in _tasks) {
      final key = '${t.id}|start';
      final lead = _lead.toDouble();
      if (_fired.contains(key)) continue;
      if (nowMin >= t.startMin - lead && nowMin < t.startMin + 2) {
        _fired.add(key);
        await store.markFired(dateKey(now), key);
        _fireAlarm(t);
        return;
      }
    }
  }

  void _fireAlarm(TaskBlock task) {
    _alarming = true;
    // 连续强震动约 4 秒
    for (var i = 0; i < 6; i++) {
      Future.delayed(Duration(milliseconds: i * 700), () {
        HapticFeedback.heavyImpact();
      });
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('时间到 · 开始任务'),
        content: Text('${task.title}\n${task.rangeLabel}',
            style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ).then((_) => _alarming = false);
  }

  // ---------- 日期切换 ----------
  void _shiftDay(int days) {
    setState(() => _date = _date.add(Duration(days: days)));
    _refreshTasks();
  }

  // ---------- 增删改 ----------
  Future<void> _editTask({TaskBlock? initial}) async {
    final result = await showModalBottomSheet<TaskBlock>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TaskSheet(date: _date, initial: initial),
    );
    if (result == null) return;

    final conflicts = _tasks
        .where((t) => t.id != result.id && t.overlaps(result))
        .map((t) => '${t.rangeLabel} ${t.title}')
        .toList();
    if (conflicts.isNotEmpty && context.mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('时间冲突'),
          content: Text('与以下任务重叠：\n${conflicts.join('\n')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('返回修改')),
          ],
        ),
      );
      return;
    }

    await store.upsert(_date, result);
    if (_alarmOn) {
      await alarms.scheduleTask(result, _date,
          leadMinutes: _lead, endRemind: _endRemind);
    }
    await _refreshTasks();
  }

  Future<void> _deleteTask(TaskBlock task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定删除「${task.title}」（${task.rangeLabel}）吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await store.removeTask(_date, task.id);
    await alarms.cancelTask(task);
    await _refreshTasks();
  }

  // ---------- 设置 ----------
  Future<void> _setAlarmOn(bool on) async {
    setState(() => _alarmOn = on);
    await store.saveSettings(alarmOn: on);
    if (on) {
      await alarms.rescheduleAll(await store.loadAll(),
          leadMinutes: _lead, endRemind: _endRemind);
    } else {
      await alarms.cancelAll();
    }
  }

  Future<void> _pickLead() async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text('提醒时机', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ...List.generate(leadOptions.length, (i) => ListTile(
                  title: Text(leadLabel(leadOptions[i])),
                  trailing: leadOptions[i] == _lead
                      ? const Icon(Icons.check, color: primaryColor)
                      : null,
                  onTap: () => Navigator.pop(ctx, i),
                )),
            ListTile(
              leading: const Icon(Icons.edit, color: primaryColor),
              title: const Text('自定义分钟数…'),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    int? lead;
    if (result == 'custom') {
      lead = await _promptCustomLead();
    } else if (result is int) {
      lead = leadOptions[result];
    }
    if (lead == null) return;
    await _applyLead(lead);
  }

  Future<int?> _promptCustomLead() {
    final controller = TextEditingController(
        text: _lead > 0 && !leadOptions.contains(_lead) ? '$_lead' : '');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('提前多少分钟提醒？'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '例如 3、20、45',
            suffixText: '分钟',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                final v = int.tryParse(controller.text.trim());
                if (v == null || v < 0 || v > 24 * 60) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('请输入 0 ~ 1440 之间的分钟数')));
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _applyLead(int lead) async {
    setState(() => _lead = lead);
    await store.saveSettings(lead: lead);
    if (_alarmOn) {
      await alarms.rescheduleAll(await store.loadAll(),
          leadMinutes: lead, endRemind: _endRemind);
    }
  }

  Future<void> _setEndRemind(bool on) async {
    setState(() => _endRemind = on);
    await store.saveSettings(endRemind: on);
    if (_alarmOn) {
      await alarms.rescheduleAll(await store.loadAll(),
          leadMinutes: _lead, endRemind: _endRemind);
    }
  }

  /// 发送测试提醒并给出排查指引
  Future<void> _testAlarm() async {
    try {
      await alarms.testAlarm();
    } catch (e) {
      debugPrint('test alarm error: $e');
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('测试提醒已发送'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('刚才应立即弹出通知并响铃。若没有收到，请依次检查：'),
            SizedBox(height: 10),
            Text('1. 系统设置 → 应用 → 时间规划 → 通知权限已开启'),
            Text('2. 系统设置 → 应用 → 时间规划 → 闹钟和提醒 → 允许'),
            Text('3. 手机的通知音量（非媒体音量）已调高、未开勿扰模式'),
            Text('4. 国产系统（小米/华为/OPPO 等）请关闭对本应用的电池优化，并允许后台弹出'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
    // 返回后刷新权限状态
    final enabled = await alarms.notificationsEnabled();
    if (mounted) setState(() => _notifEnabled = enabled);
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isToday = _date.year == now.year &&
        _date.month == now.month &&
        _date.day == now.day;
    final nowMin = now.hour * 60 + now.minute + now.second / 60;

    TaskBlock? current;
    TaskBlock? next;
    for (final t in _tasks) {
      if (isToday) {
        if (t.startMin <= nowMin && nowMin < t.endMin) {
          current ??= t;
        } else if (t.startMin > nowMin) {
          next ??= t;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        title: Text('${_date.month}月${_date.day}日'
            ' 周${'日一二三四五六'[_date.weekday % 7]}'
            '${isToday ? ' · 今天' : ''}'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.today),
            tooltip: '回到今天',
            onPressed: () {
              setState(() => _date = DateTime.now());
              _refreshTasks();
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '前一天',
            onPressed: () => _shiftDay(-1),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '后一天',
            onPressed: () => _shiftDay(1),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildNowCard(current, next, isToday, nowMin),
                const SizedBox(height: 12),
                _buildSettingsCard(),
                if (_tasks.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                    child: Text(
                      '共 ${_tasks.length} 项安排',
                      style: const TextStyle(
                          fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600),
                    ),
                  ),
                  ..._tasks.map((t) => _buildTaskTile(t, isToday, nowMin)),
                ] else
                  _buildEmpty(),
                const SizedBox(height: 24),
                const Center(
                  child: Text(
                    '提醒由系统通知在后台触发；Android 请允许通知与精确闹钟权限，iOS 请允许通知',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
        onPressed: () => _editTask(),
      ),
    );
  }

  Widget _buildNowCard(TaskBlock? current, TaskBlock? next, bool isToday, double nowMin) {
    if (current != null) {
      final progress = ((nowMin - current.startMin) /
              (current.endMin - current.startMin))
          .clamp(0.0, 1.0);
      final left = (current.endMin - nowMin).ceil();
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
              colors: [Color(0xFF5B7CFF), Color(0xFF7A5BFF)]),
          boxShadow: [
            BoxShadow(
                color: primaryColor.withOpacity(.35),
                blurRadius: 16,
                offset: const Offset(0, 6)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(99)),
                child: const Text('进行中',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(current.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(height: 10),
            Text('${current.rangeLabel} · 剩余 $left 分钟',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFF2B2F3A),
      ),
      child: Text(
        next != null ? '当前空闲 · 下一项：${next.title}（${next.startLabel} 开始）' : '当前空闲，没有后续任务',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }

  Widget _buildSettingsCard() {
    final permText = _notifEnabled == null
        ? null
        : _notifEnabled!
            ? '通知权限已开启'
            : '通知权限未开启，提醒将无法弹出';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(.05),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(children: [
        SwitchListTile(
          secondary: const Icon(Icons.alarm, color: primaryColor),
          title: const Text('闹钟提醒'),
          subtitle: Text(permText ?? '后台到点时发送系统通知',
              style: TextStyle(
                  fontSize: 12,
                  color: _notifEnabled == false ? Colors.red : Colors.grey)),
          value: _alarmOn,
          activeColor: primaryColor,
          onChanged: _setAlarmOn,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.schedule, color: primaryColor),
          title: const Text('提醒时机'),
          trailing: Text(
            _alarmOn ? leadLabel(_lead) : '已关闭',
            style: const TextStyle(color: Colors.grey),
          ),
          onTap: _pickLead,
        ),
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.flag, color: primaryColor),
          title: const Text('任务结束时提醒'),
          value: _endRemind,
          activeColor: primaryColor,
          onChanged: _setEndRemind,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.notifications_active, color: primaryColor),
          title: const Text('发送测试提醒'),
          subtitle: const Text('验证通知权限与铃声是否正常', style: TextStyle(fontSize: 12)),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: _testAlarm,
        ),
      ]),
    );
  }

  Widget _buildTaskTile(TaskBlock t, bool isToday, double nowMin) {
    String status = '未开始';
    Color color = const Color(0xFFC6CDF9);
    if (isToday) {
      if (nowMin >= t.endMin) {
        status = '已完成';
        color = Colors.grey;
      } else if (nowMin >= t.startMin) {
        status = '进行中';
        color = primaryColor;
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: status == '进行中' ? const Color(0xFFF6F8FF) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 4)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(.04),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: ListTile(
        onTap: () => _editTask(initial: t),
        onLongPress: () => _deleteTask(t),
        leading: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(t.startLabel,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 15)),
            Container(
                width: 1, height: 8, color: Colors.grey.shade300, margin: const EdgeInsets.symmetric(vertical: 2)),
            Text(t.endLabel,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ],
        ),
        title: Text(t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: t.note.isEmpty
            ? null
            : Text(t.note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: status == '进行中' ? const Color(0xFFE4EAFF) : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(status,
              style: TextStyle(
                  fontSize: 11,
                  color: status == '进行中' ? primaryColor : Colors.grey)),
        ),
      ),
    );
  }

  Widget _buildEmpty() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Column(children: [
          const Text('🗓', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 12),
          const Text('这一天还没有安排',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('点击右下角 ＋ 添加时间块',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
        ]),
      );
}

/// 添加/编辑任务底部弹层
class TaskSheet extends StatefulWidget {
  final DateTime date;
  final TaskBlock? initial;

  const TaskSheet({super.key, required this.date, this.initial});

  @override
  State<TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends State<TaskSheet> {
  late int _startMin;
  late int _endMin;
  late final TextEditingController _title;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      _startMin = widget.initial!.startMin;
      _endMin = widget.initial!.endMin;
      _title = TextEditingController(text: widget.initial!.title);
      _note = TextEditingController(text: widget.initial!.note);
    } else {
      final now = DateTime.now();
      final h = widget.date.day == now.day ? now.hour + 1 : 9;
      _startMin = (h % 24) * 60;
      _endMin = _startMin + 60;
      _title = TextEditingController();
      _note = TextEditingController();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickTime(bool isStart) async {
    final initial = TimeOfDay(
        hour: (isStart ? _startMin : _endMin) ~/ 60,
        minute: (isStart ? _startMin : _endMin) % 60);
    final picked = await showTimePicker(
        context: context, initialTime: initial, helpText: isStart ? '选择开始时间' : '选择结束时间');
    if (picked == null) return;
    final min = picked.hour * 60 + picked.minute;
    setState(() {
      if (isStart) {
        _startMin = min;
        if (_endMin <= _startMin) _endMin = _startMin + 60;
      } else {
        if (min > _startMin) {
          _endMin = min;
        } else {
          _endMin = min + 24 * 60; // 跨天
        }
      }
    });
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请填写任务名称')));
      return;
    }
    if (_endMin <= _startMin) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('结束时间需晚于开始时间')));
      return;
    }
    Navigator.pop(
      context,
      TaskBlock(
        id: widget.initial?.id ??
            DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
                DateTime.now().microsecond.toString(),
        startMin: _startMin,
        endMin: _endMin,
        title: title,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
            left: 20, right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.initial == null ? '添加任务' : '编辑任务',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(_fmt(_startMin), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  onPressed: () => _pickTime(true),
                ),
              ),
              const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('—')),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.stop, size: 18),
                  label: Text(_fmt(_endMin), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  onPressed: () => _pickTime(false),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _title,
              maxLength: 30,
              decoration: InputDecoration(
                labelText: '任务名称',
                hintText: '例如：学习剪辑',
                filled: true,
                fillColor: bg,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              maxLength: 100,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: '备注（可选）',
                filled: true,
                fillColor: bg,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: primaryColor,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(99))),
                onPressed: _save,
                child: const Text('保存', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      );

  static String _fmt(int min) =>
      '${two((min ~/ 60) % 24)}:${two(min % 60)}${min >= 24 * 60 ? ' (+1天)' : ''}';
}
