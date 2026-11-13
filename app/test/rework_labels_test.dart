import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/turn_model.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/conversation.dart';

TurnWork _work({
  String state = 'completedSuccess',
  String? origin,
  int? startedAt,
  int? endedAt,
  int? activeMs,
}) {
  return TurnWork({
    'state': state,
    if (origin != null) 'origin': origin,
    if (startedAt != null) 'startedAt': startedAt,
    if (endedAt != null) 'endedAt': endedAt,
    if (activeMs != null) 'activeMs': activeMs,
  });
}

void main() {
  group('workBarLabel（官方三态 + 中断两态，F8）', () {
    test('运行中：startedAt 实时计时；无 startedAt 只显示「工作中」', () {
      expect(
        workBarLabel(
          _work(state: 'running', startedAt: 1_000_000),
          nowMs: 1_061_000,
        ),
        '工作中 1 分 1 秒',
      );
      expect(workBarLabel(_work(state: 'running')), '工作中');
    });

    test('完成：activeMs→已工作 X；缺时长→已处理（官方无"一会儿"）', () {
      expect(workBarLabel(_work(activeMs: 61_000)), '已工作 1 分 1 秒');
      expect(workBarLabel(_work()), '已处理');
      // activeMs 缺省退回 endedAt-startedAt
      expect(
        workBarLabel(_work(startedAt: 1000, endedAt: 62_000)),
        '已工作 1 分 1 秒',
      );
    });

    test('中断：editRerun→已被新消息中断；其余→已停止；失败→失败', () {
      expect(
        workBarLabel(_work(state: 'completedInterrupted', origin: 'editRerun')),
        '已被新消息中断',
      );
      expect(
        workBarLabel(_work(state: 'completedInterrupted', origin: 'userInput')),
        '已停止',
      );
      expect(workBarLabel(_work(state: 'failed')), '失败');
    });
  });

  group('reasoningLabel（官方 reasoning.tsx 文案，F8）', () {
    test('流式收起→正在思考；流式展开→思考 · 持续了 X', () {
      expect(
        reasoningLabel(streaming: true, expanded: false),
        '正在思考',
      );
      expect(
        reasoningLabel(
          streaming: true,
          expanded: true,
          firstSeen: DateTime.fromMillisecondsSinceEpoch(1_000_000),
          now: DateTime.fromMillisecondsSinceEpoch(1_005_000),
        ),
        '思考 · 持续了 5 秒',
      );
    });

    test('完成：有时长→思考 · 持续了 X；无→持续了几秒', () {
      expect(
        reasoningLabel(streaming: false, expanded: false, durationMs: 5000),
        '思考 · 持续了 5 秒',
      );
      expect(
        reasoningLabel(streaming: false, expanded: false),
        '思考 · 持续了几秒',
      );
    });
  });

  group('toolStatusLabel（官方状态词表 + 终态兜底，盲审 #11）', () {
    test('官方词表', () {
      expect(toolStatusLabel('pending', turnRunning: true), '等待中');
      expect(toolStatusLabel('running', turnRunning: true), '执行中');
      // 对抗审查 4-3'：参数流式写入中=「等待中」（官方 toolCallRowAdapter
      // pending 词表），仅真正执行才是「执行中」。
      expect(toolStatusLabel('inputStreaming', turnRunning: true), '等待中');
      expect(toolStatusLabel('pendingApproval', turnRunning: true), '等待确认');
      expect(toolStatusLabel('error', turnRunning: true), '执行失败');
      expect(toolStatusLabel('rejected', turnRunning: true), '已拒绝');
      expect(toolStatusLabel('cancelled', turnRunning: true), '已停止');
      expect(toolStatusLabel('success', turnRunning: true), '已执行');
      expect(toolStatusLabel('', turnRunning: true), '已执行');
    });

    test('回合终态兜底：非终态一律显示已停止', () {
      expect(toolStatusLabel('running', turnRunning: false), '已停止');
      expect(toolStatusLabel('inputStreaming', turnRunning: false), '已停止');
      expect(toolStatusLabel('pending', turnRunning: false), '已停止');
      // 终态词不受影响
      expect(toolStatusLabel('error', turnRunning: false), '执行失败');
      expect(toolStatusLabel('success', turnRunning: false), '已执行');
    });
  });


group('TaskListModel dormant（F1 冷工作区）', () {
  test('dormant 时不等 sessions.ready，通道历史任务直接渲染', () {
    final model = TaskListModel(
      sessions: SessionsIndexState(),
      workspaceKey: 'k',
      dormant: true,
    );
    // si 永不 ready（冷工作区）——通道三列表到达即出卡。
    model.applyChannelLists(
      active: [
        {
          'taskId': 's1',
          'title': '冷工作区历史任务',
          'status': 'completed',
          'lastActivityAt': 1,
        },
      ],
      pinnedIds: const [],
      archivedIds: const [],
    );
    expect(model.cards, isNotEmpty);
    expect(model.cards.first.title, '冷工作区历史任务');
    expect(model.cards.first.historical, isTrue);
    model.dispose();
  });

  test('非 dormant 维持 ready 门槛（不回归）', () {
    final model = TaskListModel(
      sessions: SessionsIndexState(),
      workspaceKey: 'k',
    );
    model.applyChannelLists(
      active: [
        {'taskId': 's1', 'title': 't', 'status': 'completed',
         'lastActivityAt': 1},
      ],
      pinnedIds: const [],
      archivedIds: const [],
    );
    expect(model.cards, isEmpty);
    model.dispose();
  });
});

  group('kStaticModeOptions（F9 兜底，官方 ZCODE_AGENT_MODE_OPTIONS 对位）', () {
    test('四模式齐备且 id 为协议枚举', () {
      expect(
        kStaticModeOptions.map((m) => m.id).toList(),
        ['build', 'guarded', 'plan', 'yolo'],
      );
      for (final m in kStaticModeOptions) {
        expect(m.name, isNotEmpty);
        expect(m.description, isNotEmpty);
      }
    });
  });
}
