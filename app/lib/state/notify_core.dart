/// 通知核心（阶段 3 第二段，快照差分架构——）。
///
/// 分层：本文件是**纯数据+纯函数**（无 IO、无插件依赖，单测主战场）；
/// 落盘在 notify_store.dart；安卓通道与点击路由在 notify/；
/// 挂接各电脑栈的协调器在 notify_coordinator.dart。
///
/// 差分天然去重：重连后 sessions-index 重放历史快照，与已存基线比对
/// 无变化就不产事件（替代指纹方案，refs-scan §C3 裁决）。
library;

/// 通知通道（官方四通道裁剪为三，各自可静音——设置页三开关）。
enum NotifyChannel { approvals, tasks, goals }

/// 时效性通知存活时长：30 分钟（ 决策 1——完成/落定类信息
/// 30 分钟后已无即时提醒价值；过期只影响通知栏，台账全量留档可找回）。
const _timeSensitiveTtlMs = 30 * 60 * 1000;

/// 通道 → 通知自动过期时长（毫秒；null=不过期）。
///
/// 决策 1：tasks/goals 带超时——通知只增不清是通知栏堆积
/// （"更多通知"折叠区）主因之一，清理原本只有冷启动 cancelAll 与
/// 回前台 clearStale 两时机，companion 场景用户常年不打开 app；
/// approvals 可操作性强不超时，保留到用户处理或回前台对账清理。
/// 入参为通道 id 字符串（= NotificationService.channel* 常量值，
/// backend.show 透传的那个），消费方在 notification_service 的
/// AndroidNotificationDetails.timeoutAfter（仅 Android 生效，本项目
/// 唯一平台）。
int? notificationTtlMs(String channel) => switch (channel) {
  'tasks' || 'goals' => _timeSensitiveTtlMs,
  _ => null, // approvals 及未知通道不过期
};

/// 事件类型。
enum NotifyEventKind {
  /// 任务成功完成（running → completedSuccess）。
  taskCompleted,

  /// 任务失败/中断（running → completedInterrupted / error，高优先级）。
  taskFailed,

  /// 等待审批或等待输入（新 interactionId 出现）。
  approvalPending,

  /// Goal 落定（verified=达成；notSatisfied/failed=未达成/验证失败）。
  goalSettled,

  /// F25（2026-10-24 修复批）：Goal 验证回合开始（协议 verifying——
  /// product-projection.ts:5147 验证回合开始即置并经 sessions-index
  /// 透传）。里程碑级低频通知，迭代循环去重见 PhaseSnapshot.goalVerifyingSeen。
  goalVerifying,

  /// 断连窗口聚合（"你不在时完成了 N 个任务"）。
  awayAggregated,
}

/// 事件对账结果（回前台一轮差分的处置计划）。
class ReconcilePlan {
  /// 聚合事件（离线期间完成 ≥1 时产生，各任务不再单发）。
  final NotifyEvent? aggregated;

  /// 照常单发的事件（失败/审批/Goal——高优先级不聚合、等审批不能埋没）。
  final List<NotifyEvent> singles;
  const ReconcilePlan({this.aggregated, this.singles = const []});
}

/// 差分基线：每（deviceSid × taskId）一条。
///
/// 字段来源（官方 sessions-index sessionSummarySchema，
/// refs shared/src/zcode-protocol-v4/sessions-index.ts:29-55）：
/// - phase 七值域 draft/prewarming/running/completedSuccess/
///   completedInterrupted/error（snapshot.ts:28-37）；
/// - pendingInteraction 摘要含 interactionId + kind(permission|userInput)
///   （sessions-index.ts:12-18）——语义去重键；
/// - goalStatus 六值域 active/paused/verifying/verified/notSatisfied/
///   failed（snapshot.ts:420-440），后三个为落定态。
class PhaseSnapshot {
  final String phase;
  final String? interactionId;
  final String? pendingKind;

  /// F26（2026-10-24 修复批）：审批正文点名工具——si pendingInteraction
  /// 摘要可选携带的轻量工具身份（sessions-index.ts:17-18，不带问题/
  /// 答案 payload）。随审批事件透传（NotifyEvent.tool）。
  final String? pendingTool;

  /// F26：完成正文兜底（si lastAssistantPreview——最后回复预览，比
  /// 标题更贴近"完成了什么"）。不参与判等（每条新消息都变）。
  final String? preview;
  final String? goalStatus;
  final String title;

  /// F25：verifying 里程碑记账——迭代循环（verifying→active→verifying）
  /// 不重发；goal 落定重置（新一轮目标重新通知）。纯记账非协议状态，
  /// 不参与判等；由 diffSnapshots 写入下一轮基线并持久化。
  final bool goalVerifyingSeen;

  /// 最后活动时间（断连窗口聚合的"水位之后新增"判据；完成时间近似）。
  final int lastActivityAt;

  const PhaseSnapshot({
    required this.phase,
    this.interactionId,
    this.pendingKind,
    this.pendingTool,
    this.preview,
    this.goalStatus,
    required this.title,
    required this.lastActivityAt,
    this.goalVerifyingSeen = false,
  });

  Map<String, dynamic> toJson() => {
    'phase': phase,
    'interactionId': interactionId,
    'pendingKind': pendingKind,
    'pendingTool': pendingTool,
    'preview': preview,
    'goalStatus': goalStatus,
    'title': title,
    'lastActivityAt': lastActivityAt,
    if (goalVerifyingSeen) 'goalVerifyingSeen': true,
  };

  static PhaseSnapshot fromJson(Map<String, dynamic> raw) => PhaseSnapshot(
    phase: '${raw['phase'] ?? ''}',
    interactionId: raw['interactionId'] as String?,
    pendingKind: raw['pendingKind'] as String?,
    pendingTool: raw['pendingTool'] as String?,
    preview: raw['preview'] as String?,
    goalStatus: raw['goalStatus'] as String?,
    title: '${raw['title'] ?? ''}',
    lastActivityAt: (raw['lastActivityAt'] as num?)?.toInt() ?? 0,
    goalVerifyingSeen: raw['goalVerifyingSeen'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is PhaseSnapshot &&
      other.phase == phase &&
      other.interactionId == interactionId &&
      other.pendingTool == pendingTool &&
      other.goalStatus == goalStatus;

  @override
  int get hashCode =>
      Object.hash(phase, interactionId, pendingTool, goalStatus);
}

/// 差分事件（协调器消费：落台账 → 查通道静音 → 发安卓通知）。
class NotifyEvent {
  final NotifyChannel channel;
  final NotifyEventKind kind;
  final String deviceSid;
  final String taskId;
  final String title;

  /// 通知正文素材（F26）：审批=pendingKind 或 toolName；goal=goalStatus；
  /// 聚合=完成任务数。
  final String? detail;

  /// F26：审批点名的工具（si 轻量工具身份原样）——通知正文用。
  final String? tool;

  /// F26：完成/失败正文兜底（lastAssistantPreview 截断后使用）。
  final String? preview;
  final String? interactionId;
  final int atMs;

  const NotifyEvent({
    required this.channel,
    required this.kind,
    required this.deviceSid,
    required this.taskId,
    required this.title,
    this.detail,
    this.tool,
    this.preview,
    this.interactionId,
    required this.atMs,
  });
}

/// 台账条目（"零漏发"以台账核对判定，不靠记忆—— 决策 2/6）。
class LedgerEntry {
  final int ts;
  final String kind;
  final String deviceSid;
  final String taskId;
  final String title;

  /// posted=已发通知；firstSeen=首见建基线不通知；deduped=语义去重；
  /// muted=通道静音吞并；aggregated=并入离线聚合；noChannel=服务不可用；
  /// converged=补发收敛吞并（超阈值只发聚合， 决策 2）。
  final String outcome;
  final bool clicked;

  const LedgerEntry({
    required this.ts,
    required this.kind,
    required this.deviceSid,
    required this.taskId,
    required this.title,
    required this.outcome,
    this.clicked = false,
  });

  Map<String, dynamic> toJson() => {
    'ts': ts,
    'kind': kind,
    'deviceSid': deviceSid,
    'taskId': taskId,
    'title': title,
    'outcome': outcome,
    'clicked': clicked,
  };

  static LedgerEntry fromJson(Map<String, dynamic> raw) => LedgerEntry(
    ts: (raw['ts'] as num?)?.toInt() ?? 0,
    kind: '${raw['kind'] ?? ''}',
    deviceSid: '${raw['deviceSid'] ?? ''}',
    taskId: '${raw['taskId'] ?? ''}',
    title: '${raw['title'] ?? ''}',
    outcome: '${raw['outcome'] ?? ''}',
    clicked: raw['clicked'] == true,
  );
}

/// 运行态判定（复用任务列表词汇表：running + prewarming 都算"在跑"）。
bool _isRunning(String phase) =>
    phase == 'running' || phase == 'prewarming';

bool _isTerminal(String phase) =>
    phase == 'completedSuccess' ||
    phase == 'completedInterrupted' ||
    phase == 'error';

/// goalStatus 落定态（verified=达成；notSatisfied=有效结论未达成；
/// failed=验证过程失败——snapshot.ts:428 注释）。
bool _isGoalSettled(String? status) =>
    status == 'verified' || status == 'notSatisfied' || status == 'failed';

/// F25：verifying 记账保留规则（diffSnapshots 聚合路径与协调器逐条
/// upsert 写回共用——批尾对抗审查 A 级修正 2026-10-24：si 行构造的
/// 快照 goalVerifyingSeen 恒 false，逐条写回若不保留旧记账，
/// verifying→active 的迁移 upsert 即摧毁去重标记，迭代循环每轮重发）。
/// 规则：goal 落定重置（新一轮重新通知）；verifying 在场置真；其余
/// 沿用旧值。
PhaseSnapshot carryGoalVerifyingSeen(PhaseSnapshot? old, PhaseSnapshot now) {
  final seen = _isGoalSettled(now.goalStatus)
      ? false
      : now.goalStatus == 'verifying'
      ? true
      : (old?.goalVerifyingSeen ?? false);
  if (seen == now.goalVerifyingSeen) return now;
  return PhaseSnapshot(
    phase: now.phase,
    interactionId: now.interactionId,
    pendingKind: now.pendingKind,
    pendingTool: now.pendingTool,
    preview: now.preview,
    goalStatus: now.goalStatus,
    title: now.title,
    lastActivityAt: now.lastActivityAt,
    goalVerifyingSeen: seen,
  );
}

/// 单任务差分（纯函数）。
///
/// 首见（old == null）：不产事件（防首轮全量刷入轰炸），仅建基线——
/// 但 [countFirstSeenTerminal]（回前台对账模式）时，"水位之后才出现
/// 终态"的首见任务计入完成事件（断连窗口聚合的组合洞堵法）。
List<NotifyEvent> diffTask(
  String deviceSid,
  String taskId,
  PhaseSnapshot? old,
  PhaseSnapshot now, {
  required int atMs,
  bool countFirstSeenTerminal = false,
  int? sinceMs,
}) {
  if (old == null) {
    if (countFirstSeenTerminal &&
        sinceMs != null &&
        now.lastActivityAt > sinceMs) {
      final events = <NotifyEvent>[];
      if (_isTerminal(now.phase)) {
        // H1-P2-03/H2-P3-5：首见分支按当前终态分派（与主分支
        // 同口径）——completedSuccess 计入聚合，error/completedInterrupted
        // 归 singles 单发（失败高优先级本就不聚合）。此前只认
        // completedSuccess，断连/死亡窗口内"新建即失败"的任务零通知零
        // 台账（"你不在时"的失败完全不可见）。
        events.add(NotifyEvent(
          channel: NotifyChannel.tasks,
          kind: now.phase == 'completedSuccess'
              ? NotifyEventKind.taskCompleted
              : NotifyEventKind.taskFailed,
          deviceSid: deviceSid,
          taskId: taskId,
          title: now.title,
          preview: now.preview,
          atMs: atMs,
        ));
      }
      // 状态层批：对账模式下首见任务若正等待审批也产事件——此前
      // old==null 整体静默，"不在时新出现的等审批"永久漏报（第二道闸
      // interactionNotified 仍防重放重发）。
      if (now.interactionId != null) {
        events.add(NotifyEvent(
          channel: NotifyChannel.approvals,
          kind: NotifyEventKind.approvalPending,
          deviceSid: deviceSid,
          taskId: taskId,
          title: now.title,
          detail: now.pendingKind,
          tool: now.pendingTool,
          interactionId: now.interactionId,
          atMs: atMs,
        ));
      }
      return events;
    }
    return const [];
  }
  final events = <NotifyEvent>[];
  if (_isRunning(old.phase) && _isTerminal(now.phase)) {
    events.add(
      NotifyEvent(
        channel: NotifyChannel.tasks,
        kind: now.phase == 'completedSuccess'
            ? NotifyEventKind.taskCompleted
            : NotifyEventKind.taskFailed,
        deviceSid: deviceSid,
        taskId: taskId,
        title: now.title,
        preview: now.preview,
        atMs: atMs,
      ),
    );
  } else if (countFirstSeenTerminal &&
      sinceMs != null &&
      _isTerminal(old.phase) &&
      _isTerminal(now.phase) &&
      now.lastActivityAt > sinceMs) {
    // 对账兜底（介入点2自证轮实锤 2026-10-19）：基线可能陈旧（写盘
    // 防抖饿死/异常丢失），"终态→终态"但完成时间在水位之后=我们不在
    // 时又完整跑过一轮——计一次该轮终态，否则该轮次对死亡窗口不可见。
    // （H1 P2-02/H2 P1-1）：kind 按当前终态分派（与上方
    // 主分支同口径）——error→error（复活轮再失败）恒报"任务完成"是
    // 方向性误导，比不发更糟。
    events.add(
      NotifyEvent(
        channel: NotifyChannel.tasks,
        kind: now.phase == 'completedSuccess'
            ? NotifyEventKind.taskCompleted
            : NotifyEventKind.taskFailed,
        deviceSid: deviceSid,
        taskId: taskId,
        title: now.title,
        preview: now.preview,
        atMs: atMs,
      ),
    );
  }
  // 新审批：interactionId 变化才发（差分天然去重；基线持久化后重连
  // 重放同 id 也不发——第二道闸 notifiedInteractions 防基线丢失场景）。
  if (now.interactionId != null && now.interactionId != old.interactionId) {
    events.add(
      NotifyEvent(
        channel: NotifyChannel.approvals,
        kind: NotifyEventKind.approvalPending,
        deviceSid: deviceSid,
        taskId: taskId,
        title: now.title,
        detail: now.pendingKind,
        tool: now.pendingTool,
        interactionId: now.interactionId,
        atMs: atMs,
      ),
    );
  }
  // F25：verifying 里程碑（验证回合开始）——进入 verifying 边沿且本轮
  // 目标未通知过才发；迭代循环（verifying→active→verifying）由
  // goalVerifyingSeen 记账去重防轰炸，goal 落定重置（新一轮重发）。
  if (now.goalStatus == 'verifying' &&
      old.goalStatus != 'verifying' &&
      !old.goalVerifyingSeen) {
    events.add(
      NotifyEvent(
        channel: NotifyChannel.goals,
        kind: NotifyEventKind.goalVerifying,
        deviceSid: deviceSid,
        taskId: taskId,
        title: now.title,
        detail: 'verifying',
        atMs: atMs,
      ),
    );
  }
  // goal 落定：仅从非落定态进入落定态时发（落定→落定迁移不重发——
  // 结论类通知一次即够，重新验证走 active →落定路径自然再发）。
  if (_isGoalSettled(now.goalStatus) && !_isGoalSettled(old.goalStatus)) {
    events.add(
      NotifyEvent(
        channel: NotifyChannel.goals,
        kind: NotifyEventKind.goalSettled,
        deviceSid: deviceSid,
        taskId: taskId,
        title: now.title,
        detail: now.goalStatus,
        atMs: atMs,
      ),
    );
  }
  return events;
}

/// 整栈差分：当前快照集合 vs 基线集合，产出事件 + 下一轮基线。
/// 基线中存在、当前消失的任务（归档/删除/移除）直接从基线剔除。
DiffResult diffSnapshots(
  String deviceSid,
  Map<String, PhaseSnapshot> baselines,
  Map<String, PhaseSnapshot> current, {
  required int atMs,
  bool reconcile = false,
  int? sinceMs,
}) {
  final events = <NotifyEvent>[];
  final next = <String, PhaseSnapshot>{};
  current.forEach((taskId, now) {
    final old = baselines[taskId];
    // F25：记账字段落下一轮基线（规则见 carryGoalVerifyingSeen）。
    next[taskId] = carryGoalVerifyingSeen(old, now);
    events.addAll(
      diffTask(
        deviceSid,
        taskId,
        old,
        now,
        atMs: atMs,
        countFirstSeenTerminal: reconcile,
        sinceMs: sinceMs,
      ),
    );
  });
  return DiffResult(events: events, nextBaselines: next);
}

class DiffResult {
  final List<NotifyEvent> events;
  final Map<String, PhaseSnapshot> nextBaselines;
  const DiffResult({required this.events, required this.nextBaselines});
}

/// 基线合并（ H2-P2-1）：当前快照（=当前工作区 cards）缺席的
/// 条目保留——栈同一时刻只挂当前工作区的 TaskListModel，整体替换会
/// 清零其他工作区全部任务基线，切回后 si 快照对已清基线的任务是
/// "首见"，完成/审批事件被首见抑制结构性吞掉。merge 后切工作区不再
/// 丢基线（与 _onUpsert 单条 merge 语义对齐）；归档/删除任务的基线
/// 残留无害（无事件源，dropDevice 兜底清）。
Map<String, PhaseSnapshot> mergeBaselines(
  Map<String, PhaseSnapshot> baselines,
  Map<String, PhaseSnapshot> current,
) => {...baselines, ...current};

/// 回前台对账：完成事件合并为一条聚合（各任务不再单发——设计文档
/// "断连窗口聚合"）；失败/审批/Goal 照常单发。
/// 跨设备聚合（多电脑同时完成聚合成一条， 决策 6）：
/// [eventsByDevice] 汇总各栈对账结果。
/// （ H1-P3-01：deviceLabelOf 参数从未被读、_defaultLabel 仅为
/// 它存在——死参数已删；设备标签在 onPost 闭包自行拼接。）
ReconcilePlan planReconcile(Map<String, List<NotifyEvent>> eventsByDevice, {
  required int atMs,
}) {
  final singles = <NotifyEvent>[];
  var completed = 0;
  String? sampleTitle;
  String? sampleSid;
  String? sampleTask;
  eventsByDevice.forEach((_, events) {
    for (final e in events) {
      switch (e.kind) {
        case NotifyEventKind.taskCompleted:
          completed++;
          sampleTitle ??= e.title;
          sampleSid ??= e.deviceSid;
          sampleTask ??= e.taskId;
        case NotifyEventKind.taskFailed:
        case NotifyEventKind.approvalPending:
        case NotifyEventKind.goalSettled:
        case NotifyEventKind.goalVerifying:
          singles.add(e);
        case NotifyEventKind.awayAggregated:
          break;
      }
    }
  });
  if (completed == 0) return ReconcilePlan(singles: singles);
  return ReconcilePlan(
    aggregated: NotifyEvent(
      channel: NotifyChannel.tasks,
      kind: NotifyEventKind.awayAggregated,
      deviceSid: sampleSid ?? '',
      taskId: sampleTask ?? '',
      title: sampleTitle ?? '',
      detail: '$completed',
      atMs: atMs,
    ),
    singles: singles,
  );
}

/// 对账补发单条收敛阈值（ 决策 2）：singles 超过此数时只发
/// 一条聚合，不再逐条 post——消灭"重连一次爆一屏"（批量进栏时除最高
/// 排名几条外全部即时落入系统"更多通知"折叠区）。台账不受收敛影响，
/// 照常全量记录（outcome=converged）。
const reconcileSinglesLimit = 3;

/// 对账补发是否收敛为只发聚合（singles 超阈值→收敛；≤ 阈值逐条照发）。
bool shouldConvergeSingles(int singles) => singles > reconcileSinglesLimit;
