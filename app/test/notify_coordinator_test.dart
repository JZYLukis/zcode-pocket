import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/notify_coordinator.dart';
import 'package:zcode_pocket/state/notify_core.dart';
import 'package:zcode_pocket/state/notify_store.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

class _FakeStack extends ComputerStack {
  _FakeStack(String sid)
      : super(
          profile: RelayProfile(
            params: CompanionConnectionParams(
              deviceSid: sid,
              passHash: 'hash',
              timestamp: 1,
              source: Uri.parse('https://zcode.z.ai/ws?sid=$sid'),
            ),
            label: '测试电脑',
            addedAt: DateTime.now(),
          ),
          onLog: (_) {},
          onFailure: (_, _) {},
        );
}

void main() {
  late Directory tmp;
  late NotifyStore store;
  late List<NotifyEvent> posted;
  late NotifyCoordinator coordinator;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notify_coord_test');
    store = NotifyStore(tmp);
    await store.load();
    posted = [];
    coordinator = NotifyCoordinator(
      store: store,
      onPost: (e) async {
        posted.add(e);
        return true;
      },
    );
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // ── 测试稳定性根治（2026-10-29 批次）────────────────────────────
  // 固定 2.1s 等待在满载套件下偶发不足（"写盘饿死"家族：负载把 2s
  // 防抖窗口与磁盘写拉长，等待先到而断言后至=假红）。改轮询确定性收口。

  Future<bool> until(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return cond();
  }

  /// 正向断言前置：等聚合/单发落地（posted 非空）。
  Future<void> waitForPosted() async {
    expect(await until(() => posted.isNotEmpty), isTrue,
        reason: '防抖事件未在负载余量（2s 窗口+8s 余量）内落地');
  }

  /// 负向断言前置：等防抖计时器归位（或从未 armed）+ 尾部节拍——
  /// 满载下 2s 窗口被拉长时不再提前断言 isEmpty。
  Future<void> settleDebounce() async {
    await until(() => !coordinator.debugReconcileTimerActive);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  TaskListModel modelWith(
    List<Map<String, dynamic>> sessions, {
    bool cachePreview = false,
  }) {
    final state = SessionsIndexState();
    for (final s in sessions) {
      final e = SessionEntry(s);
      state.sessions[e.sessionId] = e;
    }
    state.ready = true;
    final model = TaskListModel(
      sessions: state,
      workspaceKey: 'ws',
      cachePreview: cachePreview,
    );
    // si 快照到达即触发 rebuild（真实路径 applyFrame 末尾 notify）。
    model.applyChannelLists(active: const [], pinnedIds: const [], archivedIds: const []);
    return model;
  }

  /// 真实 delta 帧路径（常规差分事件源 = 逐条 upsert 回调）。
  void pushUpsert(TaskListModel model, Map<String, dynamic> session) {
    final state = model.sessions;
    state.applyFrame({
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'session.upserted', 'session': session},
        ],
      },
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
    }, onGap: () {});
  }

  Map<String, dynamic> session(
    String id,
    String phase, {
    String? interactionId,
    String? goalStatus,
    int lastActivityAt = 1000,
  }) => {
    'sessionId': id,
    'workspaceId': 'ws',
    'title': '任务$id',
    'phase': phase,
    'sessionEnded': phase.startsWith('completed') || phase == 'error',
    if (interactionId != null)
      'pendingInteraction': {
        'interactionId': interactionId,
        'kind': 'permission',
      },
    'goalStatus': ?goalStatus,
    'lastActivityAt': lastActivityAt,
    'createdAt': 1,
  };

  test('F25 批尾对抗审查 A 级修正：逐条 upsert 路径迭代循环不重发 verifying',
      () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    final model = modelWith([session('t1', 'running', goalStatus: 'active')]);
    stack.onTaskListRebuilt!(model);
    await Future<void>.delayed(Duration.zero);
    // 首次进入 verifying → 发。
    pushUpsert(model, session('t1', 'running', goalStatus: 'verifying'));
    await Future<void>.delayed(Duration.zero);
    expect(
      posted.where((e) => e.kind == NotifyEventKind.goalVerifying).length,
      1,
    );
    // 迭代循环：回 active 再 verifying → 不重发。修复前红=逐条写回用
    // si 原始快照（seen 恒 false）摧毁记账，第二次 verifying 重发轰炸。
    pushUpsert(model, session('t1', 'running', goalStatus: 'active'));
    await Future<void>.delayed(Duration.zero);
    pushUpsert(model, session('t1', 'running', goalStatus: 'verifying'));
    await Future<void>.delayed(Duration.zero);
    expect(
      posted.where((e) => e.kind == NotifyEventKind.goalVerifying).length,
      1,
      reason: 'carryGoalVerifyingSeen 写回保留记账（迭代去重主路径）',
    );
    // 落定重置：verified → 新一轮 active → verifying → 再发。
    pushUpsert(
        model, session('t1', 'completedSuccess', goalStatus: 'verified'));
    await Future<void>.delayed(Duration.zero);
    expect(
      posted.where((e) => e.kind == NotifyEventKind.goalSettled).length,
      1,
    );
    pushUpsert(model, session('t1', 'running', goalStatus: 'active'));
    await Future<void>.delayed(Duration.zero);
    pushUpsert(model, session('t1', 'running', goalStatus: 'verifying'));
    await Future<void>.delayed(Duration.zero);
    expect(
      posted.where((e) => e.kind == NotifyEventKind.goalVerifying).length,
      2,
      reason: 'goal 落定重置记账——新一轮目标重新通知',
    );
  });

  test('幽灵栈不挡重挂：拆栈未 detach 后同 sid 新栈通知复活（早前批次 A4）', () async {
    // 换账号重连/auth-required 路径 dispose 旧栈但不 detachStack——
    // 修复前 attachStack 被 containsKey 幽灵门短路，新栈通知永久失效。
    final old = _FakeStack('d1');
    coordinator.attachStack(old);
    final model0 = modelWith([session('t1', 'running')]);
    old.onTaskListRebuilt!(model0);
    await Future<void>.delayed(Duration.zero);
    await old.disposeStack(); // 只 dispose、不 detach（复现拆栈路径）

    final fresh = _FakeStack('d1');
    coordinator.attachStack(fresh);
    final model = modelWith([session('t2', 'running')]);
    expect(fresh.onTaskListRebuilt, isNotNull,
        reason: '修复前：新栈回调未被接管（幽灵门短路）');
    fresh.onTaskListRebuilt!(model);
    await Future<void>.delayed(Duration.zero);
    pushUpsert(
        model, session('t2', 'completedSuccess', lastActivityAt: 2000));
    await Future<void>.delayed(Duration.zero);
    expect(posted.single.kind, NotifyEventKind.taskCompleted,
        reason: '重挂后的新栈必须能发完成通知');
  });

  test('在线差分：任务完成事件发出并落台账 posted', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    final model = modelWith([session('t1', 'running')]);
    stack.onTaskListRebuilt!(model);
    await Future<void>.delayed(Duration.zero);
    expect(posted, isEmpty, reason: '首见只建基线');
    pushUpsert(
      model, session('t1', 'completedSuccess', lastActivityAt: 2000));
    await Future<void>.delayed(Duration.zero);
    expect(posted.single.kind, NotifyEventKind.taskCompleted);
    final ledger = store.recentLedger();
    expect(ledger.single.outcome, 'posted');
    expect(ledger.single.kind, 'taskCompleted');
  });

  test('通道静音：事件不发通知但台账记 muted', () async {
    coordinator.mutedChannels = {NotifyChannel.tasks};
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    final model = modelWith([session('t1', 'running')]);
    stack.onTaskListRebuilt!(model);
    pushUpsert(
      model, session('t1', 'completedSuccess', lastActivityAt: 2000));
    await Future<void>.delayed(Duration.zero);
    expect(posted, isEmpty);
    expect(store.recentLedger().single.outcome, 'muted');
  });

  test('查看中抑制：用户正开着的会话完成不发通知（台账记 viewing）', () async {
    final viewCoord = NotifyCoordinator(
      store: store,
      onPost: (e) async {
        posted.add(e);
        return true;
      },
      shouldSuppress: (taskId) => taskId == 'watching',
    );
    final stack = _FakeStack('d1');
    viewCoord.attachStack(stack);
    final model = modelWith([
      session('watching', 'running'),
      session('background', 'running'),
    ]);
    stack.onTaskListRebuilt!(model);
    pushUpsert(model, session('watching', 'completedSuccess', lastActivityAt: 2000));
    pushUpsert(model, session('background', 'completedSuccess', lastActivityAt: 2000));
    await Future<void>.delayed(Duration.zero);
    expect(posted.map((e) => e.taskId), ['background'],
        reason: '查看中的任务抑制，后台任务照发');
    final outcomes = store.recentLedger().map((e) => '${e.taskId}:${e.outcome}');
    expect(outcomes, containsAll(['watching:viewing', 'background:posted']));
  });

  test('审批语义去重第二道闸：基线丢失后同 interactionId 不重发', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    // 先建无 pending 基线（首见不通知），审批随后出现 → 发一次
    final model = modelWith([session('t1', 'running')]);
    stack.onTaskListRebuilt!(model);
    await Future<void>.delayed(Duration.zero);
    expect(posted, isEmpty);
    pushUpsert(model, session('t1', 'running', interactionId: 'ix1'));
    await Future<void>.delayed(Duration.zero);
    expect(posted.single.kind, NotifyEventKind.approvalPending);
    // 模拟"基线回退到 pending 出现之前"（基线文件损坏/清理后 si 重放）：
    // 重放快照仍带同 interactionId → 差分再产审批事件 → 第二道闸拦截。
    store.replaceBaselines('d1', {
      't1': PhaseSnapshot(
        phase: 'running', title: '任务t1', lastActivityAt: 1000),
    });
    pushUpsert(model, session('t1', 'running', interactionId: 'ix1'));
    await Future<void>.delayed(Duration.zero);
    expect(posted, hasLength(1), reason: '第二道闸（notifiedInteractions）去重');
    expect(store.recentLedger().last.outcome, 'deduped');
  });

  test('断连窗口对账：suspend 水位后完成 → 聚合一条"你不在时"', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([session('t1', 'running')]));
    await Future<void>.delayed(Duration.zero);
    // suspend（记录水位）
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // resume：si 重放（t1 已完成 + 离线期间新完成的 t2）
    coordinator.nowMs = () => 9000;
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(modelWith([
      session('t1', 'completedSuccess', lastActivityAt: 6000),
      session('t2', 'completedSuccess', lastActivityAt: 7000),
    ]));
    // 聚合窗口 2s（负载余量轮询收口）
    await waitForPosted();
    expect(
      posted.map((e) => e.kind),
      everyElement(NotifyEventKind.awayAggregated),
    );
    expect(posted.single.detail, '2');
    expect(
      await until(() => store.recentLedger().isNotEmpty),
      isTrue,
      reason: '台账写盘未在负载余量内落地',
    );
    final ledger = store.recentLedger();
    expect(ledger.last.outcome, 'posted');
  });

  test('对账期间失败任务不进聚合（单发高优先级）', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([session('t1', 'running')]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    coordinator.nowMs = () => 9000;
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(modelWith([
      session('t1', 'error', lastActivityAt: 6000),
    ]));
    await waitForPosted();
    expect(posted.single.kind, NotifyEventKind.taskFailed);
  });

  test('回前台清过时出口：3s 后带当前 pending 集合与回前台快照回调', () async {
    Set<String>? clearedWith;
    Set<int>? clearedIds;
    coordinator.onSnapshotActive = () => const {7};
    coordinator.onClearStale = (pending, staleIds) async {
      clearedWith = pending;
      clearedIds = staleIds;
    };
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(
      modelWith([session('t1', 'running', interactionId: 'ix1')]));
    expect(
      await until(() => clearedWith != null),
      isTrue,
      reason: '3s 清过时回调未在负载余量内触发',
    );
    expect(clearedWith, {'t1'});
    expect(clearedIds, {7}, reason: '清过时候选=回前台时刻快照，不吃新通知');
  });

  test('盲审1：缓存预渲不吃对账水位、不建基线（stale running 不误报）', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([session('t1', 'running')]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // resume：先来缓存预渲（stale：t1 仍 running + 缓存独有的 t9）
    coordinator.nowMs = () => 9000;
    coordinator.onResumed();
    stack.onTaskListRebuilt!(modelWith([
      session('t1', 'running'),
      session('t9', 'completedSuccess', lastActivityAt: 100),
    ], cachePreview: true));
    await settleDebounce();
    expect(posted, isEmpty, reason: '预渲是陈旧快照，不得产事件');
    expect(store.baselinesOf('d1').containsKey('t9'), isFalse,
        reason: '预渲不得建基线');
    // live 快照到达才对账：t1 已完成 → 聚合
    stack.onTaskListRebuilt!(
      modelWith([session('t1', 'completedSuccess', lastActivityAt: 6000)]));
    await waitForPosted();
    expect(posted.single.kind, NotifyEventKind.awayAggregated,
        reason: '水位必须活到 live 快照，预渲不得提前消费');
  });

  test('盲审5：对账空事件也写基线（断连期间新建任务不漏发）', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([session('t1', 'running')]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // resume：断连期间只新建了 t3（还没完成）→ 对账零事件
    coordinator.nowMs = () => 9000;
    coordinator.onResumed();
    final live = modelWith([
      session('t1', 'running'),
      session('t3', 'running', lastActivityAt: 7000),
    ]);
    stack.onTaskListRebuilt!(live);
    await settleDebounce();
    expect(posted, isEmpty);
    expect(store.baselinesOf('d1').containsKey('t3'), isTrue,
        reason: '空事件对账也要收敛基线');
    // t3 之后完成 → 正常单发（不被首见吞掉）
    pushUpsert(
      live, session('t3', 'completedSuccess', lastActivityAt: 12000));
    await Future<void>.delayed(Duration.zero);
    expect(posted.single.kind, NotifyEventKind.taskCompleted);
    expect(posted.single.taskId, 't3');
  });

  test('盲审4：回前台不限定设备集，非活跃栈水位保留到它重连', () async {
    final stackA = _FakeStack('d1');
    final stackB = _FakeStack('d2');
    coordinator.attachStack(stackA);
    coordinator.attachStack(stackB);
    stackA.onTaskListRebuilt!(modelWith([session('a1', 'running')]));
    stackB.onTaskListRebuilt!(modelWith([session('b1', 'running')]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // 回前台只恢复了 A；B 的水位不因 resume 被清
    coordinator.nowMs = () => 9000;
    coordinator.onResumed();
    stackA.onTaskListRebuilt!(
      modelWith([session('a1', 'completedSuccess', lastActivityAt: 6000)]));
    await waitForPosted();
    posted.clear();
    // 用户切到 B（activate→resume→si 重放）：B 的对账此刻完成
    coordinator.nowMs = () => 20000;
    stackB.onTaskListRebuilt!(
      modelWith([session('b1', 'error', lastActivityAt: 8000)]));
    await waitForPosted();
    expect(posted.single.kind, NotifyEventKind.taskFailed,
        reason: 'B 栈断连期间的失败事件在对账时补发');
  });

  test('官方语义e+盲审14：空串 interactionId 非 pending；任务索引词归一化', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    final model = modelWith([session('t1', 'running')]);
    stack.onTaskListRebuilt!(model);
    await Future<void>.delayed(Duration.zero);
    // pendingInteraction 键在但 interactionId 空 → 不当审批
    pushUpsert(model, {
      ...session('t1', 'running'),
      'pendingInteraction': {'interactionId': '', 'kind': 'permission'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(posted, isEmpty, reason: '空 interactionId 不产审批事件');
    // 任务索引词汇 completed（官方 si 不发，防漏的归一化）
    pushUpsert(model, session('t1', 'completed', lastActivityAt: 3000));
    await Future<void>.delayed(Duration.zero);
    expect(posted.single.kind, NotifyEventKind.taskCompleted,
        reason: "completed 归一化为 completedSuccess 后判中终态");
  });

  test('冷启动对账：进程死亡期间完成 → 重启首个 live 快照聚合（介入点2杀后台根因）', () async {
    // 预置基线=上一进程 flush 的状态（t1 running，最后活数据时刻 1000）
    store.replaceBaselines('d1', {
      't1': PhaseSnapshot(
        phase: 'running', title: '任务t1', lastActivityAt: 1000),
    });
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    // 重启先来缓存预渲（陈旧）→ 跳过且不得消费冷启动标记
    stack.onTaskListRebuilt!(
      modelWith([session('t1', 'running')], cachePreview: true));
    await Future<void>.delayed(Duration.zero);
    expect(posted, isEmpty);
    // 首个 live 快照：t1 已在进程死亡期间完成（水位 1000 之后）
    coordinator.nowMs = () => 9000;
    stack.onTaskListRebuilt!(modelWith(
      [session('t1', 'completedSuccess', lastActivityAt: 5000)]));
    await waitForPosted();
    expect(posted.single.kind, NotifyEventKind.awayAggregated,
        reason: '进程死亡窗口的完成由冷启动水位对账补发聚合');
    expect(posted.single.detail, '1');
    // 无漏发重复：同批不得再单发（先等台账落盘，防空转断言）
    expect(
      await until(() => store.recentLedger()
          .any((e) => e.kind == 'awayAggregated')),
      isTrue,
      reason: '聚合台账未在负载余量内落盘',
    );
    expect(
      store.recentLedger().where((e) =>
          e.kind == 'taskCompleted' && e.outcome == 'posted'),
      isEmpty,
    );
  });

  test('冷启动兜底变体：盘上陈旧"完成"基线（写盘饿死）→ 死亡期间再完成仍聚合', () async {
    // 复刻 2026-10-19 自证轮失败现场：防抖饿死使盘上基线停在
    // 上一轮的 completedSuccess——死亡窗口内又跑完一轮。
    store.replaceBaselines('d1', {
      't1': PhaseSnapshot(
        phase: 'completedSuccess', title: '任务t1', lastActivityAt: 1000),
    });
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    coordinator.nowMs = () => 9000;
    stack.onTaskListRebuilt!(modelWith(
      [session('t1', 'completedSuccess', lastActivityAt: 5000)]));
    await waitForPosted();
    expect(posted.single.kind, NotifyEventKind.awayAggregated,
        reason: '终态→终态但 lastActivityAt 越过水位=漏掉的一轮，兜底补发');
  });

  test('补发收敛：singles 超过 3 条只发聚合，台账全量记 converged', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([
      for (var i = 1; i <= 5; i++) session('t$i', 'running'),
    ]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // resume：t1 完成（→聚合）+ t2..t5 四条失败（singles=4 > 3 → 收敛）
    coordinator.nowMs = () => 9000;
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(modelWith([
      session('t1', 'completedSuccess', lastActivityAt: 6000),
      for (var i = 2; i <= 5; i++) session('t$i', 'error', lastActivityAt: 6000 + i),
    ]));
    await waitForPosted();
    expect(posted.map((e) => e.kind),
        [NotifyEventKind.awayAggregated],
        reason: '超阈值只发聚合一条，不再逐条爆屏');
    expect(posted.single.detail, '1');
    final failed = store
        .recentLedger()
        .where((e) => e.kind == 'taskFailed')
        .toList();
    expect(
      await until(() => store.recentLedger()
          .where((e) => e.kind == 'taskFailed')
          .length >= 4),
      isTrue,
      reason: '台账 converged 全量未在负载余量内落盘',
    );
    expect(failed.map((e) => e.taskId), containsAll(['t2', 't3', 't4', 't5']),
        reason: '台账照常全量记录，不受收敛影响（卡片迭代序不定，按集合断言）');
    expect(failed, hasLength(4));
    expect(failed.every((e) => e.outcome == 'converged'), isTrue);
  });

  test('补发收敛边界：singles 恰为 3 条仍逐条照发', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([
      for (var i = 1; i <= 4; i++) session('t$i', 'running'),
    ]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    coordinator.nowMs = () => 9000;
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(modelWith([
      session('t1', 'completedSuccess', lastActivityAt: 6000),
      for (var i = 2; i <= 4; i++) session('t$i', 'error', lastActivityAt: 6000 + i),
    ]));
    expect(
      await until(
        () =>
            posted.where((e) => e.kind == NotifyEventKind.taskFailed).length ==
            3,
      ),
      isTrue,
      reason: '3 条失败单发未在负载余量内齐发',
    );
    expect(
      posted.map((e) => e.kind),
      containsAll([
        NotifyEventKind.awayAggregated,
        NotifyEventKind.taskFailed,
      ]),
      reason: '≤3 逐条：聚合 + 3 条失败都发',
    );
    expect(posted.where((e) => e.kind == NotifyEventKind.taskFailed),
        hasLength(3));
    expect(
      await until(() => store.recentLedger()
          .where((e) => e.kind == 'taskFailed')
          .length >= 3),
      isTrue,
      reason: '台账 posted 全量未在负载余量内落盘',
    );
    expect(
      store
          .recentLedger()
          .where((e) => e.kind == 'taskFailed')
          .every((e) => e.outcome == 'posted'),
      isTrue,
    );
  });

  test('补发收敛零聚合变体：无完成但 singles 超阈值 → 一条不发、台账 converged', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([
      for (var i = 1; i <= 4; i++) session('t$i', 'running'),
    ]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // 离线期间只有失败没有完成 → planReconcile 无聚合可发
    coordinator.nowMs = () => 9000;
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(modelWith([
      for (var i = 1; i <= 4; i++) session('t$i', 'error', lastActivityAt: 6000 + i),
    ]));
    expect(
      await until(
        () => store.recentLedger().where((e) => e.kind == 'taskFailed').length >= 4,
      ),
      isTrue,
      reason: '台账 converged 记录未在负载余量内落盘',
    );
    expect(posted, isEmpty, reason: '超阈值且无聚合：一条不发（台账可找回）');
    final failed = store
        .recentLedger()
        .where((e) => e.kind == 'taskFailed')
        .toList();
    expect(failed, hasLength(4));
    expect(failed.every((e) => e.outcome == 'converged'), isTrue);
  });

  // 对账收敛曾把 approvalPending 一并
  // converged——「等审批不能埋没」是 ReconcilePlan.singles 的字段契约，且
  // 收敛后基线已含 interactionId、第二道闸不在册=该审批提醒永久丢失。
  // 修复：审批恒逐条发，收敛阈值只作用于其余 singles。
  test('审批豁免补发收敛：>3 singles 含审批 → 审批仍逐条 posted，其余 converged', () async {
    final stack = _FakeStack('d1');
    coordinator.attachStack(stack);
    stack.onTaskListRebuilt!(modelWith([
      for (var i = 1; i <= 6; i++) session('t$i', 'running'),
    ]));
    await Future<void>.delayed(Duration.zero);
    final waterline = 5000;
    coordinator.nowMs = () => waterline;
    await coordinator.onSuspended();
    // 离线期间：t1..t4 失败 + t5/t6 各出新审批 → singles=6（修复前全收敛，
    // 一条不发；修复后审批 2 条豁免逐发，失败 4 条仍按阈值收敛）。
    coordinator.nowMs = () => 9000;
    coordinator.onResumed(deviceSids: {'d1'});
    stack.onTaskListRebuilt!(modelWith([
      for (var i = 1; i <= 4; i++) session('t$i', 'error', lastActivityAt: 6000 + i),
      session('t5', 'running', interactionId: 'ix5', lastActivityAt: 7000),
      session('t6', 'running', interactionId: 'ix6', lastActivityAt: 7001),
    ]));
    expect(
      await until(
        () => posted.where((e) => e.kind == NotifyEventKind.approvalPending).length >= 2,
      ),
      isTrue,
      reason: '审批未在负载余量内逐条落地（修复前红：被 converged 吞掉零通知）',
    );
    expect(posted.where((e) => e.kind == NotifyEventKind.taskFailed), isEmpty,
        reason: '失败 4 条超阈值仍收敛不逐发（收敛策略对非审批不变）');
    expect(
      await until(
        () => store.recentLedger().where((e) => e.kind == 'taskFailed').length >= 4,
      ),
      isTrue,
      reason: '台账 converged 全量未在负载余量内落盘',
    );
    expect(
      store.recentLedger().where((e) => e.kind == 'taskFailed').every((e) => e.outcome == 'converged'),
      isTrue,
    );
    expect(
      store.recentLedger().where((e) => e.kind == 'approvalPending').every((e) => e.outcome == 'posted'),
      isTrue,
      reason: '审批豁免收敛=照常 posted（台账可核对）',
    );
  });

  // 状态层批：拆栈 dispose await 窗口内同 sid 新栈入表后，旧栈收尾的
  // detach 不得把新栈的监听/持久基线一起摘掉。
  test('detachStack 按栈身份：旧栈收尾不摘同 sid 新栈', () async {
    final oldStack = _FakeStack('sid-ident');
    coordinator.attachStack(oldStack);
    await oldStack.disposeStack(); // 模拟"拆栈已 dispose、detach 尚未执行"
    final newStack = _FakeStack('sid-ident');
    coordinator.attachStack(newStack);
    expect(coordinator.debugAttachedForTest('sid-ident'), isTrue);

    coordinator.detachStack('sid-ident', ifStack: oldStack);
    // 红：修复前按 sid 无边界摘除——新栈通知永久静默。
    expect(coordinator.debugAttachedForTest('sid-ident'), isTrue,
        reason: '旧栈身份 detach 不得摘掉新栈');

    coordinator.detachStack('sid-ident', ifStack: newStack);
    expect(coordinator.debugAttachedForTest('sid-ident'), isFalse);
  });

  // 状态层批：保活后台掉线对账水位只为已知设备记账（不无条件写，
  // 否则后台实时通知会被吞进聚合缓冲）。
  test('markPendingReconcile：仅已知栈记水位，重复调用保留最早水位', () {
    final stack = _FakeStack('sid-bg');
    coordinator.attachStack(stack);
    coordinator.nowMs = () => 5000;
    coordinator.markPendingReconcile('sid-bg');
    expect(coordinator.debugPendingReconcile['sid-bg'], 5000);

    coordinator.nowMs = () => 9000;
    coordinator.markPendingReconcile('sid-bg');
    expect(coordinator.debugPendingReconcile['sid-bg'], 5000,
        reason: '既有水位不被后到覆盖（水位越早对账覆盖越全）');

    coordinator.markPendingReconcile('sid-unknown');
    expect(coordinator.debugPendingReconcile.containsKey('sid-unknown'), isFalse,
        reason: '未挂接设备不写（AppState 只对自有栈调用，防御面）');
  });
}
