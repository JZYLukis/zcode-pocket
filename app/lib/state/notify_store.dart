import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'notify_core.dart';

/// 通知状态存储（阶段 3 第二段）：
/// - `notify-baselines.json` 差分基线（每设备每任务一条）——进程重启/
///   重连后历史状态不丢，才能正确差分"这个完成是新完成"（官方同款）。
/// - `notifiedInteractions` 已通知审批 id 环形集合（语义去重第二道闸，
///   防基线清理/异常丢失后的重放重发；窗口 7 天容量 500）。
/// - `notify-ledger.jsonl` 通知台账（零漏发以台账核对判定）。
///
/// 全 IO 容错（读失败=空态，写失败=丢弃——通知状态永远不阻塞主流程）；
/// 基线写入 debounce 2s（si 流式期间 cards 频繁刷新）。目录注入以便单测。
class NotifyStore {
  NotifyStore(this.baseDir);

  /// 生产工厂：path_provider 应用支持目录（LocalCacheStore 同款模式）。
  static Future<NotifyStore> createDefault() async {
    final dir = await getApplicationSupportDirectory();
    final root = Directory('${dir.path}${Platform.pathSeparator}notify');
    await root.create(recursive: true);
    return NotifyStore(root);
  }

  final Directory baseDir;

  File get _baselinesFile => File(
    '${baseDir.path}${Platform.pathSeparator}notify-baselines.json',
  );
  File get _ledgerFile => File(
    '${baseDir.path}${Platform.pathSeparator}notify-ledger.jsonl',
  );

  final Map<String, Map<String, PhaseSnapshot>> _baselines = {};
  final List<({String id, int at})> _notifiedInteractions = [];
  final List<LedgerEntry> _recentLedger = [];
  bool _loaded = false;
  Timer? _baselineWriteTimer;

  /// 写链（状态层批，对齐 ComputerStack._deviceWriteChain）：2s 防抖写、
  /// 10s 强写与 flush 此前各自起飞——并发写同一文件靠唯一 tmp 后缀兜底
  /// 不互相破坏，但落盘顺序不受控（后写的旧快照可能覆盖新快照）。
  /// 全部基线写经此链串行，flush 的 await 也因此等到前序写完成。
  Future<void> _baselineWriteChain = Future<void>.value();

  /// 测试缝：注入时钟（防饿死用例不再真等 11×1.1s）。
  @visibleForTesting
  int Function() nowMs = _defaultNow;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  Future<void> _enqueueBaselineWrite() {
    final write = _baselineWriteChain.then((_) => _writeBaselines());
    _baselineWriteChain = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  static const _maxInteractions = 500;
  static const _interactionWindowMs = 7 * 24 * 3600 * 1000;
  static const _maxLedgerLines = 2000;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _baselinesFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((sid, tasks) {
          if (tasks is Map) {
            final map = <String, PhaseSnapshot>{};
            tasks.forEach((taskId, snap) {
              if (snap is Map) {
                map['$taskId'] = PhaseSnapshot.fromJson(
                  snap.cast<String, dynamic>(),
                );
              }
            });
            _baselines['$sid'] = map;
          }
        });
        final notified = decoded['notifiedInteractions'];
        if (notified is List) {
          for (final e in notified) {
            if (e is Map) {
              _notifiedInteractions.add((
                id: '${e['id'] ?? ''}',
                at: (e['at'] as num?)?.toInt() ?? 0,
              ));
            }
          }
        }
      }
    } catch (_) {
      // 读失败=空基线（首见逻辑兜底，不会误发）
    }
    try {
      final lines = await _ledgerFile.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          _recentLedger.add(
            LedgerEntry.fromJson(
              (jsonDecode(line) as Map).cast<String, dynamic>(),
            ),
          );
        } catch (_) {}
      }
    } catch (_) {}
    _pruneInteractions(nowMs());
  }

  // ------------------------------------------------------------- baselines

  Map<String, PhaseSnapshot> baselinesOf(String deviceSid) =>
      _baselines[deviceSid] ?? {};

  void replaceBaselines(
    String deviceSid,
    Map<String, PhaseSnapshot> next,
  ) {
    _baselines[deviceSid] = next;
    // 最大等待 10s（防饿死）：活跃会话每秒 upsert 会让 2s 防抖无限
    // 顺延——强杀时盘上基线停在旧值，死亡窗口的完成变成"完成vs完成"
    // 无差异，补发失效（介入点2真机实锤 2026-10-19 自证轮）。
    final now = nowMs();
    if (now - _lastBaselineWriteAt > 10000) {
      _writeBaselinesNow();
      return;
    }
    _scheduleWrite();
  }

  int _lastBaselineWriteAt = 0;

  void _writeBaselinesNow() {
    _lastBaselineWriteAt = nowMs();
    unawaited(_enqueueBaselineWrite());
  }

  void dropDevice(String deviceSid) {
    _baselines.remove(deviceSid);
    _scheduleWrite();
  }

  void _scheduleWrite() {
    _baselineWriteTimer?.cancel();
    _baselineWriteTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_enqueueBaselineWrite()),
    );
  }

  Future<void> _writeBaselines() async {
    final now = nowMs();
    // H1-P3-08：任意写入口统一刷新基准——10s 强写判定此前
    // 只认 _writeBaselinesNow/flush，防抖写刚落盘又立刻强写一次同内容。
    _lastBaselineWriteAt = now;
    _pruneInteractions(now);
    try {
      final payload = <String, dynamic>{
        for (final e in _baselines.entries)
          e.key: {
            for (final t in e.value.entries) t.key: t.value.toJson(),
          },
        'notifiedInteractions': [
          for (final e in _notifiedInteractions) {'id': e.id, 'at': e.at},
        ],
      };
      // 批次 2：.tmp 唯一后缀（2s 防抖与 10s 强写理论窗口互踩的防御消除）。
      final tmp = File('${_baselinesFile.path}.${_tmpSeq++}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(_baselinesFile.path);
    } catch (_) {
      // 写失败丢弃（下次再试）
    }
  }

  void _pruneInteractions(int nowMs) {
    _notifiedInteractions.removeWhere((e) => nowMs - e.at > _interactionWindowMs);
    while (_notifiedInteractions.length > _maxInteractions) {
      _notifiedInteractions.removeAt(0);
    }
  }

  // ------------------------------------------------- 语义去重（第二道闸）

  /// 该审批 id 是否已通知过（已处理/autoResolution 到期后再见 pending
  /// 不重发——Tactic 借鉴，差分基线之外的第二道闸）。
  bool interactionNotified(String id) =>
      id.isEmpty ||
      _notifiedInteractions.any((e) => e.id == id);

  void markInteractionNotified(String id, int atMs) {
    if (id.isEmpty) return;
    _notifiedInteractions.add((id: id, at: atMs));
    _pruneInteractions(atMs);
    _scheduleWrite();
  }

  // ---------------------------------------------------------------- ledger

  Future<void> appendLedger(LedgerEntry entry, {bool rewriteAll = false}) async {
    final overflowed = _recentLedger.length >= _maxLedgerLines;
    _recentLedger.add(entry);
    while (_recentLedger.length > _maxLedgerLines) {
      _recentLedger.removeAt(0);
    }
    try {
      if (rewriteAll || overflowed || !await _ledgerFile.exists()) {
        await _rewriteLedgerFile();
      } else {
        // 常规追加直接写目标文件（JSONL 追加不适合 rename 轮换；
        // 崩溃残行由读取侧逐行容错兜住）。
        await _ledgerFile.writeAsString(
          '${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    } catch (_) {
      // 台账写失败不阻塞通知主流程（内存台账仍在）
    }
  }

  /// 台账尾部（设置页"通知台账"查看 + 零漏发核对入口）。
  List<LedgerEntry> recentLedger({int limit = 200}) =>
      _recentLedger.length <= limit
          ? List.unmodifiable(_recentLedger)
          : List.unmodifiable(
              _recentLedger.sublist(_recentLedger.length - limit),
            );

  /// 点击回填（通知被点开后标记，供真用期数据参考）。低频事件，
  /// 原位改内存 + 全量重写文件——不经 appendLedger（它会再 add 一行，
  /// 同事件重复两行，发现9）。
  Future<void> markClicked(String taskId, int atMs) async {
    for (final e in _recentLedger.reversed) {
      // H1-P3-02：只回填 posted 行——同任务先 muted/deduped
      // 后又 posted 时（noChannel→posted 重试成对出现），不按 outcome
      // 过滤会标在最近一条非 posted 行上，真实 posted 行 clicked 恒 false。
      if (e.taskId == taskId && !e.clicked && e.outcome == 'posted') {
        final idx = _recentLedger.indexOf(e);
        _recentLedger[idx] = LedgerEntry(
          ts: e.ts,
          kind: e.kind,
          deviceSid: e.deviceSid,
          taskId: e.taskId,
          title: e.title,
          outcome: e.outcome,
          clicked: true,
        );
        try {
          await _rewriteLedgerFile();
        } catch (_) {}
        break;
      }
    }
  }

  Future<void> _rewriteLedgerFile() async {
    // 全量重写（≤2000 行，规模可控）；tmp+rename 原子替换（唯一后缀）。
    final tmp = File('${_ledgerFile.path}.${_tmpSeq++}.tmp');
    final buf = StringBuffer();
    for (final e in _recentLedger) {
      buf.writeln(jsonEncode(e.toJson()));
    }
    await tmp.writeAsString(buf.toString(), flush: true);
    await tmp.rename(_ledgerFile.path);
  }

  Future<void> flush() async {
    _baselineWriteTimer?.cancel();
    _baselineWriteTimer = null;
    _lastBaselineWriteAt = nowMs();
    await _enqueueBaselineWrite();
  }

  @visibleForTesting
  void debugForceWrite() {
    _baselineWriteTimer?.cancel();
    _baselineWriteTimer = null;
    unawaited(_enqueueBaselineWrite());
  }

  /// 等写链排空（测试/收尾用；生产 dispose 不阻塞）。
  @visibleForTesting
  Future<void> debugDrainWrites() => _baselineWriteChain;

  int _tmpSeq = 0;
}
