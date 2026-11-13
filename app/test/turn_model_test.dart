import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

Map<String, dynamic> _row(
  int rowId,
  String kind, {
  Map<String, dynamic> extra = const {},
}) {
  return {'rowId': rowId, 'kind': kind, ...extra};
}

void main() {
  group('turnWorkExpandable（③ 对齐桌面三层折叠：展开=想看步骤列表）', () {
    test('有工作行（含全成功工具）→ 可展开，与工具显示开关无关', () {
      expect(
        turnWorkExpandable([
          {'kind': 'toolCall', 'status': 'success'},
          {'kind': 'toolCall', 'status': 'success'},
        ]),
        isTrue,
      );
    });
    test('仅思考行 → 可展开', () {
      expect(
        turnWorkExpandable([
          {'kind': 'reasoning', 'state': 'done'},
        ]),
        isTrue,
      );
    });
    test('空工作集 → 不可展开', () {
      expect(turnWorkExpandable([]), isFalse);
    });
  });

  group('formatWorkDuration', () {
    test('官方 workDuration.ts 对齐（至少 1 秒/只写非零单位/最多两段）', () {
      expect(formatWorkDuration(0), '1 秒'); // 官方：秒下限 1
      expect(formatWorkDuration(59_000), '59 秒');
      expect(formatWorkDuration(61_000), '1 分 1 秒');
      expect(formatWorkDuration(60_000), '1 分'); // 非零单位才写
      expect(formatWorkDuration(3_660_000), '1 时 1 分'); // 有时+分不写秒
      expect(formatWorkDuration(90_000_000), '1 天 1 时');
    });
  });

  group('buildChatItems', () {
    test('完整 turn：header+思考+工具折叠为一条，正文独立', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '帮我改代码'}),
        _row(
          2,
          'turnHeader',
          extra: {
            'state': 'completedSuccess',
            'startedAt': 1000,
            'endedAt': 62_000,
            'activeMs': 61_000,
          },
        ),
        _row(
          3,
          'reasoning',
          extra: {'text': '想想…', 'state': 'complete', 'durationMs': 5000},
        ),
        _row(
          4,
          'toolCall',
          extra: {
            'toolName': 'Edit',
            'status': 'success',
            'inputText': 'a.dart',
          },
        ),
        _row(5, 'assistantText', extra: {'text': '改好了', 'state': 'complete'}),
      ]);
      // 2026-10-22 分组模型修复：正文不打断工作段——整轮一条状态条，
      // 正文按时间序进段（收起态外置可见正文）。
      expect(items.length, 2);
      expect(items[0], isA<UserItem>());
      final bar = items[1] as TurnBarItem;
      expect(bar.work.header?['state'], 'completedSuccess');
      expect(bar.work.work.length, 3); // reasoning + toolCall + 正文
      expect(bar.work.activeMs, 61_000);
      expect(bar.work.running, isFalse);
      expect(bar.work.visibleTextRow?['text'], '改好了');
    });

    test('运行中 turn：header.state=running 为权威', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': 'go'}),
        _row(2, 'turnHeader', extra: {'state': 'running', 'startedAt': 1000}),
        _row(3, 'reasoning', extra: {'text': '…', 'state': 'streaming'}),
      ]);
      final bar = items[1] as TurnBarItem;
      expect(bar.work.running, isTrue);
      expect(bar.work.activeMs, isNull); // 运行中无权威工时
      expect(bar.work.startedAtMs, 1000);
    });

    test('无 turnHeader 的旧行序：工作行自动成组', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': 'q'}),
        _row(2, 'reasoning', extra: {'text': 'r', 'state': 'complete'}),
        _row(3, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(4, 'assistantText', extra: {'text': 'a', 'state': 'complete'}),
        _row(5, 'toolCall', extra: {'toolName': 'Read', 'status': 'success'}),
        _row(6, 'assistantText', extra: {'text': 'b', 'state': 'complete'}),
      ]);
      // 官方 splitVisualWorkSegments：正文不断段——整段一条。
      // 条形：user | bar(2,3,正文a,5,正文b)
      expect(items.length, 2);
      final bar = items[1] as TurnBarItem;
      expect(bar.work.work.length, 5);
      expect(bar.work.visibleTextRow?['text'], 'b');
    });

    test('turn 条占位在首个工作行位置（正文先行也不乱序）', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': 'q'}),
        _row(2, 'turnHeader', extra: {'state': 'completedSuccess'}),
        _row(3, 'reasoning', extra: {'text': 'r', 'state': 'complete'}),
        _row(4, 'assistantText', extra: {'text': '中途正文', 'state': 'complete'}),
        _row(5, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(6, 'assistantText', extra: {'text': '结尾', 'state': 'complete'}),
      ]);
      // 2026-10-22 修复：正文不断段——一个回合一条状态条（官方语义）。
      // user | bar(reasoning3, 中途正文4, tool5, 结尾6)
      expect(items.length, 2);
      final bar = items[1] as TurnBarItem;
      expect(bar.work.header?['state'], 'completedSuccess');
      expect(bar.work.work.length, 4);
      expect(bar.work.work[0]['kind'], 'reasoning');
      expect(bar.work.work[1]['text'], '中途正文');
      expect(bar.work.work[2]['toolName'], 'Bash');
      expect(bar.work.visibleTextRow?['text'], '结尾');
    });

    test('流式空正文保留为思考占位', () {
      final items = buildChatItems([
        _row(1, 'assistantText', extra: {'text': '', 'state': 'streaming'}),
        _row(2, 'assistantText', extra: {'text': '', 'state': 'complete'}),
      ]);
      expect(items.length, 1);
      // 空正文占位进段（展开态可见流式标记）。
      final bar = items[0] as TurnBarItem;
      expect(bar.work.work.single['state'], 'streaming');
      expect(bar.work.running, isTrue);
    });

    test('guided 输入切独立工作段（官方 splitVisualWorkSegments 对齐）', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '任务'}),
        _row(2, 'turnHeader', extra: {'state': 'completedSuccess'}),
        _row(3, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(4, 'userInput', extra: {'text': '引导', 'guided': true}),
        _row(5, 'toolCall', extra: {'toolName': 'Read', 'status': 'success'}),
      ]);
      // user 任务 | bar(tool3) | user 引导 | bar(tool5)——guide 各自一条状态条。
      expect(items.length, 4);
      expect((items[1] as TurnBarItem).work.work.single['toolName'], 'Bash');
      expect(items[2], isA<UserItem>());
      expect((items[3] as TurnBarItem).work.work.single['toolName'], 'Read');
    });

    test('guided 多段折叠键按段独立（2026-11-04 用户拍板）', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '任务'}),
        _row(2, 'turnHeader', extra: {'state': 'completedSuccess'}),
        _row(3, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(4, 'userInput', extra: {'text': '引导', 'guided': true}),
        _row(5, 'toolCall', extra: {'toolName': 'Read', 'status': 'success'}),
      ]);
      final bars = items.whereType<TurnBarItem>().toList();
      expect(bars, hasLength(2));
      // 同一轮 header rowId=2 下的两段：段 0 保持原键，段 1 并入段号——
      // 展开/收起一段不再连带另一段（修复前两段同键连动）。
      expect(bars[0].work.segmentIndex, 0);
      expect(bars[1].work.segmentIndex, 1);
      expect(bars[0].work.collapseKeyId, 2);
      expect(bars[1].work.collapseKeyId, 2 * 1000 + 1);
      expect(bars[0].work.collapseKeyId == bars[1].work.collapseKeyId,
          isFalse, reason: '多段必须各自独立折叠键');
    });

    test('B9：guided 多段工时按段（workSegments 事实 activeMs，triggerEntityId 匹配优先）',
        () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '任务'}),
        _row(2, 'turnHeader', extra: {
          'state': 'completedSuccess',
          'workSegments': [
            {'activeMs': 60_000},
            {'triggerEntityId': 'other', 'activeMs': 1},
            {'triggerEntityId': 'e4', 'activeMs': 30_000},
          ],
        }),
        _row(3, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(4, 'userInput', extra: {
          'text': '引导',
          'guided': true,
          'entityId': 'e4',
        }),
        _row(5, 'toolCall', extra: {'toolName': 'Read', 'status': 'success'}),
      ]);
      final b0 = (items[1] as TurnBarItem).work;
      final b1 = (items[3] as TurnBarItem).work;
      expect(b0.isMultiSegment, isTrue);
      expect(b0.activeMs, 60_000, reason: '前段=workSegments[0]（下标兜底）');
      expect(b1.activeMs, 30_000,
          reason: '后段按 triggerEntityId 精确匹配（非下标 1）——修复前红=整轮 activeMs/null');
    });

    test('B9：运行轮的 guided 前段不显"工作中"（官方 segmentCompleted）+计时锚=段起点',
        () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '任务'}),
        _row(2, 'turnHeader', extra: {
          'state': 'running',
          'startedAt': 0,
          'workSegments': [
            {'activeMs': 60_000, 'startedAt': 0},
            {'triggerEntityId': 'e4', 'startedAt': 65_000},
          ],
        }),
        _row(3, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(4, 'userInput', extra: {
          'text': '引导',
          'guided': true,
          'entityId': 'e4',
          'createdAt': 65_000,
        }),
        _row(5, 'toolCall', extra: {'toolName': 'Read', 'status': 'running'}),
      ]);
      final b0 = (items[1] as TurnBarItem).work;
      final b1 = (items[3] as TurnBarItem).work;
      // 修复前红：前段 stateLabel='running'→"工作中 N 秒"（误显）。
      expect(b0.stateLabel, 'completed');
      expect(b0.running, isFalse);
      expect(workBarLabel(b0), '已工作 1 分');
      expect(b1.stateLabel, 'running');
      expect(b1.running, isTrue);
      expect(b1.startedAtMs, 65_000,
          reason: '运行计时锚=段事实 startedAt（整轮 startedAt 会把前段时长并入）');
    });

    test('B9：旧快照无 workSegments 退 trigger 行时间边界（官方 legacy 兜底）', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '任务'}),
        _row(2, 'turnHeader', extra: {
          'state': 'completedSuccess',
          'startedAt': 0,
          'endedAt': 9000,
        }),
        _row(3, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        _row(4, 'userInput', extra: {
          'text': '引导',
          'guided': true,
          'createdAt': 3000,
        }),
        _row(5, 'toolCall', extra: {'toolName': 'Read', 'status': 'success'}),
      ]);
      final b0 = (items[1] as TurnBarItem).work;
      final b1 = (items[3] as TurnBarItem).work;
      expect(b0.activeMs, 3000,
          reason: '前段=header.startedAt→trigger.createdAt（修复前红=整轮 endedAt-startedAt=9000）');
      expect(b1.activeMs, 6000, reason: '末段=trigger.createdAt→header.endedAt');
    });
    test('subagent 独立条目，不入工作组', () {
      final items = buildChatItems([
        _row(1, 'subagent', extra: {'subagentType': 'Explore'}),
        _row(2, 'reasoning', extra: {'text': 'r', 'state': 'complete'}),
      ]);
      // 2026-10-22：subagent 入工作组时间序（官方 flowItems 同组）。
      expect(items.length, 1);
      final bar = items[0] as TurnBarItem;
      expect(bar.work.work.length, 2);
      expect(bar.work.work[0]['kind'], 'subagent');
      expect(bar.work.work[1]['kind'], 'reasoning');
    });
  });

  group('F5 重做：轮尾文件变更卡与轮归属', () {
    test('完整轮：文件卡落位在正文之后', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': '改代码'}),
        _row(
          2,
          'turnHeader',
          extra: {
            'state': 'completedSuccess',
            'entityId': 'turn-2',
            'fileChanges': {'files': 2, 'additions': 10, 'deletions': 3},
          },
        ),
        _row(3, 'reasoning', extra: {'text': 'r', 'state': 'complete'}),
        _row(4, 'assistantText', extra: {'text': '好了', 'state': 'complete'}),
      ]);
      // user | bar(含正文) | 文件卡（正文进段，卡仍落轮尾）
      expect(items.length, 3);
      expect(items[2], isA<FileSummaryItem>());
      final card = items[2] as FileSummaryItem;
      expect((card.fileChanges!['files'] as num).toInt(), 2);
    });

    test('正文后工具行开新段：文件卡仍归属本轮（在下一轮边界落位）', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': 'a'}),
        _row(
          2,
          'turnHeader',
          extra: {
            'state': 'completedSuccess',
            'entityId': 'turn-2',
            'fileChanges': {'files': 1, 'additions': 2, 'deletions': 0},
          },
        ),
        _row(4, 'assistantText', extra: {'text': '中途', 'state': 'complete'}),
        _row(5, 'toolCall', extra: {'toolName': 'Bash', 'status': 'success'}),
        // 真实 wire：下一轮 header 先于其 userInput 到达（2026-10-22 行序
        // 修正，product-projection.ts 实证）。
        _row(6, 'turnHeader', extra: {'state': 'completedSuccess'}),
        _row(7, 'userInput', extra: {'text': 'b'}),
      ]);
      // user a | bar(中途正文+工具) | 文件卡(轮1 收口) | user b
      expect(items.length, 4);
      expect(items[0], isA<UserItem>());
      expect(items[1], isA<TurnBarItem>());
      expect((items[1] as TurnBarItem).work.work.length, 2);
      expect(items[2], isA<FileSummaryItem>());
      expect(items[3], isA<UserItem>());
    });

    test('连续两轮都有 fileChanges：两卡顺序正确', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': 'a'}),
        _row(
          2,
          'turnHeader',
          extra: {
            'state': 'completedSuccess',
            'entityId': 'turn-2',
            'fileChanges': {'files': 1, 'additions': 1, 'deletions': 0},
          },
        ),
        _row(3, 'assistantText', extra: {'text': 'r1', 'state': 'complete'}),
        _row(4, 'userInput', extra: {'text': 'b'}),
        _row(
          5,
          'turnHeader',
          extra: {
            'state': 'completedSuccess',
            'entityId': 'turn-5',
            'fileChanges': {'files': 3, 'additions': 5, 'deletions': 2},
          },
        ),
        _row(6, 'assistantText', extra: {'text': 'r2', 'state': 'complete'}),
      ]);
      final cards = items.whereType<FileSummaryItem>().toList();
      expect(cards.length, 2);
      expect((cards[0].fileChanges!['files'] as num).toInt(), 1);
      expect((cards[1].fileChanges!['files'] as num).toInt(), 3);
    });

    test('files=0 不出卡；turnHeader 在 userInput 之后（旧快照行序）兜底成组', () {
      final items = buildChatItems([
        _row(1, 'userInput', extra: {'text': 'q'}),
        _row(
          2,
          'turnHeader',
          extra: {
            'state': 'completedSuccess',
            'fileChanges': {'files': 0, 'additions': 0, 'deletions': 0},
          },
        ),
        _row(3, 'reasoning', extra: {'text': 'r', 'state': 'complete'}),
      ]);
      // header 落在 userInput 之后（旧快照行序）：仍被本轮认领——
      // 工时/文件摘要不丢（晚到的 turnHeader 语义上属于该轮）。
      expect(items.whereType<FileSummaryItem>(), isEmpty);
      final bar = items[1] as TurnBarItem;
      expect(bar.work.header?['state'], 'completedSuccess');
      expect(bar.work.work.length, 1);
    });

    test('stateLabel：中断轮按 origin 区分文案', () {
      TurnWork workOf(Map<String, dynamic> extra) =>
          (buildChatItems([
            _row(1, 'userInput', extra: {'text': 'q'}),
            _row(2, 'turnHeader', extra: extra),
            _row(3, 'reasoning', extra: {'text': 'r', 'state': 'complete'}),
          ])[1] as TurnBarItem).work;
      expect(
        workOf({'state': 'completedInterrupted', 'origin': 'editRerun'})
            .stateLabel,
        'interrupted',
      );
      expect(workOf({'state': 'completedInterrupted'}).stateLabel, 'stopped');
      expect(workOf({'state': 'failed'}).stateLabel, 'failed');
      expect(workOf({'state': 'running'}).stateLabel, 'running');
      expect(workOf({'state': 'completedSuccess'}).stateLabel, 'completed');
    });
  });

  group('工具摘要', () {
    test('工具名中文化 + 输入预览截断', () {
      expect(toolDisplayName('Edit'), '编辑');
      expect(toolDisplayName('Bash'), '运行命令');
      expect(toolDisplayName('Whatever'), 'Whatever');
      expect(toolPreview({'inputText': 'a\nb\nc'}), 'a');
      final long = 'x' * 100;
      expect(toolPreview({'inputText': long}).length, 73); // 72 + 省略号
      expect(toolPreview({}), '');
    });
    test('toolPreview JSON 参数语义化（用户拍板：不显示原始 JSON）', () {
      expect(
        toolPreview({
          'inputText': '{"file_path":"G:/proj/main.dart","limit":50}',
        }),
        // 对抗审查 3-8：文件名为主（官方 renderFileChip 叶子名+路径窄隐）。
        'main.dart',
      );
      expect(
        toolPreview({'inputText': '{"command":"npm test","timeout":3}'}),
        'npm test',
      );
      expect(
        toolPreview({
          'toolName': 'Grep',
          'inputText': '{"pattern":"TODO","path":"lib"}',
        }),
        '"TODO"',
      );
      // AskUserQuestion：questions 数组取首题问题文本（不再裸 JSON）。
      expect(
        toolPreview({
          'toolName': 'AskUserQuestion',
          'inputText':
              '{"questions":[{"question":"用哪个方案？","options":[]}]}',
        }),
        '用哪个方案？',
      );
      // 非 JSON 纯文本命令：首行原样。
      expect(
        toolPreview({'inputText': 'git status\nsecond'}),
        'git status',
      );
    });
  });

  // V2 折叠策略（2026-10-22 审美优化轮，官方行为补交付）：
  // 手动记忆 > 失败自动展开 > 默认收起；思考 userInteracted 锁。
  group('V2 折叠策略', () {
    test('toolOpenDecision：手动记忆优先于一切', () {
      expect(toolOpenDecision(true, '已执行'), isTrue);
      expect(toolOpenDecision(false, '执行失败'), isFalse); // 用户点收让位
    });

    test('toolOpenDecision：失败/被拒自动展开，其余默认收起', () {
      expect(toolOpenDecision(null, '执行失败'), isTrue);
      expect(toolOpenDecision(null, '已拒绝'), isTrue);
      expect(toolOpenDecision(null, '已执行'), isFalse);
      expect(toolOpenDecision(null, '已停止'), isFalse);
      expect(toolOpenDecision(null, '执行中'), isFalse);
    });

    test('reasoningAutoCollapse：用户交互过则不自动收起', () {
      expect(reasoningAutoCollapse(userToggled: false), isTrue);
      expect(reasoningAutoCollapse(userToggled: true), isFalse);
    });
  });

  // 2026-10-22 真机验收③回归：wire 真实行序是 [turnHeader][userInput]
  // [工作行…]（product-projection.ts 先 append header 再 append input）。
  // 旧实现 userInput 处 closeTurn 清掉本轮 header → 全部回合空 header
  // （文案兜底「已处理」+运行中被判完成默认收起）——真实行序必须覆盖。
  group('真实 wire 行序（header 先于 userInput）', () {
    test('完成 turn：header 保住，文案=已工作 X 分 X 秒', () {
      final items = buildChatItems([
        _row(1, 'turnHeader', extra: {
          'state': 'completedSuccess',
          'startedAt': 1000,
          'endedAt': 62_000,
          'activeMs': 61_000,
        }),
        _row(2, 'userInput', extra: {'text': '帮我改代码'}),
        _row(3, 'toolCall', extra: {
          'toolName': 'Edit',
          'status': 'success',
          'inputText': 'a.dart',
        }),
        _row(4, 'assistantText', extra: {'text': '改好了', 'state': 'complete'}),
      ]);
      expect(items.length, 2);
      expect(items[0], isA<UserItem>());
      final bar = items[1] as TurnBarItem;
      expect(bar.work.header?['activeMs'], 61_000);
      expect(workBarLabel(bar.work), '已工作 1 分 1 秒');
      expect(bar.work.visibleTextRow?['text'], '改好了');
    });

    test('运行中 turn：stateLabel=running（默认展开前提）', () {
      final items = buildChatItems([
        _row(1, 'turnHeader', extra: {'state': 'running', 'startedAt': 1000}),
        _row(2, 'userInput', extra: {'text': 'go'}),
        _row(3, 'reasoning', extra: {'text': '…', 'state': 'streaming'}),
      ]);
      final bar = items[1] as TurnBarItem;
      expect(bar.work.stateLabel, 'running');
      expect(bar.work.startedAtMs, 1000);
    });

    test('连续两轮：第二轮 header 到达才关第一轮（文件卡归属正确）', () {
      final items = buildChatItems([
        _row(1, 'turnHeader', extra: {'state': 'completedSuccess', 'activeMs': 61_000}),
        _row(2, 'userInput', extra: {'text': 'q1'}),
        _row(3, 'toolCall', extra: {'toolName': 'Read', 'status': 'success'}),
        _row(4, 'turnHeader', extra: {'state': 'completedSuccess', 'activeMs': 5_000}),
        _row(5, 'userInput', extra: {'text': 'q2'}),
        _row(6, 'toolCall', extra: {'toolName': 'Grep', 'status': 'success'}),
        _row(7, 'assistantText', extra: {'text': 'done', 'state': 'complete'}),
      ]);
      final bars = items.whereType<TurnBarItem>().toList();
      expect(bars.length, 2);
      expect(bars[0].work.activeMs, 61_000);
      expect(bars[1].work.activeMs, 5_000);
      // 第一轮的 bar 在 q1 之后、q2 之前（时间序不被下一轮 header 打乱）。
      UserItem? user2;
      for (final e in items) {
        if (e is UserItem && e.text == 'q2') user2 = e;
      }
      final idxUser2 = user2 == null ? -1 : items.indexOf(user2);
      final idxBar2 = items.indexOf(bars[1]);
      expect(idxBar2, greaterThan(idxUser2));
      expect(items.indexOf(bars[0]), lessThan(idxUser2));
    });
  });

  group('buildWorkUnits 纯投影', () {
    test('连续同族成组、单条不成组，组锚稳定取首行', () {
      final rows = [
        _row(1, 'toolCall', extra: {'toolName': 'Bash'}),
        _row(2, 'toolCall', extra: {'toolName': 'Bash'}),
        _row(3, 'toolCall', extra: {'toolName': 'Read'}),
      ];
      final units = buildWorkUnits(rows);
      expect(units, hasLength(2));
      final group = units[0] as GroupUnit;
      expect(group.family, GroupFamily.terminal);
      expect(group.rows, hasLength(2));
      expect(group.anchorRowId, 1);
      expect(units[1], isA<RowUnit>(), reason: '单个 Read 不伪造查阅组');
    });

    test('parentToolCallId 配对在 Agent 原位置出合并卡，后置行撤销', () {
      final tool = _row(1, 'toolCall', extra: {
        'toolName': 'Agent',
        'toolCallId': 'call-1',
      });
      final sub = _row(2, 'subagent', extra: {'parentToolCallId': 'call-1'});
      final units = buildWorkUnits(
        [tool, sub],
        pairedSubagentByToolRowId: {1: sub},
        claimedSubagentRowIds: {2},
      );
      expect(units, hasLength(1));
      final pair = units.single as SubagentPairUnit;
      expect(pair.toolRow, same(tool));
      expect(pair.subagentRow, same(sub));
    });

    test('guided 跨段共享轮级配对，-1 哨兵不参与', () {
      final items = buildChatItems([
        _row(1, 'turnHeader', extra: {'state': 'completedSuccess'}),
        _row(2, 'userInput', extra: {'text': 'q'}),
        _row(3, 'toolCall', extra: {
          'toolName': 'Agent',
          'toolCallId': 'call-guided',
        }),
        _row(4, 'userInput', extra: {'text': 'g', 'guided': true}),
        _row(5, 'subagent', extra: {'parentToolCallId': 'call-guided'}),
      ]);
      final works = items.whereType<TurnBarItem>().map((e) => e.work).toList();
      expect(works, hasLength(2));
      for (final work in works) {
        expect(work.pairedSubagentByToolRowId?[3]?['rowId'], 5);
        expect(work.claimedSubagentRowIds, contains(5));
      }

      final sentinel = buildChatItems([
        _row(6, 'turnHeader', extra: {'state': 'completedSuccess'}),
        _row(-1, 'toolCall', extra: {
          'toolName': 'Agent',
          'toolCallId': 'call-sentinel',
        }),
        _row(-1, 'subagent', extra: {'parentToolCallId': 'call-sentinel'}),
      ]).whereType<TurnBarItem>().single.work;
      expect(sentinel.pairedSubagentByToolRowId, isNull);
      expect(sentinel.claimedSubagentRowIds, isNull);
    });
  });
}
