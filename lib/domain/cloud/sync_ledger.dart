import 'dart:convert';
import 'dart:math';

/// 同步实体的因果版本。设备序号不依赖手机时钟，并发版本保留到用户明确选择。
class SyncVersion {
  SyncVersion({
    required this.device,
    required this.sequence,
    required this.clock,
    required this.value,
    required this.time,
  });
  final String device;
  final int sequence, time;
  final Map<String, int> clock;
  final Object? value;
  String get revision => '$device:$sequence';
  Map<String, dynamic> toJson() => {
    'device': device,
    'sequence': sequence,
    'clock': clock,
    'value': value,
    'time': time,
  };
  factory SyncVersion.fromJson(Map<String, dynamic> json) {
    final device = json['device'] as String;
    final sequence = json['sequence'] as int;
    final clock = Map<String, dynamic>.from(
      json['clock'] as Map,
    ).map((k, v) => MapEntry(k, v as int));
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(device) ||
        sequence < 1 ||
        clock[device] != sequence ||
        clock.values.any((v) => v < 0)) {
      throw const FormatException('云端版本记录损坏');
    }
    return SyncVersion(
      device: device,
      sequence: sequence,
      clock: clock,
      value: json['value'],
      time: json['time'] as int? ?? 0,
    );
  }
}

/// 每个字段／业务实体独立合并；未知 entity 与 value 原样保留，旧端不能擦掉新字段。
class SyncLedger {
  SyncLedger(this.device);
  final String device;
  int sequence = 0;
  final Map<String, List<SyncVersion>> entries = {};
  final Map<String, int> clock = {};
  Iterable<String> get conflicts =>
      entries.keys.where((key) => entries[key]!.length > 1);

  static bool _dominates(Map<String, int> a, Map<String, int> b) =>
      b.entries.every((entry) => (a[entry.key] ?? 0) >= entry.value);
  static bool same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  /// 本地变更在所有已知修订之后发生，因而也可用于用户显式解决冲突。
  void put(String key, Object? value) {
    sequence = max(sequence, clock[device] ?? 0) + 1;
    clock[device] = sequence;
    entries[key] = [
      SyncVersion(
        device: device,
        sequence: sequence,
        clock: Map.of(clock),
        value: value,
        time: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
  }

  /// 仅合并有因果依据的覆盖；并发不同值不能凭时间戳或最大进度猜测用户意图。
  void merge(SyncLedger other) {
    for (final item in other.entries.entries) {
      final combined = <String, SyncVersion>{
        for (final v in [...?entries[item.key], ...item.value]) v.revision: v,
      }.values.toList();
      final maximal = combined
          .where(
            (v) => !combined.any(
              (candidate) =>
                  candidate.revision != v.revision &&
                  _dominates(candidate.clock, v.clock),
            ),
          )
          .toList();
      // 值完全相同的并发版本保留因果信息，界面无需要求用户重复确认。
      entries[item.key] = maximal;
    }
    for (final entry in other.clock.entries) {
      clock[entry.key] = max(clock[entry.key] ?? 0, entry.value);
    }
  }

  bool hasConflict(String key) {
    final values = entries[key] ?? [];
    return values.length > 1 &&
        values.skip(1).any((v) => !same(v.value, values.first.value));
  }

  SyncVersion? winner(String key) {
    final values = entries[key];
    if (values == null || values.isEmpty) return null;
    if (hasConflict(key)) {
      return values.where((v) => v.device == device).firstOrNull;
    }
    return values.first;
  }

  Map<String, Object?> materialize() => {
    for (final key in entries.keys)
      if (winner(key) != null) key: winner(key)!.value,
  };
  Map<String, dynamic> toJson() => {
    'protocol': 1,
    'device': device,
    'sequence': sequence,
    'clock': clock,
    'entries': entries.map(
      (k, v) => MapEntry(k, v.map((e) => e.toJson()).toList()),
    ),
  };
  factory SyncLedger.fromJson(Map<String, dynamic> json) {
    if (json['protocol'] != 1) throw const FormatException('云书架协议较新，请先升级阅读器');
    final device = json['device'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(device)) {
      throw const FormatException('设备标识损坏');
    }
    final ledger = SyncLedger(device)..sequence = json['sequence'] as int? ?? 0;
    ledger.clock.addAll(
      Map<String, dynamic>.from(
        json['clock'] as Map,
      ).map((k, v) => MapEntry(k, v as int)),
    );
    for (final item in Map<String, dynamic>.from(
      json['entries'] as Map,
    ).entries) {
      if (item.key.length > 300) throw const FormatException('云端实体标识过长');
      ledger.entries[item.key] = (item.value as List)
          .map((v) => SyncVersion.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
    }
    return ledger;
  }
}
