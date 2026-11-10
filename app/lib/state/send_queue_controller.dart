import 'dart:async';

import '../transport/id.dart';
import 'app_state.dart';
import 'send_queue_store.dart';

/// 会话页向离线队列提供的窄端口；发送、草稿和附件状态仍归页面。
class OfflineQueueHost {
  final SendQueueBucket? Function() bucketProvider;
  final bool Function() isAlive;
  final bool Function() readOnly;
  final bool Function() sending;
  final Future<bool> Function(SendQueueEntry entry) replay;
  final void Function() onNotify;
  final void Function(void Function() action) scheduleDrain;

  const OfflineQueueHost({
    required this.bucketProvider,
    required this.isAlive,
    required this.readOnly,
    required this.sending,
    required this.replay,
    required this.onNotify,
    required this.scheduleDrain,
  });
}

/// 离线发送队列控制链：存储读取、串行 drain、online 边沿与失败重试。
class OfflineSendQueueController {
  OfflineSendQueueController({
    required this.host,
    this.retryDelay = const Duration(seconds: 15),
    this.interEntryDelay = const Duration(milliseconds: 120),
  });

  final OfflineQueueHost host;
  final Duration retryDelay;
  final Duration interEntryDelay;

  List<SendQueueEntry> entries = const [];
  bool expanded = false;
  bool _draining = false;
  bool _watchArmed = false;
  bool _disposed = false;
  AppState? _app;
  LinkPhase? _lastPhase;

  /// 桥身份（重建/首次连上的边沿）：恢复即重放——不依赖 phase 变化
  /// （断连期 phase 可能一路 online 只是桥为 null 或已换新实例），也不
  /// 破坏失败后的 15s 退避（同桥同 phase 的 notify 不旁路）。
  Object? _lastBridge;
  Timer? _retryTimer;

  bool get draining => _draining;

  void arm(AppState app, {Future<void>? draftRestore}) {
    if (_watchArmed || _disposed || host.readOnly()) return;
    _watchArmed = true;
    _app = app;
    _lastPhase = app.phase;
    _lastBridge = app.bridge;
    app.addListener(_onAppChanged);
    unawaited(refresh());
    if (draftRestore != null) {
      // A1-P1/A2-P1-1（离线开页死锁）：bucketProvider 依赖页面
      // _draftIdentity——它在 draftRestore 内部异步就绪，arm 的同步
      // refresh 必然空跑（bucket==null 直接 return）。恢复完成后先重试
      // 装载再 drain：离线开页时已持久化的排队条目才能显示（可撤销），
      // online 边沿的 entries 门才有数据可比。
      // P3-9：whenComplete 会透传上游错误（unawaited 链上
      // 成 zone 未处理异步错误）——catchError 兜住。
      unawaited(
        draftRestore
            .whenComplete(() async {
              await refresh();
              await drain();
            })
            .catchError((_) {}),
      );
    } else {
      unawaited(drain());
    }
  }

  void _onAppChanged() {
    final app = _app;
    if (app == null || _disposed) return;
    final phase = app.phase;
    final backOnline =
        _lastPhase != null && _lastPhase != LinkPhase.online && phase == LinkPhase.online;
    _lastPhase = phase;
    final bridge = app.bridge;
    final bridgeRestored = bridge != null && !identical(_lastBridge, bridge);
    _lastBridge = bridge;
    if ((backOnline || bridgeRestored) && !_draining) {
      // A1-P1：online 边沿不信任内存 entries——离线开页时
      // 装载窗口可能错过，先查 store 重载后再判 drain。
      _retryTimer?.cancel();
      host.scheduleDrain(() async {
        await refresh();
        if (entries.isNotEmpty && !_draining) unawaited(drain());
      });
      return;
    }
    // P2-3：非边沿的 notify 驱动不得旁路 15s 失败退避——
    // replay 持续失败时（如新建桶陈旧选型被目录校验拒绝），每次
    // AppState notify（relay failure/引导事件）都会立即重走完整发送
    // 路径+刷错误横幅，退避形同虚设。退避计时器在场=由它统一驱动；
    // online 边沿分支（上方）显式 cancel 后不受此门控。
    if (app.bridge != null &&
        entries.isNotEmpty &&
        !_draining &&
        _retryTimer == null) {
      host.scheduleDrain(() => unawaited(drain()));
    }
  }

  Future<void> refresh() async {
    final app = _app;
    final store = app?.sendQueue;
    final bucket = host.bucketProvider();
    if (store == null || bucket == null) return;
    final next = await store.entries(bucket);
    if (!host.isAlive() || _disposed) return;
    final same =
        next.length == entries.length &&
        [for (final e in next) e.id].join('\u0000') ==
            [for (final e in entries) e.id].join('\u0000');
    if (same) return;
    entries = next;
    host.onNotify();
  }

  Future<void> drain() async {
    if (_draining || host.sending() || !host.isAlive() || host.readOnly()) {
      return;
    }
    final app = _app;
    if (app == null || _disposed) return;
    if (app.bridge == null || app.phase != LinkPhase.online) {
      _lastPhase = app.phase;
      // A2-P1-1：离线早退也要装载——持久化的排队条目先显示
      // （排队条可见/可撤销），重连边沿再补发。
      await refresh();
      return;
    }
    final store = app.sendQueue;
    final bucket = host.bucketProvider();
    if (store == null || bucket == null) return;
    _draining = true;
    var hadFailure = false;
    try {
      while (host.isAlive() && !_disposed) {
        final current = await store.entries(bucket);
        if (current.isEmpty) break;
        var entry = current.first;
        var replayCommandId = entry.commandId;
        if (replayCommandId == null) {
          replayCommandId = generateUuid();
          await store.setCommandId(bucket, entry.id, replayCommandId);
          // P1-1/E3-P2-1（双发红线）：setCommandId 只等内存
          // 不等盘尾——进程在「服务端已接受该 commandId」后、落盘 rename
          // 完成前被杀，重启换新 ID 重放=同消息双发（ 红线）。
          // 先 await flush（操作队列+盘尾写全部落定）再发起发送。
          await store.flush();
          entry = SendQueueEntry(
            id: entry.id,
            text: entry.text,
            config: entry.config,
            queuedAt: entry.queuedAt,
            commandId: replayCommandId,
          );
        }
        // P3-9：撤销与 drain 拾取竞态——pickup 后、replay 前
        // 用户撤销该条（cancel 只删存储）。replay 前二次确认条目仍是
        // 队首：已被撤销/消费则本轮终止（尚未发起发送，撤销语义成立）。
        final confirm = await store.entries(bucket);
        if (confirm.isEmpty || confirm.first.id != entry.id) break;
        // A2-P1-2：单条重放的意外异常不再外泄（unawaited 链上
        // 是 zone 未处理错误）——按失败同语义处理（条目留存，commandId
        // 幂等保护下走 15s 重试），不中断其余条目的消费链。
        var ok = false;
        try {
          ok = await host.replay(entry);
        } catch (_) {
          ok = false;
        }
        if (!ok) {
          hadFailure = true;
          break;
        }
        await store.remove(bucket, entry.id);
        await Future<void>.delayed(interEntryDelay);
      }
    } finally {
      _draining = false;
      await refresh();
      _retryTimer?.cancel();
      if (hadFailure && host.isAlive() && entries.isNotEmpty && !_disposed) {
        _retryTimer = Timer(retryDelay, () {
          if (host.isAlive() && !_draining && !_disposed) unawaited(drain());
        });
      }
    }
  }

  Future<void> cancel(SendQueueEntry entry) async {
    final store = _app?.sendQueue;
    final bucket = host.bucketProvider();
    if (store == null || bucket == null) return;
    await store.remove(bucket, entry.id);
    await refresh();
  }

  void toggleExpanded() {
    expanded = !expanded;
    host.onNotify();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _app?.removeListener(_onAppChanged);
    _retryTimer?.cancel();
    _retryTimer = null;
  }
}
