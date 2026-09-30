/// 数据模型：时间块任务
library;

String two(int n) => n.toString().padLeft(2, '0');

String dateKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

DateTime parseDateKey(String k) {
  final p = k.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

class TaskBlock {
  final String id;
  final int startMin; // 当天分钟数，如 12:00 = 720
  final int endMin;
  final String title;
  final String note;

  const TaskBlock({
    required this.id,
    required this.startMin,
    required this.endMin,
    required this.title,
    this.note = '',
  });

  String get startLabel => '${two(startMin ~/ 60)}:${two(startMin % 60)}';

  String get endLabel => '${two(endMin ~/ 60)}:${two(endMin % 60)}';

  String get rangeLabel => '$startLabel - $endLabel';

  int get durationMin => endMin - startMin;

  bool overlaps(TaskBlock other) =>
      startMin < other.endMin && other.startMin < endMin;

  Map<String, dynamic> toJson() =>
      {'id': id, 'start': startMin, 'end': endMin, 'title': title, 'note': note};

  factory TaskBlock.fromJson(Map<String, dynamic> j) => TaskBlock(
        id: j['id'] as String,
        startMin: (j['start'] as num).toInt(),
        endMin: (j['end'] as num).toInt(),
        title: j['title'] as String,
        note: (j['note'] ?? '') as String,
      );

  /// 稳定通知 ID（Android int32）
  int get startNotifId => id.hashCode & 0x3fffffff;

  int get endNotifId => (id.hashCode ^ 0x55555555) & 0x3fffffff;
}
