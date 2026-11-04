import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/notify_core.dart';
import 'package:zcode_pocket/state/notify_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notify_store_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  NotifyStore newStore() => NotifyStore(tmp);

  test('基线持久化 roundtrip：进程重启后差分基线不丢', () async {
    final s1 = newStore();
    await s1.load();
    s1.replaceBaselines('dev1', {
      't1': PhaseSnapshot(
        phase: 'running',
        interactionId: 'ix1',
        goalStatus: 'active',
        title: '任务A',
        lastActivityAt: 100,
      ),
    });
    await s1.flush();
    // "重启"：新 store 同目录
    final s2 = newStore();
    await s2.load();
    final restored = s2.baselinesOf('dev1')['t1'];
    expect(restored, isNotNull);
    expect(restored!.phase, 'running');
    expect(restored.interactionId, 'ix1');
    // 重连重放同 interactionId → 差分天然去重（notify_core 已测），
    // 基线恢复正确性在这里保证。
    final e = diffTask('dev1', 't1', restored,
      PhaseSnapshot(
        phase: 'running', interactionId: 'ix1', goalStatus: 'active',
        title: '任务A', lastActivityAt: 200,
      ), atMs: 1);
    expect(e, isEmpty);
  });

  test('已通知审批 id 第二道闸：markInteractionNotified 后判定去重', () async {
    final s = newStore();
    await s.load();
    expect(s.interactionNotified('ix1'), isFalse);
    s.markInteractionNotified('ix1', 1000);
    expect(s.interactionNotified('ix1'), isTrue);
    expect(s.interactionNotified('ix2'), isFalse);
    // 空 id 视作"已通知"（拿不到键时保守跳过，防无键重发）
    expect(s.interactionNotified(''), isTrue);
  });

  test('去重窗口持久化 + 7 天过期', () async {
    final s1 = newStore();
    await s1.load();
    final now = DateTime.now().millisecondsSinceEpoch;
    s1.markInteractionNotified('ix1', now);
    await s1.flush();
    final s2 = newStore();
    await s2.load();
    expect(s2.interactionNotified('ix1'), isTrue);
    // 过期清理（窗口 7 天）
    s2.markInteractionNotified('ix2', now + 8 * 24 * 3600 * 1000);
    expect(s2.interactionNotified('ix1'), isFalse,
        reason: '写入新条目触发 prune，超 7 天的 ix1 应被清掉');
  });

  test('台账 JSONL 追加 + 读取 + 点击回填', () async {
    final s = newStore();
    await s.load();
    await s.appendLedger(const LedgerEntry(
      ts: 1, kind: 'taskCompleted', deviceSid: 'd1', taskId: 't1',
      title: 'A', outcome: 'posted'));
    await s.appendLedger(const LedgerEntry(
      ts: 2, kind: 'approvalPending', deviceSid: 'd1', taskId: 't2',
      title: 'B', outcome: 'posted'));
    // H1-P3-02 修复（只回填 posted 行）：deduped 行不得被标记——
    // 同一任务更近的 deduped 行不得抢走 posted 行的回填目标。
    await s.appendLedger(const LedgerEntry(
      ts: 3, kind: 'approvalPending', deviceSid: 'd1', taskId: 't3',
      title: 'C', outcome: 'deduped'));
    final s2 = newStore();
    await s2.load();
    final ledger = s2.recentLedger();
    expect(ledger, hasLength(3));
    expect(ledger.last.outcome, 'deduped');
    // 点击回填（倒序找最近未点击的同任务条目）
    await s2.markClicked('t2', 99);
    final s3 = newStore();
    await s3.load();
    final lastPosted = s3.recentLedger().firstWhere((e) => e.taskId == 't2');
    expect(lastPosted.clicked, isTrue);
    expect(s3.recentLedger().first.clicked, isFalse);
    expect(
      s3.recentLedger().firstWhere((e) => e.taskId == 't3').clicked,
      isFalse,
      reason: 'deduped 行不得被回填（H1-P3-02）',
    );
    // 回填不得新增行（原位替换，不是 append）
    expect(s3.recentLedger(), hasLength(3));
    final s4 = newStore();
    await s4.load();
    await s4.markClicked('t2', 100);
    expect(s4.recentLedger(), hasLength(3), reason: '二次点击也不重复');
  });

  test('基线写盘防饿死（介入点2自证轮实锤）：首写立即+持续刷新 10s 必落盘', () async {
    final dir = await Directory.systemTemp.createTemp('notify_starve');
    final s = NotifyStore(dir);
    await s.load();
    // 首次 replace → 立即写（_lastBaselineWriteAt=0 → now-0>10s）
    s.replaceBaselines('d1', {
      't1': PhaseSnapshot(phase: 'running', title: 'A', lastActivityAt: 1),
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(
      File('${dir.path}${Platform.pathSeparator}notify-baselines.json')
          .existsSync(),
      isTrue,
      reason: '首次基线写入应立即落盘');
    // 持续每秒刷新（活跃会话节奏）超过 10s——防抖被顺延也必须已把
    // 中途状态写盘（最大等待兜底）；结束时盘中状态=最终状态。
    for (var i = 0; i < 11; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      s.replaceBaselines('d1', {
        't1': PhaseSnapshot(
          phase: 'running', title: 'A', lastActivityAt: 100 + i),
      });
    }
    // 不 flush，直接读盘（饿死场景=进程被杀，无人 flush）。末两次刷新
    // 可能还在 2s 防抖里——但 10s 最大等待必须已把接近末尾的状态写盘。
    final raw = await File(
      '${dir.path}${Platform.pathSeparator}notify-baselines.json',
    ).readAsString();
    final persisted = int.parse(
      RegExp(r'"lastActivityAt":\s*(\d+)').firstMatch(raw)!.group(1)!,
    );
    expect(persisted, greaterThanOrEqualTo(105),
        reason: '10s 最大等待必须让连续刷新落盘（否则死亡窗口丢失）；'
            '实际落盘值 $persisted');
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('dropDevice 清空该设备基线', () async {
    final s = newStore();
    await s.load();
    s.replaceBaselines('d1', {
      't1': PhaseSnapshot(
        phase: 'running', title: 'A', lastActivityAt: 1),
    });
    s.dropDevice('d1');
    await s.flush();
    expect(s.baselinesOf('d1'), isEmpty);
  });
}
