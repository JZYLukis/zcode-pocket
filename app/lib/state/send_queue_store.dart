import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 断网消息排队（阶段 6.6②，2026-10-29 批次）：断连期（90s 后台断连
/// 窗口/冷启动未连/切工作区期）发送的消息入队，重连后自动按序发出。
///
/// 安全边界（ 结果未知红线）：队列**只装从未发起过发送的消息**
/// ——入队发生在"无桥前置判定"，不经 RPC；发送在途/半途失败仍走会话页
/// 既有暂存与「结果未知」机制，永不自动重发已尝试过的发送。
class SendQueueEntry {
  final String id;
  final String text;

  /// 该桶的新建草稿排队时携带的挂起选型快照
  /// （provider/model/thought/mode/planEnabled，随首条消息创建会话）。
  final Map<String, dynamic>? config;
  final int queuedAt;

  /// ：首次重放前分配并持久化的 commandId——
  /// accepted 后、出队落盘前崩溃的窗口里，重启重放沿用同一 ID（服务端
  /// 幂等表去重），守住"永不自动重发已尝试发送"红线。
  final String? commandId;

  const SendQueueEntry({
    required this.id,
    required this.text,
    this.config,
    required this.queuedAt,
    this.commandId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    if (config != null) 'config': config,
    'queuedAt': queuedAt,
    if (commandId != null) 'commandId': commandId,
  };

  static SendQueueEntry? fromJson(Map<String, dynamic> raw) {
    final id = '${raw['id'] ?? ''}'.trim();
    final text = '${raw['text'] ?? ''}';
    if (id.isEmpty || text.trim().isEmpty) return null;
    final config = raw['config'];
    final commandId = '${raw['commandId'] ?? ''}'.trim();
    final queuedAt = raw['queuedAt'];
    return SendQueueEntry(
      id: id,
      text: text,
      config: config is Map ? config.cast<String, dynamic>() : null,
      // P1-1：queuedAt 非 num（损坏/历史版本/外来写入）此前
      // `as num?` 直接抛 TypeError——从 _ensureLoaded 一路抛穿致 _loaded
      // 永不置位，整库永久哑弹（entries 恒空、add 静默丢消息）。
      queuedAt: queuedAt is num ? queuedAt.toInt() : 0,
      commandId: commandId.isEmpty ? null : commandId,
    );
  }
}

/// 待发队列的桶键（与会话页草稿同维隔离：电脑/账号/工作区/会话或新建）。
class SendQueueBucket {
  final String deviceSid;
  final String accountId;
  final String workspaceKey;
  final String scopeId;

  const SendQueueBucket({
    required this.deviceSid,
    required this.accountId,
    required this.workspaceKey,
    required this.scopeId,
  });

  String get key => jsonEncode([deviceSid, accountId, workspaceKey, scopeId]);
}

/// 队列存储：单文件原子写+操作串行（对齐 DraftStore 的持久化纪律）；
/// 单条形态异常跳过不拖垮整库；写盘串行尾巴（多次变更合并为最终态）。
/// P3-4/E3-P3-8：entriesChanged 回调全库无人接线（UI 实际
/// 经页面手动 refresh），死代码已删。
class SendQueueStore {
  SendQueueStore(this._file);

  static Future<SendQueueStore> createDefault() async {
    final dir = await getApplicationSupportDirectory();
    return SendQueueStore(
      File('${dir.path}${Platform.pathSeparator}send-queue.json'),
    );
  }

  final File _file;
  final Map<String, List<SendQueueEntry>> _buckets = {};
  Future<void> _operations = Future.value();
  Future<void> _diskTail = Future.value();
  bool _loaded = false;
  bool _closed = false;

  Future<T> _serial<T>(FutureOr<T> action()) {
    final previous = _operations;
    final completer = Completer<T>();
    _operations = previous.catchError((_) {}).then((_) async {
      try {
        await _ensureLoaded();
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    if (!await _file.exists()) {
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) {
        throw const FormatException('unsupported send queue store');
      }
      // P2-3：buckets 缺失/非 Map 此前被当"合法空库"装载
      // → 下一次 add 全量覆盖原文件=磁盘上待发消息静默清空。对齐
      // DraftStore 的防御 throw，落进下方隔离自愈路径。
      final buckets = decoded['buckets'];
      if (buckets is! Map) {
        throw const FormatException('missing buckets map');
      }
      for (final e in buckets.entries) {
        final list = e.value;
        if (list is! List) continue;
        final entries = <SendQueueEntry>[];
        for (final raw in list) {
          // P1-1：逐条 try/on（对齐 DraftStore）——单条形态
          // 异常（类型错乱/畸形）跳过不拖垮整库。
          try {
            if (raw is! Map) continue;
            final entry = SendQueueEntry.fromJson(
              raw.cast<String, dynamic>(),
            );
            if (entry != null) entries.add(entry);
          } on Object catch (error) {
            debugPrint('[send-queue] entry unparsable, skipped: $error');
          }
        }
        if (entries.isNotEmpty) _buckets['${e.key}'] = entries;
      }
    } on Object catch (error) {
      // P1-1/E2-P2-1/E3-P1-1（库损坏静默失效三路）：整库级
      // 失败此前不置 loaded → entries 恒空（已排队消息永不重放）、add 被
      // catchError 静默吞（UI 清了输入框但什么都没发生）、零日志。隔离
      // 自愈：坏文件改名 .corrupt 保留（人工可找回），重建空库继续服务；
      // rename 失败保持失败态——绝不拿空库覆盖原文件。
      try {
        await _file.rename('${_file.path}.corrupt');
      } on Object {
        debugPrint('[send-queue] store corrupt; quarantine failed: $error');
        rethrow;
      }
      debugPrint('[send-queue] store corrupt; quarantined .corrupt, reset');
      _loaded = true;
      return;
    }
    _loaded = true;
  }

  Future<List<SendQueueEntry>> entries(SendQueueBucket bucket) =>
      _serial(
    () => List<SendQueueEntry>.unmodifiable(
      _buckets[bucket.key] ?? const <SendQueueEntry>[],
    ),
  )
          .catchError((_) => const <SendQueueEntry>[]);

  /// 每桶条目软上限（P3-6：断网期可连发任意多条，队列文件
  /// 无界增长且重连后 120ms 间隔连发洪泛——超限丢最旧并留痕）。
  static const maxQueuedEntries = 50;

  /// 入队（追加队尾）。
  Future<void> add(SendQueueBucket bucket, SendQueueEntry entry) =>
      _serial<void>(() {
        if (_closed) return;
        final list = _buckets.putIfAbsent(bucket.key, () => [])..add(entry);
        if (list.length > maxQueuedEntries) {
          debugPrint(
            '[send-queue] bucket overflow (${list.length}); dropping oldest',
          );
          list.removeRange(0, list.length - maxQueuedEntries);
        }
        _scheduleWrite();
      }).catchError((_) {});

  /// 消费一条（flush 成功后移除）。
  Future<void> remove(SendQueueBucket bucket, String id) =>
      _serial<void>(() {
        if (_closed) return;
        final list = _buckets[bucket.key];
        if (list == null) return;
        final before = list.length;
        list.removeWhere((e) => e.id == id);
        if (list.isEmpty) _buckets.remove(bucket.key);
        if (list.length != before || _buckets[bucket.key] == null) {
          _scheduleWrite();
        }
      }).catchError((_) {});

  /// 删任务/归档联动（与会话草稿同点位调用）。
  Future<void> removeSession(String deviceSid, String sessionId) =>
      _serial<void>(() {
        if (_closed) return;
        final scope = 'session:$sessionId';
        final before = _buckets.length;
        _buckets.removeWhere((key, list) {
          final parts = _parseKey(key);
          return parts != null && parts[0] == deviceSid && parts[3] == scope;
        });
        if (_buckets.length != before) _scheduleWrite();
      }).catchError((_) {});

  /// 删电脑联动。
  Future<void> removeDevice(String deviceSid) => _serial<void>(() {
    if (_closed) return;
    final before = _buckets.length;
    _buckets.removeWhere((key, list) {
      final parts = _parseKey(key);
      return parts != null && parts[0] == deviceSid;
    });
    if (_buckets.length != before) _scheduleWrite();
  }).catchError((_) {});

  List<String>? _parseKey(String key) {
    try {
      final decoded = jsonDecode(key);
      if (decoded is List && decoded.length == 4) {
        return decoded.map((e) => '$e').toList();
      }
    } on Object {
      // 形态异常的桶键原样保留（不误删）。
    }
    return null;
  }

  void _scheduleWrite() {
    // 写盘串行尾巴：每次变更取当前内存态全量落盘，后来的写自然覆盖
    // 先到的（最终一致）；失败不中断队列（下次变更再写）。
    _diskTail = _diskTail.catchError((_) {}).then((_) => _write());
  }

  Future<void> _write() async {
    try {
      final payload = jsonEncode({
        'version': 1,
        'buckets': {
          for (final e in _buckets.entries)
            e.key: [for (final entry in e.value) entry.toJson()],
        },
      });
      final tmp = File('${_file.path}.tmp');
      await _file.parent.create(recursive: true);
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(_file.path);
    } catch (e) {
      debugPrint('[send-queue] write failed: $e');
    }
  }

  /// ：为条目钉住 commandId（首次重放前调用，
  /// 持久化先于发送——崩溃窗口内重启后沿用同一 ID 重放，服务端幂等表
  /// 去重，守住"永不自动重发已尝试发送"红线）。
  Future<void> setCommandId(
    SendQueueBucket bucket,
    String entryId,
    String commandId,
  ) => _serial<void>(() {
    if (_closed) return;
    final list = _buckets[bucket.key];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == entryId && e.commandId == null);
    if (idx < 0) return;
    list[idx] = SendQueueEntry(
      id: list[idx].id,
      text: list[idx].text,
      config: list[idx].config,
      queuedAt: list[idx].queuedAt,
      commandId: commandId,
    );
    _scheduleWrite();
  }).catchError((_) {});

  /// 退后台即时落盘。：先等操作队列再等盘
  /// 尾——此前只等 _diskTail，仍在 _operations 排队的 add 不在盘尾里，
  /// 退后台瞬杀可丢"UI 已显示排队"的消息（对齐 DraftStore 语义）。
  Future<void> flush() async {
    await _operations;
    await _diskTail;
  }

  /// close 先等已入链的盘尾写完成再关门（P2-2：原实现只置
  /// _closed 不等盘尾——dispose→进程退出的窗口里最后一次 add/remove 的
  /// 落盘可丢；对齐 DraftStore.close 的先 flush 语义）。
  Future<void> close() => _serial<void>(() async {
    await _diskTail;
    _closed = true;
  }).catchError((_) {});
}
