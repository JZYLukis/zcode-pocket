import 'dart:async';

import 'package:flutter/foundation.dart';

import '../transport/conversation.dart' show SessionEntry;
import 'computer_stack.dart';
import 'notify_core.dart';
import 'notify_store.dart';
import 'task_list.dart';

/// 通知协调器（阶段 3 第二段核心）：挂接各电脑栈的任务列表，
/// 快照差分 → 语义去重 → 通道静音 → 台账 → 安卓通知； suspend/resume
/// 周期的对账聚合（"你不在时完成了 N 个任务"）与回前台清过时。
///
/// 设计原则（phase3-notify-design）：通知层不感知连接档位——它只消费
/// 事件流；保活/断连是连接层（AppState 策略 + ComputerStack）的事。
class NotifyCoordinator {
  NotifyCoordinator({
    required this.store,
    required this.onPost,
    this.shouldSuppress,
  });

  final NotifyStore store;

  /// 发通知出口（NotificationService.post + 设备标签由调用方拼）。
  final Future<bool> Function(NotifyEvent event) onPost;

  /// 查看中抑制谓词（AppState 注入：会话页前台打开时该任务事件不发
  /// 通知——用户看得见界面，通知是噪音；台账记 viewing 留证据）。
  final bool Function(String taskId)? shouldSuppress;

  /// 通道静音矩阵（UiPrefs 驱动；null=不静音全开）。
  Set<NotifyChannel> mutedChannels = const {};

  static const _reconcileWindow = Duration(seconds: 2);

  final Map<String, ComputerStack> _stacks = {};
  final Map<String, TaskListModel> _watched = {};
  final Map<String, void Function()> _removers = {};

  /// 每 stack 最后一次 live 数据时刻（模型换代 mini 对账的水位源）。
  final Map<String, int> _lastLiveAt = {};

  /// 冷启动对账挂起（介入点 2 真机实锤修复 2026-10-19）：进程被杀
  /// （系统回收/划掉）期间完成的任务，重启后首个 live 快照走"非对账
  /// 只收敛基线"被静默吞掉——"杀后台轮无通知"根因。每个栈的首次
  /// live 快照以基线最大 lastActivityAt 为水位做一轮对账（与 suspend
  /// 水位同语义；无基线=首装，正常首见）。
  final Set<String> _coldStartPending = {};

  /// 对账挂起：deviceSid → 水位时间（suspend 时刻）。
  final Map<String, int> _pendingReconcile = {};
  Map<String, List<NotifyEvent>> _reconcileBuffer = {};
  Timer? _reconcileTimer;
  Timer? _clearStaleTimer;
  int Function() nowMs = _defaultNow;

  /// 测试缝（2026-10-29 批次·测试稳定性根治）：对账防抖计时器是否在途
  /// ——测试的固定 2.1s 等待在满载套件下偶发不足（"写盘饿死"家族，
  /// 负载把 2s 防抖窗口拉长），改轮询本缝确定性收口。生产禁止依赖。
  @visibleForTesting
  bool get debugReconcileTimerActive => _reconcileTimer?.isActive ?? false;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  /// 挂接一个栈（AppState 建栈时调用；重复挂接幂等）。
  /// ：已 dispose 的幽灵栈不得挡住新栈重挂——换账号
  /// 重连/auth-required 等拆栈路径不 detach 时，旧 map 条目会让新栈的
  /// 通知静默永久失效（attachStack 被 containsKey 短路）。
  void attachStack(ComputerStack stack) {
    final sid = stack.profile.deviceSid;
    final old = _stacks[sid];
    if (old != null && !identical(old, stack) && !old.disposed) return;
    _stacks[sid] = stack;
    _coldStartPending.add(sid);
    // 任务列表在栈生命周期里会多次重建（切工作区/复活/缓存预渲）——
    // 经栈级回调跟随重挂。
    stack.onTaskListRebuilt = (model) => _watch(sid, model);
    _watch(sid, stack.taskList);
  }

  /// [ifStack]（状态层批）：按栈身份摘除——拆旧栈的 dispose await 窗口
  /// 内同 sid 可能已建新栈入表（removeComputer 收尾竞态），无边界的
  /// detach 会把新栈的监听/持久基线一起摘掉（新连接在、通知永久静默）。
  void detachStack(String deviceSid, {ComputerStack? ifStack}) {
    if (ifStack != null && !identical(_stacks[deviceSid], ifStack)) {
      return;
    }
    _removers.remove(deviceSid)?.call();
    _removers.remove(deviceSid);
    _watched.remove(deviceSid);
    final stack = _stacks.remove(deviceSid);
    stack?.onTaskListRebuilt = null;
    _pendingReconcile.remove(deviceSid);
    _coldStartPending.remove(deviceSid);
    _lastLiveAt.remove(deviceSid);
    store.dropDevice(deviceSid);
  }

  /// 保活后台检测到 relay 掉线时按设备记对账水位（状态层批）：连接断开
  /// 期间的事件不会再走逐条 upsert，恢复后首个 si 快照必须走对账模式
  /// （水位之后的完成/首见事件才可见）。只在"确实掉过线"时写——无条件
  /// 写会把后台实时通知吞进聚合缓冲。
  void markPendingReconcile(String deviceSid, {int? atMs}) {
    if (!_stacks.containsKey(deviceSid)) return;
    _pendingReconcile.putIfAbsent(deviceSid, () => atMs ?? nowMs());
  }

  @visibleForTesting
  bool debugAttachedForTest(String deviceSid) => _stacks.containsKey(deviceSid);

  @visibleForTesting
  Map<String, int> get debugPendingReconcile =>
      Map<String, int>.of(_pendingReconcile);

  void _watch(String deviceSid, TaskListModel? model) {
    final prev = _watched[deviceSid];
    if (identical(prev, model)) return;
    _removers.remove(deviceSid)?.call();
    if (model != null) {
      // live 模型换代（relay 闪断重连/si 重订阅/复活）而栈没经过
      // suspend——换代前后的数据缺口无人对账会静默丢事件（发现6）。
      // 以旧模型最后活帧时间为水位做 mini 对账；suspend 路径已有更准的
      // 水位（onSuspended），不覆盖。
      if (prev != null &&
          !_pendingReconcile.containsKey(deviceSid) &&
          model.cachePreview == false) {
        final lastLive = _lastLiveAt[deviceSid];
        if (lastLive != null && nowMs() - lastLive > 5000) {
          _pendingReconcile[deviceSid] = lastLive;
        }
      }
      void listener() => _onCards(deviceSid, model);
      model.addListener(listener);
      // 逐条 upsert 事件源（常规差分路径——聚合 cards 监听看不到同帧
      // 批量 upsert 的中间态，见 SessionsIndexState.onUpserted 注释）。
      final si = model.sessions;
      si.onUpserted = (entry) => _onUpsert(deviceSid, entry);
      _watched[deviceSid] = model;
      _removers[deviceSid] = () {
        model.removeListener(listener);
        si.onUpserted = null;
      };
      _onCards(deviceSid, model);
    } else {
      _watched.remove(deviceSid);
      _removers.remove(deviceSid);
    }
  }

  // ------------------------------------------------------------ 快照差分

  /// 从任务卡提取差分快照（pendingInteraction 摘要含 interactionId，
  /// 官方 sessions-index.ts:12-18；：toolName/preview 与 si 行同透传
  /// ——对账路径的审批/完成文案不缺素材）。
  @visibleForTesting
  static Map<String, PhaseSnapshot> snapshotsOf(List<TaskCardData> cards) => {
    for (final c in cards)
      c.sessionId: PhaseSnapshot(
        phase: c.phase,
        interactionId: _normalizeInteractionId(c.pendingInteraction),
        pendingKind: c.pendingInteraction == null
            ? null
            : '${c.pendingInteraction!['kind'] ?? ''}',
        pendingTool: c.pendingInteraction == null
            ? null
            : '${c.pendingInteraction!['toolName'] ?? ''}'.trim().isEmpty
            ? null
            : '${c.pendingInteraction!['toolName']}',
        goalStatus: c.goalStatus,
        title: c.title,
        preview: c.preview,
        lastActivityAt: c.lastActivityAt,
      ),
  };

  /// pendingInteraction 的 interactionId（空/缺失归一化为 null——官方
  /// 清除 pending 是键缺席而非置 null，refs sessions-index-projection
  /// :87；空串当 pending 会误产审批事件）。
  static String? _normalizeInteractionId(Map<String, dynamic>? pending) {
    if (pending == null) return null;
    final id = '${pending['interactionId'] ?? ''}'.trim();
    return id.isEmpty ? null : id;
  }

  /// si 原始 phase 归一化（si 官方只发六值域，但任务索引词汇
  /// completed/failed 一旦漏进来也不至于判不中终态——发现14）。
  /// 补 'cancelled'（对齐 task_list.normalizePhase
  /// 词表——两词表不一致会让同一条 si 行在 upsert 与 cards 两路径产出
  /// 不同 phase，基线双值翻转产生多余基线写与无谓 diff）。
  static String _normalizePhase(String raw) {
    switch (raw) {
      case 'completed':
        return 'completedSuccess';
      case 'failed':
        return 'error';
      case 'cancelled':
        return 'completedInterrupted';
      default:
        return raw;
    }
  }

  void _onCards(String deviceSid, TaskListModel model) {
    if (model.cachePreview) {
      // 预渲=陈旧快照：不建基线（stale running 会在 live 重放误报完成）、
      // 不消费水位（发现1）。等 live 模型/快照。
      return;
    }
    // 聚合快照路径职责：①对账（水位后的全量重放对账）；②基线与列表现实
    // 收敛（upsert 流之外的增删——归档/删除/历史任务）。
    // 常规事件不走这里（帧内批量 upsert 吞中间态——见
    // SessionsIndexState.onUpserted 注释）。
    final cards = model.cards;
    if (cards.isEmpty) {
      // si 未重放（新建模型首帧空列表）：对账等待；非对账时空卡是
      // 瞬态（快照未到），清基线会造成窗口内事件丢失（发现11）。
      // 冷启动标记也不消费——等真正的快照。
      return;
    }
    var sinceMs = _pendingReconcile[deviceSid];
    if (sinceMs == null && _coldStartPending.remove(deviceSid)) {
      // 冷启动首个 live 快照：进程死亡期间完成的对账（水位=基线里
      // 最大 lastActivityAt ≈ 最后见到活数据的时刻）。
      var maxTs = 0;
      store.baselinesOf(deviceSid).forEach((_, s) {
        if (s.lastActivityAt > maxTs) maxTs = s.lastActivityAt;
      });
      if (maxTs > 0) sinceMs = maxTs;
    }
    _lastLiveAt[deviceSid] = nowMs();
    final baselines = store.baselinesOf(deviceSid);
    final result = diffSnapshots(
      deviceSid,
      baselines,
      snapshotsOf(cards),
      atMs: nowMs(),
      reconcile: sinceMs != null,
      sinceMs: sinceMs,
    );
    if (sinceMs != null) {
      // 对账模式：事件进聚合缓冲（跨设备汇总后一条聚合+高优先级单发），
      // 同步收敛基线（空事件也要写——断连期间新建的任务才能进基线，
      // 否则其后续完成被首见吞掉，发现5）。窗口内逐条路径已并入的
      // 事件合并而非覆盖。
      _pendingReconcile.remove(deviceSid);
      if (result.events.isNotEmpty) {
        final buffer = _reconcileBuffer.putIfAbsent(deviceSid, () => []);
        buffer.addAll(result.events);
        _reconcileTimer?.cancel();
        _reconcileTimer = Timer(_reconcileWindow, _flushReconcile);
      }
      // merge 而非整体替换——current 只是当前工作区
      // cards 的快照，整体替换会清零其他工作区任务基线。
      store.replaceBaselines(
        deviceSid,
        mergeBaselines(baselines, result.nextBaselines),
      );
      return;
    }
    // 非对账：只收敛基线（常规事件由 _onUpsert 逐条产出）。merge 保留
    // 其他工作区条目（语义见 mergeBaselines 注释）。
    store.replaceBaselines(
      deviceSid,
      mergeBaselines(baselines, result.nextBaselines),
    );
  }

  /// 逐条 upsert 差分（常规事件源）。
  void _onUpsert(String deviceSid, SessionEntry entry) {
    final now = _snapshotOfEntry(entry);
    final baselines = store.baselinesOf(deviceSid);
    final old = baselines[entry.sessionId];
    final events = diffTask(
      deviceSid,
      entry.sessionId,
      old,
      now,
      atMs: nowMs(),
    );
    if (events.isEmpty && old == now) return;
    _lastLiveAt[deviceSid] = nowMs();
    // 合并进基线（保留其余任务的基线）。verifying 记账随写回保留
    // （批尾对抗审查 A 级修正：now 来自 si 行 seen 恒 false，裸写回会
    // 在 verifying→active 迁移时摧毁去重标记→迭代循环每轮重发）。
    final next = Map<String, PhaseSnapshot>.of(baselines);
    next[entry.sessionId] = carryGoalVerifyingSeen(old, now);
    store.replaceBaselines(deviceSid, next);
    if (_pendingReconcile.containsKey(deviceSid)) {
      // 对账窗口内（模型换代 mini 对账/suspend 后 si 已重放但 _onCards
      // 尚未跑到）：逐条事件并入对账缓冲，避免聚合被逐条单发抢先。
      final buffer = _reconcileBuffer.putIfAbsent(deviceSid, () => []);
      buffer.addAll(events);
      _reconcileTimer?.cancel();
      _reconcileTimer = Timer(_reconcileWindow, _flushReconcile);
      return;
    }
    for (final e in events) {
      _dispatch(e);
    }
  }

  static PhaseSnapshot _snapshotOfEntry(SessionEntry entry) {
    final pi = entry.pendingInteraction;
    var tool = '${pi?['toolName'] ?? ''}'.trim();
    return PhaseSnapshot(
      phase: _normalizePhase(entry.phase),
      interactionId: _normalizeInteractionId(pi),
      pendingKind: pi == null ? null : '${pi['kind'] ?? ''}',
      // si 摘要可选携带的轻量工具身份（sessions-index.ts:17-18）。
      pendingTool: tool.isEmpty ? null : tool,
      goalStatus: entry.goalStatus,
      title: entry.title,
      // 完成正文兜底（最后回复预览）。
      preview: entry.lastAssistantPreview,
      lastActivityAt: entry.lastActivityAt,
    );
  }

  void _flushReconcile() {
    final buffer = _reconcileBuffer;
    _reconcileBuffer = {};
    final plan = planReconcile(buffer, atMs: nowMs());
    if (plan.aggregated != null) {
      _dispatch(plan.aggregated!);
    }
    // 审批豁免收敛——"等审批不能
    // 埋没"是 ReconcilePlan.singles 的字段契约（notify_core.dart:63），
    // 且收敛后基线已含该 interactionId、第二道闸不在册，该审批提醒会
    // 永久丢失。审批恒逐条发；收敛策略只作用于其余 singles。
    final approvals = plan.singles
        .where((e) => e.kind == NotifyEventKind.approvalPending)
        .toList();
    for (final e in approvals) {
      _dispatch(e);
    }
    final rest = plan.singles
        .where((e) => e.kind != NotifyEventKind.approvalPending)
        .toList();
    // 补发收敛（ 决策 2）：singles 超阈值只发上面那条聚合，
    // 不再逐条 post（"重连一次爆一屏"是通知栏折叠区堆积主因之二）。
    // 台账照常全量记录（outcome=converged），信息不丢、核对口径不变。
    if (shouldConvergeSingles(rest.length)) {
      for (final e in rest) {
        _ledgerConverged(e);
      }
      return;
    }
    for (final e in rest) {
      _dispatch(e);
    }
  }

  /// 收敛吞并的单条只落台账不发通知（fire-and-forget，与 _dispatch
  /// 在 _flushReconcile 中的时序一致）。
  Future<void> _ledgerConverged(NotifyEvent e) async {
    await store.appendLedger(
      LedgerEntry(
        ts: e.atMs,
        kind: e.kind.name,
        deviceSid: e.deviceSid,
        taskId: e.taskId,
        title: e.title,
        outcome: 'converged',
      ),
    );
    _log('[converged] ${e.kind.name} ${e.taskId} "${e.title}"');
  }

  /// 单事件处置：语义去重 → 通道静音 → 台账 → 发送。
  Future<void> _dispatch(NotifyEvent e) async {
    var outcome = 'posted';
    String interactionId = '';
    if (e.kind == NotifyEventKind.approvalPending) {
      // interactionId 随事件携带（upsert 回调先于 si 帧尾 notify，回查
      // cards 拿不到本帧 pending）；事件未带时（聚合路径重构的边缘）回查。
      interactionId = e.interactionId ?? _interactionIdOf(e);
      if (interactionId.isNotEmpty && store.interactionNotified(interactionId)) {
        outcome = 'deduped';
      }
    }
    if (outcome == 'posted' && mutedChannels.contains(e.channel)) {
      outcome = 'muted';
    }
    if (outcome == 'posted' &&
        (shouldSuppress?.call(e.taskId) ?? false)) {
      outcome = 'viewing';
    }
    if (outcome == 'posted') {
      final sent = await onPost(e);
      if (!sent) {
        outcome = 'noChannel';
      } else if (interactionId.isNotEmpty) {
        store.markInteractionNotified(interactionId, e.atMs);
      }
    }
    await store.appendLedger(
      LedgerEntry(
        ts: e.atMs,
        kind: e.kind.name,
        deviceSid: e.deviceSid,
        taskId: e.taskId,
        title: e.title,
        outcome: outcome,
      ),
    );
    _log('[$outcome] ${e.kind.name} ${e.taskId} "${e.title}"');
  }

  /// 事件 detail 里没带 interactionId——差分产事件时只有 kind。语义去重
  /// 需要回查当前快照：取该任务当前 pending 的 interactionId。
  /// 回查同样过 [_normalizeInteractionId]（trim/空串归 null），
  /// 与差分路径的键口径一致。
  String _interactionIdOf(NotifyEvent e) {
    final model = _watched[e.deviceSid];
    if (model == null) return '';
    for (final c in model.cards) {
      if (c.sessionId == e.taskId) {
        return _normalizeInteractionId(c.pendingInteraction) ?? '';
      }
    }
    return '';
  }

  void _log(String line) => debugPrint('[notify] $line');

  // ------------------------------------------------------ suspend/resume

  /// 退后台断连前：记录水位（对账判据）并 flush 基线落盘。
  Future<void> onSuspended() async {
    final now = nowMs();
    for (final sid in _stacks.keys) {
      _pendingReconcile[sid] = now;
    }
    await store.flush();
  }

  /// 回前台恢复：待对账设备就位（si 重放后自动对账），并安排清过时。
  void onResumed({Set<String>? deviceSids}) {
    if (deviceSids != null) {
      _pendingReconcile.removeWhere((sid, _) => !deviceSids.contains(sid));
    }
    // 清过时候选=回前台时刻已在栏的快照：之后新发的通知（断连聚合等）
    // 不属于"陈旧通知"，不得吃掉（清理论证见 notification_service）。
    final staleCandidates = onSnapshotActive?.call() ?? const <int>{};
    _clearStaleTimer?.cancel();
    _clearStaleTimer = Timer(const Duration(seconds: 3), () {
      final pending = <String>{};
      // pending 判据此前只看触发时刻的 watched cards
      // ——后台 >90s 回前台时 TaskCatalog 重建空 cards 的新模型，si 快照
      // 未到的 3s 空窗里 pending 为空集 → 在栏审批通知被全量误清；且基线
      // 已含该 interactionId、第二道闸也不在册 → 该审批提醒永久丢失。
      // 补持久基线回查（interactionId 在基线=仍在等待），cards 与基线
      // 取并集。
      _watched.forEach((_, model) {
        for (final c in model.cards) {
          if (c.pendingInteraction != null) pending.add(c.sessionId);
        }
      });
      for (final sid in _stacks.keys) {
        store.baselinesOf(sid).forEach((taskId, s) {
          if (s.interactionId != null) pending.add(taskId);
        });
      }
      onClearStale?.call(pending, staleCandidates);
    });
  }

  /// 活跃通知快照出口（NotificationService.activeNotificationIds）。
  Set<int> Function()? onSnapshotActive;

  /// 清过时出口（NotificationService.clearStale，协调器不直持有服务）。
  Future<void> Function(Set<String> stillPendingTaskIds, Set<int> staleIds)?
      onClearStale;

  // （onOpenTask 死代码已删——点击路由实际走
  // NotificationService.onTap → AppState.openTaskFromNotification。）
}
