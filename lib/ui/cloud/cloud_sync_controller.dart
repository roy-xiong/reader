import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../data/cloud/cloud_assets.dart';
import '../../data/cloud/cloud_crypto.dart';
import '../../data/cloud/cloud_secrets.dart';
import '../../data/cloud/webdav_store.dart';
import '../../domain/cloud/cloud_models.dart';
import '../../domain/cloud/sync_ledger.dart';

/// 云同步独立于阅读排版。资源仅由用户主动传输，阅读进度走单独的持久化队列。
/// 所有网络任务串行，退出连接时关闭客户端；不把普通设置或 PIN 导出到云端。
class CloudSyncController extends ChangeNotifier {
  CloudSyncController({
    required this.directory,
    required this.sources,
    required this.receive,
    required this.isUnavailable,
    CloudSecrets? secrets,
    CloudStore Function(String, String, String)? storeFactory,
  }) : secrets = secrets ?? CloudSecrets(),
       storeFactory =
           storeFactory ??
           ((s, u, p) => WebDavStore(server: s, username: u, password: p));
  final Directory directory;
  final Future<List<CloudSource>> Function(String) sources;
  final Future<void> Function(CloudItem, Map<String, File>) receive;
  final bool Function() isUnavailable;
  final CloudSecrets secrets;
  final CloudStore Function(String, String, String) storeFactory;
  CloudStore? _store;
  CloudAssets? _assets;
  CloudCrypto? _crypto;
  SyncLedger? _ledger;
  String? _libraryId;
  String root = '阅读', server = 'https://dav.jianguoyun.com/dav/', username = '';
  String? _recovery;
  String get recoveryCode => _recovery ?? '';
  String _device = '';
  bool busy = false, _disposed = false, _paused = false;
  String? error;
  String status = '尚未连接坚果云';
  double? fraction;
  int completedFiles = 0, totalFiles = 0, lastSuccess = 0;
  String currentFile = '';
  int _sequence = 0, _failures = 0;
  final Map<String, CloudProgress> _pending = {};
  final Map<String, CloudProgress> _lastUploaded = {};
  Timer? _progressTimer;
  Future<void> _saving = Future.value();
  bool get connected => _store != null && _crypto != null && _libraryId != null;
  bool get progressPending => _pending.isNotEmpty;
  int get pendingCount => _pending.length;
  List<CloudItem> get items {
    final result = <CloudItem>[];
    for (final entry
        in _ledger?.entries.entries ??
            const <MapEntry<String, List<SyncVersion>>>[]) {
      if (!entry.key.startsWith('item/')) continue;
      final versions = List<SyncVersion>.of(entry.value)
        ..sort((a, b) => b.time.compareTo(a.time));
      final value =
          _ledger!.winner(entry.key)?.value ?? versions.firstOrNull?.value;
      if (value is! Map || !['book', 'font', 'photo'].contains(value['kind'])) {
        continue;
      }
      try {
        result.add(CloudItem.fromJson(Map<String, dynamic>.from(value)));
      } catch (_) {
        /* 未识别记录继续留在协议中，旧端不绘制或删除它。 */
      }
    }
    return result..sort((a, b) => a.name.compareTo(b.name));
  }

  File get _state => File('${directory.path}/cloud-state.enc');
  String get _stateBinding => '$_libraryId/local/$_device';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String _message(Object e) =>
      e is FormatException ? e.message : '同步失败，请检查网络、应用密码和可用存储后重试';

  /// 恢复安全存储中的连接，不在启动时主动上传书籍、字体、照片或设置。
  Future<void> initialize() async {
    try {
      final saved = await secrets.read();
      if (_disposed || saved == null) return;
      final data = Map<String, dynamic>.from(jsonDecode(saved) as Map);
      server = data['server'] as String;
      username = data['username'] as String;
      root = data['root'] as String;
      _libraryId = data['libraryId'] as String;
      _device = data['device'] as String;
      _recovery = data['recovery'] as String;
      _crypto = CloudCrypto(CloudCrypto.parseRecoveryCode(_recovery!));
      _store = storeFactory(server, username, data['password'] as String);
      _assets = CloudAssets(_store!, _crypto!, root, _libraryId!);
      _ledger = SyncLedger(_device);
      if (await _state.exists()) {
        final data = await _crypto!.decode(
          await _state.readAsBytes(),
          _stateBinding,
        );
        _ledger = SyncLedger.fromJson(
          Map<String, dynamic>.from(data['ledger'] as Map),
        );
        _sequence = data['sequence'] as int? ?? 0;
        lastSuccess = data['lastSuccess'] as int? ?? 0;
        for (final value in (data['pending'] as List? ?? [])) {
          final progress = CloudProgress.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          _pending[progress.bookId] = progress;
        }
        for (final value in (data['uploaded'] as List? ?? [])) {
          final progress = CloudProgress.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          _lastUploaded[progress.bookId] = progress;
        }
      }
      if (_disposed) {
        _store?.close();
        _store = null;
        return;
      }
      status = '已连接坚果云';
      _scheduleProgress();
    } catch (e) {
      error = _message(e);
      status = '连接恢复失败，请重新连接';
      _store?.close();
      _store = null;
    }
    _changed();
  }

  Future<void> connect({
    required String server,
    required String username,
    required String password,
    required String root,
    required String recoveryCode,
    required bool create,
  }) async {
    if (busy || isUnavailable()) return;
    if (username.trim().isEmpty || password.trim().isEmpty) {
      throw const FormatException('请填写账号和第三方应用密码');
    }
    if (!RegExp(r'^[^/\\.][^/\\]{0,59}$').hasMatch(root.trim()) ||
        root.trim().contains('..')) {
      throw const FormatException('云书架目录只能填写单个文件夹名称');
    }
    busy = true;
    fraction = null;
    error = null;
    totalFiles = completedFiles = 0;
    currentFile = '';
    status = '验证坚果云连接';
    _changed();
    CloudStore? candidate;
    try {
      candidate = storeFactory(server.trim(), username.trim(), password.trim());
      await candidate.directory(root.trim());
      final vault = await candidate.read(
        '${root.trim()}/vault.json',
        maxBytes: 16384,
      );
      final crypto = CloudCrypto(CloudCrypto.parseRecoveryCode(recoveryCode));
      String id;
      if (vault == null) {
        if (!create) throw const FormatException('此目录还没有云书架，请在首台设备创建');
        id = _hex(16);
        final check = await crypto.encode({
          'magic': 'ReadingVault',
          'libraryId': id,
        }, '$id/vault');
        await candidate.write(
          '${root.trim()}/vault.json',
          utf8.encode(
            jsonEncode({
              'protocol': 1,
              'libraryId': id,
              'check': base64Encode(check),
            }),
          ),
          createOnly: true,
        );
      } else {
        if (create) throw const FormatException('此目录已有云书架，请使用原恢复码加入，或更换目录创建');
        final header = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(vault)) as Map,
        );
        if (header['protocol'] != 1) {
          throw const FormatException('云书架版本较新，请先升级阅读器');
        }
        id = header['libraryId'] as String;
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
          throw const FormatException('云书架标识损坏');
        }
        final check = await crypto.decode(
          base64Decode(header['check'] as String),
          '$id/vault',
        );
        if (check['magic'] != 'ReadingVault' || check['libraryId'] != id) {
          throw const FormatException('恢复码验证失败');
        }
      }
      final sameLibrary = _libraryId == id;
      final device = sameLibrary && _device.isNotEmpty ? _device : _hex(16);
      final assets = CloudAssets(candidate, crypto, root.trim(), id);
      await assets.ensureDirectory('${root.trim()}/devices');
      await assets.ensureDirectory('${root.trim()}/commits');
      await assets.ensureDirectory('${root.trim()}/进度');
      await secrets.write(
        jsonEncode({
          'server': server.trim(),
          'username': username.trim(),
          'password': password.trim(),
          'root': root.trim(),
          'recovery': recoveryCode.trim(),
          'device': device,
          'libraryId': id,
        }),
      );
      _store?.close();
      _store = candidate;
      _crypto = crypto;
      _assets = assets;
      this.server = server.trim();
      this.username = username.trim();
      this.root = root.trim();
      _libraryId = id;
      _device = device;
      _recovery = recoveryCode.trim();
      if (!sameLibrary) {
        _ledger = SyncLedger(device);
        _pending.clear();
        _lastUploaded.clear();
        _sequence = 0;
      }
      await _persist();
      status = '已连接；资源由你选择上传或下载';
    } catch (e) {
      candidate?.close();
      error = _message(e);
      rethrow;
    } finally {
      busy = false;
      fraction = null;
      _changed();
      _scheduleProgress();
    }
  }

  static String _hex(int bytes) => CloudCrypto.random(
    bytes,
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  /// 设备 head 只引用已上传且认证通过的不可变快照，资源上传失败不会发布半个书架。
  Future<void> _refresh() async {
    final store = _store!, crypto = _crypto!, ledger = _ledger!;
    final deviceFiles = await store.list('$root/devices');
    for (final name in deviceFiles) {
      if (!RegExp(r'^[a-f0-9]{32}\.json$').hasMatch(name)) continue;
      final headBytes = await store.read(
        '$root/devices/$name',
        maxBytes: 16384,
      );
      if (headBytes == null) continue;
      final device = name.substring(0, 32);
      final head = await crypto.decode(headBytes, '$_libraryId/head/$device');
      final commit = head['commit'] as String;
      if (!RegExp(
        r'^[a-f0-9]{32}-[0-9]+-[a-f0-9]{12}\.bin$',
      ).hasMatch(commit)) {
        throw const FormatException('云书架快照引用无效');
      }
      final bytes = await store.read('$root/commits/$commit');
      if (bytes == null) throw const FormatException('云书架快照缺失，已保留本机目录');
      final remote = await crypto.decode(bytes, '$_libraryId/commit/$commit');
      final decoded = SyncLedger.fromJson(remote);
      if (decoded.device != device) throw const FormatException('快照设备归属不一致');
      ledger.merge(decoded);
    }
    await _persist();
  }

  Future<void> refresh() => _run('刷新云端目录', () async {
    await _refresh();
  });
  Future<void> upload(String kind) => _run('准备上传', () async {
    await _refresh();
    final local = await sources(kind);
    totalFiles = local.length;
    completedFiles = 0;
    for (final source in local) {
      if (_disposed || !connected) throw const FormatException('同步已取消');
      currentFile = source.name;
      status = '上传 ${completedFiles + 1}/$totalFiles';
      fraction = 0;
      _changed();
      final item = await _assets!.upload(
        source,
        progress: (done, total) {
          fraction = total == 0 ? 1 : done / total;
          _changed();
        },
        cancelled: () => _disposed || !connected,
      );
      final key = 'item/${item.key}';
      final previous = (_ledger!.entries[key] ?? []).fold<Object?>(
        null,
        (value, version) => _preserveFields(value, version.value),
      );
      _ledger!.put(key, _preserveFields(previous, item.toJson()));
      // 每完成一个资源即发布，后续文件失败也能保留已经上传完成的项目。
      await _publish();
      completedFiles++;
      fraction = 1;
      _changed();
    }
    status = local.isEmpty
        ? '本机没有可上传的${_kindName(kind)}'
        : '上传完成，共 $completedFiles 项';
  });

  /// 覆盖已知值时保留未知业务字段；列表成员按稳定 ID 合并未知属性，不复活已删成员。
  static Object? _preserveFields(Object? previous, Object? current) {
    if (previous is Map && current is Map) {
      return {
        ...previous,
        for (final key in current.keys)
          key: _preserveFields(previous[key], current[key]),
      };
    }
    if (previous is List &&
        current is List &&
        current.every((v) => v is Map && v['id'] is String)) {
      return current
          .map(
            (v) => _preserveFields(
              previous
                  .where((p) => p is Map && p['id'] == (v as Map)['id'])
                  .firstOrNull,
              v,
            ),
          )
          .toList();
    }
    return current;
  }

  Future<void> _publish() async {
    final name = '$_device-${++_sequence}-${_hex(6)}.bin';
    await _store!.write(
      '$root/commits/$name',
      await _crypto!.encode(_ledger!.toJson(), '$_libraryId/commit/$name'),
    );
    final head = await _crypto!.encode({
      'commit': name,
    }, '$_libraryId/head/$_device');
    await _store!.write('$root/devices/$_device.json', head);
    await _persist();
  }

  Future<void> download(CloudItem item) => downloadAll([item]);

  /// 用户主动选择的同类资源依次下载；任何一次校验失败都会停止，并保留已完成的项目。
  Future<void> downloadAll(List<CloudItem> selected) => _run('准备下载', () async {
    totalFiles = selected.length;
    completedFiles = 0;
    for (final item in selected) {
      final transfers = await Directory(
        '${directory.path}/transfers',
      ).create(recursive: true);
      final temp = await transfers.createTemp('download_');
      try {
        currentFile = item.name;
        fraction = 0;
        _changed();
        final files = await _assets!.download(
          item,
          temp,
          progress: (done, total) {
            fraction = total == 0 ? 1 : done / total;
            _changed();
          },
          cancelled: () => _disposed || !connected,
        );
        if (isUnavailable()) throw const FormatException('请先解锁并等待当前本地导入结束');
        await receive(item, files);
        completedFiles++;
        fraction = 1;
        status = '下载完成 $completedFiles/$totalFiles';
        _changed();
      } finally {
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    }
  });

  Future<void> _run(String label, Future<void> Function() task) async {
    if (busy || !connected || isUnavailable()) return;
    busy = true;
    error = null;
    totalFiles = completedFiles = 0;
    currentFile = '';
    status = label;
    _changed();
    try {
      await task();
      lastSuccess = DateTime.now().millisecondsSinceEpoch;
      await _persist();
    } catch (e) {
      error = _message(e);
      status = '同步未完成，可重试';
    } finally {
      busy = false;
      fraction = null;
      currentFile = '';
      _changed();
      _scheduleProgress();
    }
  }

  String _kindName(String kind) => switch (kind) {
    'book' => '书籍',
    'font' => '字体',
    _ => '照片',
  };

  /// 每次阅读变更都持久化待上传位置；连续快速翻页合并为最新位置，避免触发网盘频率限制。
  void recordProgress({
    required String bookId,
    required int offset,
    required int length,
    required int updatedAt,
    String quote = '',
    int parseVersion = 2,
  }) {
    if (!connected || _disposed) return;
    final progress = CloudProgress(
      bookId: bookId,
      deviceId: _device,
      offset: offset,
      length: length,
      updatedAt: updatedAt,
      sequence: ++_sequence,
      quote: quote,
      parseVersion: parseVersion,
      extensions:
          _pending[bookId]?.extensions ??
          _lastUploaded[bookId]?.extensions ??
          const {},
    );
    _pending[bookId] = progress;
    unawaited(
      _persist().catchError((Object e) {
        error = _message(e);
        _changed();
      }),
    );
    _scheduleProgress();
    _changed();
  }

  void setPaused(bool value) {
    _paused = value;
    if (value) {
      _progressTimer?.cancel();
    } else {
      _scheduleProgress();
    }
  }

  void _scheduleProgress() {
    if (_disposed ||
        _paused ||
        !connected ||
        _pending.isEmpty ||
        _progressTimer?.isActive == true) {
      return;
    }
    final wait = _failures == 0
        ? 500
        : min(300000, 5000 * (1 << min(_failures, 6)));
    _progressTimer = Timer(
      Duration(milliseconds: wait),
      () => unawaited(flushProgress()),
    );
  }

  Future<void> flushProgress() async {
    _progressTimer?.cancel();
    if (busy || _paused || !connected || isUnavailable() || _pending.isEmpty) {
      _scheduleProgress();
      return;
    }
    busy = true;
    error = null;
    status = '上传阅读进度';
    fraction = null;
    _changed();
    try {
      final batch = Map<String, CloudProgress>.of(_pending);
      totalFiles = batch.length;
      completedFiles = 0;
      for (final entry in batch.entries) {
        final progress = entry.value;
        await _assets!.ensureDirectory('$root/进度/${progress.bookId}');
        final bytes = await _crypto!.encode(
          progress.toJson(),
          '$_libraryId/progress/${progress.bookId}/$_device',
        );
        await _store!.write('$root/进度/${progress.bookId}/$_device.bin', bytes);
        _lastUploaded[entry.key] = progress;
        if (_pending[entry.key]?.sequence == progress.sequence) {
          _pending.remove(entry.key);
        }
        completedFiles++;
        fraction = completedFiles / totalFiles;
        _changed();
        await _persist();
      }
      _failures = 0;
      lastSuccess = DateTime.now().millisecondsSinceEpoch;
      status = '阅读进度已上传';
      await _persist();
    } catch (e) {
      _failures++;
      error = _message(e);
      status = '进度待补传';
    } finally {
      busy = false;
      fraction = null;
      _changed();
      _scheduleProgress();
    }
  }

  /// 打开书籍前查询各设备记录，仅当云端更新时间更晚且位置不同才返回提示候选。
  /// 不修改本机进度，用户同意后由 AppModel 定位；获取失败仍可离线阅读。
  Future<CloudProgress?> newerProgress(
    String bookId,
    int localUpdatedAt,
    int localOffset,
  ) async {
    if (!connected) return null;
    if (busy) {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (busy && !_disposed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (busy || !connected || _disposed) {
        error = '正在传输其他资料，暂时无法检查进度。可继续本机阅读或稍后重试';
        _changed();
        return null;
      }
    }
    busy = true;
    totalFiles = completedFiles = 0;
    currentFile = '';
    status = '检查云端阅读进度';
    error = null;
    _changed();
    try {
      CloudProgress? latest;
      for (final name in await _store!.list('$root/进度/$bookId')) {
        if (!RegExp(r'^[a-f0-9]{32}\.bin$').hasMatch(name)) continue;
        final device = name.substring(0, 32);
        final bytes = await _store!.read(
          '$root/进度/$bookId/$name',
          maxBytes: 32768,
        );
        if (bytes == null) continue;
        final progress = CloudProgress.fromJson(
          await _crypto!.decode(bytes, '$_libraryId/progress/$bookId/$device'),
        );
        if (progress.bookId != bookId || progress.deviceId != device) {
          throw const FormatException('云端进度归属校验失败');
        }
        if (latest == null ||
            progress.updatedAt > latest.updatedAt ||
            (progress.updatedAt == latest.updatedAt &&
                progress.sequence > latest.sequence)) {
          latest = progress;
        }
      }
      final pending = _pending[bookId];
      if (pending != null && pending.updatedAt >= (latest?.updatedAt ?? 0)) {
        return null;
      }
      status = '云端进度检查完成';
      return latest != null &&
              latest.updatedAt > localUpdatedAt &&
              latest.offset != localOffset
          ? latest
          : null;
    } catch (e) {
      error = _message(e);
      status = '云端暂不可用，可继续本地阅读';
      return null;
    } finally {
      busy = false;
      _changed();
      _scheduleProgress();
    }
  }

  /// 加密本地队列使用原子替换，网络失败不丢队列；普通设置和密码不进入同步状态。
  Future<void> _persist() {
    if (_crypto == null || _ledger == null) return Future.value();
    final crypto = _crypto!, binding = _stateBinding;
    final value = {
      'ledger': _ledger!.toJson(),
      'sequence': _sequence,
      'lastSuccess': lastSuccess,
      'pending': _pending.values.map((p) => p.toJson()).toList(),
      'uploaded': _lastUploaded.values.map((p) => p.toJson()).toList(),
    };
    final operation = _saving.catchError((Object _) {}).then((_) async {
      final bytes = await crypto.encode(value, binding);
      await directory.create(recursive: true);
      final temp = File('${_state.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(_state.path);
    });
    _saving = operation;
    return operation;
  }

  Future<void> disconnect() async {
    if (busy) return;
    _progressTimer?.cancel();
    await _saving.catchError((Object _) {});
    await secrets.delete();
    _store?.close();
    _store = null;
    _crypto = null;
    _assets = null;
    _ledger = null;
    _recovery = null;
    _libraryId = null;
    _pending.clear();
    _lastUploaded.clear();
    status = '已断开；本地书架和网盘文件保留';
    error = null;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    _store?.close();
    super.dispose();
  }
}
