import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/notify/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/notify_core.dart';

PhaseSnapshot snap({
  String phase = 'running',
  String? interactionId,
  String? pendingKind,
  String? pendingTool,
  String? preview,
  String? goalStatus,
  bool goalVerifyingSeen = false,
  String title = '任务A',
  int lastActivityAt = 1000,
}) => PhaseSnapshot(
  phase: phase,
  interactionId: interactionId,
  pendingKind: pendingKind,
  pendingTool: pendingTool,
  preview: preview,
  goalStatus: goalStatus,
  goalVerifyingSeen: goalVerifyingSeen,
  title: title,
  lastActivityAt: lastActivityAt,
);

void main() {
  const sid = 'dev1';
  group('diffTask 首见规则', () {
    test('首见不产事件（防首轮全量刷入轰炸），含带 pending 的首见', () {
      final events = diffTask(sid, 't1', null, snap(), atMs: 1);
      expect(events, isEmpty);
      final withPending = diffTask(
        sid, 't1', null, snap(interactionId: 'ix1'), atMs: 1);
      expect(withPending, isEmpty);
    });

    test('首见终态在对账模式且水位之后才计入聚合源', () {
      // 对账模式 + completedSuccess + lastActivityAt > 水位 → 计入
      final counted = diffTask(
        sid, 't1', null, snap(phase: 'completedSuccess', lastActivityAt: 2000),
        atMs: 1, countFirstSeenTerminal: true, sinceMs: 1500,
      );
      expect(counted.single.kind, NotifyEventKind.taskCompleted);
      // 水位之前完成（历史任务）→ 不计
      final old = diffTask(
        sid, 't1', null, snap(phase: 'completedSuccess', lastActivityAt: 1000),
        atMs: 1, countFirstSeenTerminal: true, sinceMs: 1500,
      );
      expect(old, isEmpty);
      // 非对账模式首见终态 → 不计
      final normal = diffTask(
        sid, 't1', null, snap(phase: 'completedSuccess', lastActivityAt: 2000),
        atMs: 1,
      );
      expect(normal, isEmpty);
    });

    // 状态层批：对账首见此前整体静默——"不在时新出现的等审批"永久漏报。
    test('对账模式首见携带待审批也产 approvalPending（非对账仍静默）', () {
      final events = diffTask(
        sid,
        't1',
        null,
        snap(
          interactionId: 'ix9',
          pendingKind: 'permission',
          lastActivityAt: 2000,
        ),
        atMs: 1,
        countFirstSeenTerminal: true,
        sinceMs: 1500,
      );
      expect(events, hasLength(1));
      expect(events.single.kind, NotifyEventKind.approvalPending);
      expect(events.single.interactionId, 'ix9');
      // 水位之前出现的 pending（历史 pending 重放）不报。
      final old = diffTask(
        sid,
        't1',
        null,
        snap(interactionId: 'ix9', lastActivityAt: 1000),
        atMs: 1,
        countFirstSeenTerminal: true,
        sinceMs: 1500,
      );
      expect(old, isEmpty);
    });
  });

  group('diffTask 终态迁移', () {
    test('running → completedSuccess = 任务完成', () {
      final e = diffTask(sid, 't1', snap(), snap(phase: 'completedSuccess'), atMs: 1);
      expect(e.single.kind, NotifyEventKind.taskCompleted);
      expect(e.single.channel, NotifyChannel.tasks);
    });

    test('prewarming → completedSuccess 也算完成', () {
      final e = diffTask(
        sid, 't1', snap(phase: 'prewarming'), snap(phase: 'completedSuccess'),
        atMs: 1);
      expect(e.single.kind, NotifyEventKind.taskCompleted);
    });

    test('running → completedInterrupted / error = 任务失败', () {
      for (final terminal in ['completedInterrupted', 'error']) {
        final e = diffTask(sid, 't1', snap(), snap(phase: terminal), atMs: 1);
        expect(e.single.kind, NotifyEventKind.taskFailed);
      }
    });

    test('终态→终态无事件；复活后再完成会再发', () {
      var e = diffTask(sid, 't1',
        snap(phase: 'completedSuccess'), snap(phase: 'completedSuccess'), atMs: 1);
      expect(e, isEmpty);
      // 用户追发消息复活
      e = diffTask(sid, 't1', snap(phase: 'completedSuccess'), snap(), atMs: 2);
      expect(e, isEmpty);
      e = diffTask(sid, 't1', snap(), snap(phase: 'completedSuccess'), atMs: 3);
      expect(e.single.kind, NotifyEventKind.taskCompleted);
    });

    test('对账兜底：终态→终态但完成时间在水位之后=漏掉的一轮（介入点2自证轮）', () {
      // 基线陈旧（写盘饿死），盘上还是上一轮的 completed——死亡窗口内
      // 又完整跑过一轮（lastActivityAt 越过水位）→ 必须计完成。
      final e = diffTask(
        sid, 't1',
        snap(phase: 'completedSuccess', lastActivityAt: 1000),
        snap(phase: 'completedSuccess', lastActivityAt: 5000),
        atMs: 9,
        countFirstSeenTerminal: true,
        sinceMs: 1000,
      );
      expect(e.single.kind, NotifyEventKind.taskCompleted);
      // 水位之前的（=我们见过的那轮）不重发
      final none = diffTask(
        sid, 't1',
        snap(phase: 'completedSuccess', lastActivityAt: 900),
        snap(phase: 'completedSuccess', lastActivityAt: 900),
        atMs: 10,
        countFirstSeenTerminal: true,
        sinceMs: 1000,
      );
      expect(none, isEmpty);
      // 非对账模式不触发兜底（常规差分语义不变）
      final normal = diffTask(
        sid, 't1',
        snap(phase: 'completedSuccess', lastActivityAt: 1000),
        snap(phase: 'completedSuccess', lastActivityAt: 5000),
        atMs: 11,
      );
      expect(normal, isEmpty);
    });

    test('对账兜底按当前终态分派（开源审查批B组5，H1 P2-02/H2 P1-1）：复活轮失败不得误报完成',
        () {
      // error → error：用户追发消息复活后再次失败——修复前恒 taskCompleted
      //（「任务完成」通知对失败轮次是方向性误导）。
      final again = diffTask(
        sid, 't1',
        snap(phase: 'error', lastActivityAt: 1000),
        snap(phase: 'error', lastActivityAt: 5000),
        atMs: 9,
        countFirstSeenTerminal: true,
        sinceMs: 1000,
      );
      expect(again.single.kind, NotifyEventKind.taskFailed,
          reason: '修复前红：终态→终态兜底不看 now.phase 恒报完成');
      // completedSuccess → completedInterrupted：复活轮被打断=失败语义。
      final interrupted = diffTask(
        sid, 't1',
        snap(phase: 'completedSuccess', lastActivityAt: 1000),
        snap(phase: 'completedInterrupted', lastActivityAt: 5000),
        atMs: 10,
        countFirstSeenTerminal: true,
        sinceMs: 1000,
      );
      expect(interrupted.single.kind, NotifyEventKind.taskFailed);
      // error → completedSuccess：复活轮成功=完成（正向不被收窄）。
      final recovered = diffTask(
        sid, 't1',
        snap(phase: 'error', lastActivityAt: 1000),
        snap(phase: 'completedSuccess', lastActivityAt: 5000),
        atMs: 11,
        countFirstSeenTerminal: true,
        sinceMs: 1000,
      );
      expect(recovered.single.kind, NotifyEventKind.taskCompleted);
    });
  });

  group('diffTask 审批差分（语义去重键=interactionId）', () {
    test('新 interactionId 出现 = 等审批；同 id 重放无事件', () {
      final e = diffTask(sid, 't1', snap(), snap(interactionId: 'ix1'), atMs: 1);
      expect(e.single.kind, NotifyEventKind.approvalPending);
      expect(e.single.channel, NotifyChannel.approvals);
      // 重连重放：同 interactionId
      final replay = diffTask(
        sid, 't1', snap(interactionId: 'ix1'), snap(interactionId: 'ix1'),
        atMs: 2);
      expect(replay, isEmpty);
    });

    test('审批解决（pending 消失）后另一轮新审批再发', () {
      var e = diffTask(sid, 't1', snap(), snap(interactionId: 'ix1'), atMs: 1);
      expect(e.single.kind, NotifyEventKind.approvalPending);
      e = diffTask(sid, 't1', snap(interactionId: 'ix1'), snap(), atMs: 2);
      expect(e, isEmpty);
      e = diffTask(sid, 't1', snap(), snap(interactionId: 'ix2'), atMs: 3);
      expect(e.single.kind, NotifyEventKind.approvalPending);
    });
  });

  group('diffTask Goal 里程碑', () {
    test('active → verified = 目标达成', () {
      final e = diffTask(
        sid, 't1', snap(goalStatus: 'active'), snap(goalStatus: 'verified'),
        atMs: 1);
      expect(e.single.kind, NotifyEventKind.goalSettled);
      expect(e.single.detail, 'verified');
      expect(e.single.channel, NotifyChannel.goals);
    });

    test('F25：active → verifying = 目标验证中（首见通知；旧语义静默已按拍板升级）',
        () {
      final e = diffTask(
        sid, 't1', snap(goalStatus: 'active'), snap(goalStatus: 'verifying'),
        atMs: 2);
      expect(e.single.kind, NotifyEventKind.goalVerifying);
      expect(e.single.channel, NotifyChannel.goals);
    });

    test('notSatisfied/failed 同为落定；落定→落定不重发', () {
      final e = diffTask(
        sid, 't1', snap(goalStatus: 'active'), snap(goalStatus: 'failed'),
        atMs: 1);
      expect(e.single.kind, NotifyEventKind.goalSettled);
      final same = diffTask(
        sid, 't1', snap(goalStatus: 'failed'), snap(goalStatus: 'notSatisfied'),
        atMs: 2);
      expect(same, isEmpty);
    });

    test('F25：迭代循环去重——goalVerifyingSeen 后 verifying→active→verifying 不重发',
        () {
      // 首轮进入：未记账 → 发。
      final first = diffTask(
        sid, 't1', snap(goalStatus: 'active'), snap(goalStatus: 'verifying'),
        atMs: 1);
      expect(first.single.kind, NotifyEventKind.goalVerifying);
      // 记账后的下一轮（seen=true 经基线回写）：循环再入不发。
      final loop = diffTask(
        sid, 't1',
        snap(goalStatus: 'active', goalVerifyingSeen: true),
        snap(goalStatus: 'verifying'),
        atMs: 2);
      expect(loop, isEmpty, reason: '迭代循环防轰炸（修复前红=每次 verifying 都发）');
    });

    test('F25：goal 落定重置记账——新一轮目标 verifying 再发', () {
      final again = diffTask(
        sid, 't1',
        snap(goalStatus: 'active', goalVerifyingSeen: true),
        snap(goalStatus: 'verifying'),
        atMs: 1,
      );
      expect(again, isEmpty);
      // 落定后（基线 seen 已被 diffSnapshots 重置）新一轮再入 → 发。
      final fresh = diffTask(
        sid, 't1', snap(goalStatus: 'active'), snap(goalStatus: 'verifying'),
        atMs: 2);
      expect(fresh.single.kind, NotifyEventKind.goalVerifying);
    });
  });

  group('F25：diffSnapshots verifying 记账回写', () {
    test('verifying 在场 → 下一轮基线 seen=true；落定重置；循环保持', () {
      // active → verifying：事件 + 基线 seen=true。
      final r1 = diffSnapshots(
        sid, {'t1': snap(goalStatus: 'active')},
        {'t1': snap(goalStatus: 'verifying')},
        atMs: 1);
      expect(r1.events.single.kind, NotifyEventKind.goalVerifying);
      expect(r1.nextBaselines['t1']!.goalVerifyingSeen, isTrue);
      // 循环回 active：无事件，seen 保持（去重窗口跨迭代）。
      final r2 = diffSnapshots(
        sid, r1.nextBaselines, {'t1': snap(goalStatus: 'active')}, atMs: 2);
      expect(r2.events, isEmpty);
      expect(r2.nextBaselines['t1']!.goalVerifyingSeen, isTrue);
      // 再入 verifying：记账拦截，不再发。
      final r3 = diffSnapshots(
        sid, r2.nextBaselines, {'t1': snap(goalStatus: 'verifying')}, atMs: 3);
      expect(r3.events, isEmpty, reason: '迭代循环去重');
      // 落定：落定事件 + seen 重置（新一轮目标重新通知）。
      final r4 = diffSnapshots(
        sid, r3.nextBaselines, {'t1': snap(goalStatus: 'verified')}, atMs: 4);
      expect(r4.events.single.kind, NotifyEventKind.goalSettled);
      expect(r4.nextBaselines['t1']!.goalVerifyingSeen, isFalse);
    });

    test('F26：审批事件带 toolName、完成事件带 preview 透传', () {
      final ap = diffTask(
        sid, 't1',
        snap(),
        snap(interactionId: 'ix1', pendingKind: 'permission', pendingTool: 'Bash'),
        atMs: 1);
      expect(ap.single.tool, 'Bash');
      final done = diffTask(
        sid, 't1',
        snap(),
        snap(phase: 'completedSuccess', preview: '已修复登录黑屏问题'),
        atMs: 2);
      expect(done.single.preview, '已修复登录黑屏问题');
    });
  });

  group('diffSnapshots 整栈', () {
    test('基线中消失的任务从基线剔除（归档/删除）', () {
      final baselines = {'t1': snap(), 't2': snap()};
      final current = {'t1': snap(phase: 'completedSuccess')};
      final r = diffSnapshots(sid, baselines, current, atMs: 1);
      expect(r.events.single.taskId, 't1');
      expect(r.nextBaselines.keys, {'t1'});
    });
  });

  group('planReconcile 对账聚合', () {
    test('完成合并一条聚合，失败/审批/Goal 单发', () {
      final plan = planReconcile({
        'd1': [
          NotifyEvent(
            channel: NotifyChannel.tasks, kind: NotifyEventKind.taskCompleted,
            deviceSid: 'd1', taskId: 'a', title: 'A', atMs: 1),
          NotifyEvent(
            channel: NotifyChannel.tasks, kind: NotifyEventKind.taskFailed,
            deviceSid: 'd1', taskId: 'b', title: 'B', atMs: 1),
          NotifyEvent(
            channel: NotifyChannel.approvals,
            kind: NotifyEventKind.approvalPending,
            deviceSid: 'd1', taskId: 'c', title: 'C', atMs: 1),
        ],
        'd2': [
          NotifyEvent(
            channel: NotifyChannel.tasks, kind: NotifyEventKind.taskCompleted,
            deviceSid: 'd2', taskId: 'd', title: 'D', atMs: 1),
        ],
      }, atMs: 9);
      expect(plan.aggregated, isNotNull);
      expect(plan.aggregated!.kind, NotifyEventKind.awayAggregated);
      expect(plan.aggregated!.detail, '2'); // 跨设备聚合计数
      expect(plan.singles.map((e) => e.kind), containsAll([
        NotifyEventKind.taskFailed,
        NotifyEventKind.approvalPending,
      ]));
    });

    test('零完成 → 无聚合，仅单发透传', () {
      final plan = planReconcile({
        'd1': [
          NotifyEvent(
            channel: NotifyChannel.goals, kind: NotifyEventKind.goalSettled,
            deviceSid: 'd1', taskId: 'a', title: 'A', atMs: 1),
        ],
      }, atMs: 9);
      expect(plan.aggregated, isNull);
      expect(plan.singles, hasLength(1));
    });
  });

  group('notificationTtlMs 通道过期映射（决策 1）', () {
    test('approvals 不过期（可操作性强，保留到处理或回前台对账清理）', () {
      expect(notificationTtlMs('approvals'), isNull);
    });

    test('tasks/goals 30 分钟（时效性信息自动出栏；台账不受影响）', () {
      expect(notificationTtlMs('tasks'), 30 * 60 * 1000);
      expect(notificationTtlMs('goals'), 30 * 60 * 1000);
    });

    test('未知通道不过期（保守默认）', () {
      expect(notificationTtlMs('other'), isNull);
    });
  });

  group('shouldConvergeSingles 补发收敛阈值（决策 2）', () {
    test('≤3 逐条照发；>3 收敛只发聚合', () {
      expect(shouldConvergeSingles(0), isFalse);
      expect(shouldConvergeSingles(3), isFalse,
          reason: '边界值 3 恰好仍逐条（阈值=3，超过才收敛）');
      expect(shouldConvergeSingles(4), isTrue);
      expect(shouldConvergeSingles(20), isTrue);
    });
  });

  group('PhaseSnapshot 序列化', () {
    test('toJson/fromJson roundtrip', () {
      final s = snap(
        interactionId: 'ix9', pendingKind: 'permission',
        goalStatus: 'active', lastActivityAt: 42);
      final restored = PhaseSnapshot.fromJson(s.toJson());
      expect(restored.phase, s.phase);
      expect(restored.interactionId, 'ix9');
      expect(restored.goalStatus, 'active');
      expect(restored.lastActivityAt, 42);
      expect(restored, s); // == 不含 lastActivityAt/title（差分无关字段）
    });
  });

  group('两步式深链（2026-11-04 拍板）', () {
    test('NotifyTapPayload 携带 atMs 编码/解码往返', () {
      final p = NotifyTapPayload('sid-1', 'task-1', 'approvalPending',
          atMs: 1730000000000);
      final back = NotifyTapPayload.decode(p.encode())!;
      expect(back.deviceSid, 'sid-1');
      expect(back.taskId, 'task-1');
      expect(back.kind, 'approvalPending');
      expect(back.atMs, 1730000000000);
      // 旧载荷（无 at 键）兼容：atMs=0 表示无时间戳，页面不弹定位浮层。
      final legacy = NotifyTapPayload.decode(
          '{"sid":"s","task":"t","kind":"taskCompleted"}')!;
      expect(legacy.atMs, 0);
    });

    test('openTaskFromNotification 仅在有 atMs 时挂深链（无时间戳维持旧行为）', () {
      final app = AppState();
      // fullsweep-1108 状态层批：目标档案不可达时不挂深链（失败收口，
      // 防陈旧 atMs 被下一次会话误配对）——单测需先播种可达档案。
      app.profiles = [
        AccountV2Profile(
          deviceSid: 'sid-a',
          deviceMid: 'mid-a',
          deviceName: '电脑A',
          appVersion: '3.17.1',
          accountId: 'acc-1',
          label: '电脑A',
          addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ];
      app.openTaskFromNotification('sid-a', 'task-a');
      expect(app.pendingOpenTask?.taskId, 'task-a');
      expect(app.pendingDeepLinkAt, isNull, reason: '无时间戳不挂深链');
      app.openTaskFromNotification('sid-a', 'task-b', atMs: 1730000000000);
      expect(app.pendingOpenTask?.taskId, 'task-b');
      expect(app.pendingDeepLinkAt, 1730000000000);
      app.dispose();
    });
  });
}
