import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../transport/conversation.dart';
import 'cache_policy.dart';

/// 本地缓存存储（方案 A：文件每条目一份 JSON，应用支持目录）。
///
/// 布局：
/// - `<base>/sessions/<deviceSid>/<sessionId>.json` 会话行缓存
/// - `<base>/device/<deviceSid>.json` 设备级（工作区/任务列表+桥身份）
///
/// 全部 IO 容错（读失败=无缓存，写失败=丢弃缓存——缓存永远不许阻塞
/// 主流程）；写入走 tmp+rename 原子替换；淘汰策略在 cache_policy（纯函数）。
/// 目录注入以便单测（temp dir）。
class LocalCacheStore {
  LocalCacheStore(this.baseDir);

  /// 生产工厂：path_provider 应用支持目录（不进用户可见文件区）。
  static Future<LocalCacheStore> createDefault() async {
    final dir = await getApplicationSupportDirectory();
    final root = Directory('${dir.path}${Platform.pathSeparator}local-cache');
    await root.create(recursive: true);
    await _sweepTmp(root);
    return LocalCacheStore(root);
  }

  /// P3-1/E2-P3-1/E3-P3-4：崩溃残留 .tmp（write 与 rename
  /// 之间进程死亡，唯一后缀会逐次累积且不被 _evict/removeDevice 覆盖）
  /// 启动时顺手清扫；失败不阻塞启动。
  static Future<void> _sweepTmp(Directory root) async {
    try {
      if (!await root.exists()) return;
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith('.tmp')) {
          await e.delete().catchError((_) => e);
        }
      }
    } on Object {
      // 清扫失败不阻塞启动。
    }
  }

  final Directory baseDir;

  Directory get _sessionsRoot => Directory(
    '${baseDir.path}${Platform.pathSeparator}sessions',
  );

  Directory _sessionDir(String deviceSid) => Directory(
    '${_sessionsRoot.path}${Platform.pathSeparator}${_safe(deviceSid)}',
  );

  Directory get _devicesRoot => Directory(
    '${baseDir.path}${Platform.pathSeparator}device',
  );

  /// 跨设备目录安全名：sid 含非法路径字符时做哈希（正常 sid 是
  /// hex/uuid，这里只是防御）。P3-3/E3-P3-5：String.hashCode
  /// 跨执行稳定性无语言保证且碰撞无防护——换确定性 fnv1a-64 + 长度
  /// 前缀（消除短串拼接碰撞维度）。存量目录漂移面≈0（防御路径，真实
  /// sid 全过正则）。
  String _safe(String name) {
    final ok = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name);
    if (ok) return name;
    final bytes = utf8.encode(name);
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return 'h${bytes.length}_${h.toRadixString(36)}';
  }

  File _sessionFile(String deviceSid, String sessionId) => File(
    '${_sessionDir(deviceSid).path}${Platform.pathSeparator}${_safe(sessionId)}.json',
  );

  File _deviceFile(String deviceSid) => File(
    '${_devicesRoot.path}${Platform.pathSeparator}${_safe(deviceSid)}.json',
  );

  // ------------------------------------------------------------- sessions

  Future<SessionCacheEntry?> readSession(String deviceSid, String sessionId) async {
    if (_closed) return null;
    try {
      final raw = await _sessionFile(deviceSid, sessionId).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SessionCacheEntry.fromJson(decoded.cast<String, dynamic>());
    } on Object {
      return null; // 无文件/损坏：当无缓存
    }
  }

  /// 写会话条目（原子替换）+ 淘汰执行。byteSize 在此处测量一次并写回
  /// 条目（淘汰记账用真值，不信调用方；byteSize 不含自身字段 ~15B，
  /// 淘汰决策走 stat.size 真值，此处仅参考——E1-P3-5 注）。
  Future<void> writeSession(SessionCacheEntry entry) async {
    if (_closed) return;
    try {
      // P2-1：序列化全部在首个 await 之前完成——rows 与
      // snapshotControl 若是调用方的活引用（capRows ≤上限时返回原列表、
      // 控制块浅拷贝），await（dir.create）窗口内到达的新回合会把
      // seq=N+1 的行混进"lastSeq=N"的一致水位条目（恢复种子重复行），
      // 且 >200 行会话走 sublist 拷贝不受影响=同机制行为不一致。编码
      // 产物是不可变 String，窗口内变更不再渗入。
      var payload = entry.toJson();
      final bytes = utf8.encode(jsonEncode(payload)).length;
      payload = {...payload, 'byteSize': bytes};
      final content = jsonEncode(payload);
      final file = _sessionFile(entry.deviceSid, entry.sessionId);
      await _sessionDir(entry.deviceSid).create(recursive: true);
      await _atomicWrite(file, content);
      await _evict();
    } on Object catch (e) {
      debugPrint('[cache] session write failed (contained): $e');
    }
  }

  // -------------------------------------------------------------- device

  Future<DeviceCacheEntry?> readDevice(String deviceSid) async {
    if (_closed) return null;
    try {
      final raw = await _deviceFile(deviceSid).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DeviceCacheEntry.fromJson(decoded.cast<String, dynamic>());
    } on Object {
      return null;
    }
  }

  /// 写设备条目（原子替换）。返回是否写成功——：
  /// 内部仍容错不抛（缓存永不阻塞主流程），但调用方需要真实结果来
  /// 决定指纹记账（写失败时同内容必须能在下轮重试，而非被去重锁死）。
  Future<bool> writeDevice(DeviceCacheEntry entry) async {
    if (_closed) return false;
    try {
      await _devicesRoot.create(recursive: true);
      await _atomicWrite(_deviceFile(entry.deviceSid), jsonEncode(entry.toJson()));
      return true;
    } on Object catch (e) {
      debugPrint('[cache] device write failed (contained): $e');
      return false;
    }
  }

  // -------------------------------------------------------------- cleanup

  /// 配对删除：档案移除时清该设备全部条目（会话目录+设备文件）。
  Future<void> removeDevice(String deviceSid) async {
    if (_closed) return;
    try {
      final dir = _sessionDir(deviceSid);
      if (await dir.exists()) await dir.delete(recursive: true);
      final f = _deviceFile(deviceSid);
      if (await f.exists()) await f.delete();
    } on Object catch (e) {
      debugPrint('[cache] removeDevice failed (contained): $e');
    }
  }

  Future<void> close() async {
    _closed = true;
  }

  bool _closed = false;

  // -------------------------------------------------------------- private

  Future<void> _atomicWrite(File file, String content) async {
    // 批次 2：.tmp 带唯一后缀（同名互踩的防御性消除，成本≈0）。
    final tmp = File('${file.path}.${_tmpSeq++}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }

  int _tmpSeq = 0;

  /// 淘汰：枚举全部会话条目元信息（文件 mtime/size 即记账真值）→
  /// cache_policy.evictSessions → 删除。
  Future<void> _evict() async {
    try {
      final root = _sessionsRoot;
      if (!await root.exists()) return;
      final metas = <SessionCacheMeta>[];
      await for (final devDir in root.list()) {
        if (devDir is! Directory) continue;
        final deviceSid = devDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        await for (final f in devDir.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          final stat = await f.stat();
          final fileName = f.uri.pathSegments.where((s) => s.isNotEmpty).last;
          metas.add(SessionCacheMeta(
            deviceSid,
            fileName.substring(0, fileName.length - 5),
            stat.modified.millisecondsSinceEpoch,
            stat.size,
          ));
        }
      }
      final doomed = evictSessions(metas);
      for (final (dev, sid) in doomed) {
        final f = _sessionFile(dev, sid);
        if (await f.exists()) await f.delete();
      }
    } on Object catch (e) {
      debugPrint('[cache] evict failed (contained): $e');
    }
  }
}

/// 会话缓存写入器（回合静默落盘，阶段 3 设计"写路径"的代码化）：
///
/// attach 到 ConversationState，仅在一致水位（ready + logEpoch 已知 +
/// 非运行中 + 无 streaming 行——即回合结束/收尾帧）后 debounce 3s 落盘；
/// 流式中间态不写。切后台/关工作区前 [flush] 保住最终态。
class SessionCacheWriter {
  SessionCacheWriter({
    required this.store,
    required this.deviceSid,
    required this.sessionId,
    required this.onLog,
  });

  final LocalCacheStore store;
  final String deviceSid;
  final String sessionId;
  final void Function(String line) onLog;

  ConversationState? _state;
  Timer? _timer;
  bool _writing = false;
  ({String logEpoch, int seq, int totalCount, int firstRowId})? _lastPersisted;

  void attach(ConversationState state) {
    _state = state;
    state.addListener(_onChanged);
    _schedule(); // attach 时可能已在一致水位（重开已完成的会话）
  }

  void detach() {
    _timer?.cancel();
    _timer = null;
    _state?.removeListener(_onChanged);
    _state = null;
  }

  /// 立即落盘（demote/关闭前）：不一致水位（流式中）则跳过——中间态
  /// 永不落盘，宁可少一次更新。
  Future<void> flush() async {
    final state = _state;
    if (state == null || !_atConsistentWatermark(state)) return;
    await _write(state);
  }

  void _onChanged() => _schedule();

  bool _atConsistentWatermark(ConversationState state) =>
      shouldWriteSessionCache(
        ready: state.ready,
        logEpoch: state.logEpoch,
        isRunning: state.isRunning,
        hasStreamingRow: state.rows.any((r) => r['state'] == 'streaming'),
      );

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () {
      final state = _state;
      if (state != null && _atConsistentWatermark(state)) {
        unawaited(_write(state));
      }
    });
  }

  Future<void> _write(ConversationState state) async {
    if (_writing) {
      // B2（2026-10-19 审查）：在途写期间又到一致水位快照（如 debounce
      // 写进行中来了 flush）——原实现静默跳过，落盘停留在旧快照。排队
      // 补写：当前写完成后用最新状态再写一次（防饿死：补写无条件触发，
      // 仅水位不一致时按设计跳过中间态）。
      _pendingAfterWrite = true;
      return;
    }
    _writing = true;
    try {
      final (capFirstRowId, rows) = capRows(state.rows);
      // P3-3：水位未动（logEpoch/seq/条数/游标一致）则免写
      // ——重开已完成会话时 attach 排的 3s 定时器会把与盘上相同的快照
      // 原样重写一遍（设备缓存有内容指纹去重，会话缓存此前没有）。
      // 水位一致即内容一致（delta 必推 seq；快照重放同 seq 同形状），
      // 控制块随水位定格。
      final watermark = (
        logEpoch: state.logEpoch ?? '',
        seq: state.seq,
        totalCount: state.totalCount,
        firstRowId: capFirstRowId ?? state.firstRowId ?? -1,
      );
      if (_lastPersisted == watermark) return;
      final snap = state.snapshot;
      Map<String, dynamic>? control;
      if (snap != null) {
        // 完整控制块原样保存（含 pendingInteractions）——订阅种子必须与
        // base 水位时刻的真状态严格一致（官方水位不变量），清洗只允许
        // 发生在页面预渲层。
        control = Map<String, dynamic>.of(snap)..remove('rows');
      }
      await store.writeSession(SessionCacheEntry(
        deviceSid: deviceSid,
        sessionId: sessionId,
        rows: rows,
        logEpoch: state.logEpoch,
        lastSeq: state.seq,
        firstRowId: capFirstRowId ?? state.firstRowId,
        totalCount: state.totalCount,
        snapshotControl: control,
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 0, // store 写入时测真值
      ));
      onLog(
        '[cache] session saved ${_shortSid(sessionId)}: '
        'rows=${rows.length} epoch=${state.logEpoch} seq=${state.seq}',
      );
      // 成功落盘才记水位（失败路径不记，同水位下轮重试）。
      _lastPersisted = watermark;
    } on Object catch (e) {
      onLog('[cache] session write failed (contained): $e');
    } finally {
      _writing = false;
      if (_pendingAfterWrite) {
        _pendingAfterWrite = false;
        final s = _state;
        if (s != null && _atConsistentWatermark(s)) {
          unawaited(_write(s));
        }
      }
    }
  }

  bool _pendingAfterWrite = false;

  static String _shortSid(String sid) =>
      sid.length <= 8 ? sid : sid.substring(0, 8);
}
