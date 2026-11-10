import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart';

/// 回填律（2026-10-22 真机反馈C）：agent 提问（AskUserQuestion，payload
/// .questions）此前无渲染分支——手机只见问题文本不见选项。钉死：
/// ①questions 载荷渲染出选项行 ②选择+提交发出官方形状的
/// content（answers/answer_N/answer，值=option.value）③跳过=decline。

class _RecordingAppState extends AppState {
  final calls = <Map<String, dynamic>>[];
  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    calls.add({
      'interactionId': interactionId,
      'optionId': optionId,
      'action': action,
      'content': content,
    });
  }
}

ConversationState _stateWithQuestions() => ConversationState()
  ..snapshot = {
    'pendingInteractions': [
      {
        'interactionId': 'iq1',
        'payload': {
          'kind': 'userInput',
          'prompt': '选一个方案',
          'toolName': 'AskUserQuestion',
          'questions': [
            {
              'question': '用哪个库？',
              'header': '方案',
              'multiSelect': false,
              'options': [
                {'value': 'redis', 'label': 'Redis'},
                {'value': 'mem', 'label': '内存缓存'},
              ],
            },
            {
              'question': '要不要持久化？',
              'header': '行为',
              'multiSelect': true,
              'options': [
                {'value': 'yes', 'label': '要'},
                {'value': 'no', 'label': '不要'},
              ],
            },
          ],
        },
      },
    ],
  };

void main() {
  group('buildQuestionsResponseContent（官方 buildElicitationResponseContent 对位）', () {
    test('多题：answers+answer_N，未作答题不出现', () {
      final content = buildQuestionsResponseContent(
        [
          {
            'question': 'Q1',
            'options': [
              {'value': 'a', 'label': 'A'},
              {'value': 'b', 'label': 'B'},
            ],
          },
          {
            'question': 'Q2',
            'multiSelect': true,
            'options': [
              {'value': 'x', 'label': 'X'},
              {'value': 'y', 'label': 'Y'},
            ],
          },
        ],
        {
          0: {'b'},
          1: {'y', 'x'},
        },
      );
      expect(content['answers'], {'Q1': 'b', 'Q2': 'x, y'});
      expect(content['answer_0'], 'b');
      expect(content['answer_1'], ['x', 'y']);
      expect(content.containsKey('answer'), isFalse); // 多题无兼容单键
    });

    test('单题：answer 兼容键存在；空选择=空 answers', () {
      final content = buildQuestionsResponseContent(
        [
          {
            'question': 'Q',
            'options': [
              {'value': 'v1', 'label': 'L1'},
            ],
          },
        ],
        {
          0: {'v1'},
        },
      );
      expect(content['answer'], 'v1');
      expect(content['answer_0'], 'v1');
      expect(content['answers'], {'Q': 'v1'});

      final empty = buildQuestionsResponseContent(
        [
          {
            'question': 'Q',
            'options': [
              {'value': 'v1', 'label': 'L1'},
            ],
          },
        ],
        const {},
      );
      expect(empty['answers'], isEmpty);
      expect(empty.containsKey('answer_0'), isFalse);
    });
  });

  group('InteractionBanner questions 渲染与应答', () {
    testWidgets('一次一题：单选自动推进，末题多选提交；附言框不出现（2026-10-26 拍板）',
        (tester) async {
      final app = _RecordingAppState();
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: Scaffold(
              body: InteractionBanner(state: _stateWithQuestions(), sessionId: 's1'),
            ),
          ),
        ),
      );
      // 一次一题（官方 ElicitationDialog questionIndex 对位）：首题可见、
      // 第二题不可见（此前全部平铺）。
      expect(find.text('Redis'), findsOneWidget);
      expect(find.text('内存缓存'), findsOneWidget);
      expect(find.text('要'), findsNothing, reason: '第二题在首题答完前不可见');
      expect(find.text('1 / 2'), findsOneWidget, reason: '进度指示');
      // 附言输入不得出现在问题卡（2026-10-26 真机事故根因：第二提交
      // 入口不带答案提交→桌面校验拒绝）。
      expect(find.text('附言输入'), findsNothing);
      expect(find.textContaining('反馈（可选）'), findsNothing);

      Future<void> tapVisible(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f, warnIfMissed: false);
        await tester.pump();
      }

      // 单选首题：点 Redis → 自动进第二题。
      await tapVisible(find.text('Redis'));
      expect(find.text('Redis'), findsNothing, reason: '已推进到第二题');
      expect(find.text('要'), findsOneWidget);
      // 上一题可回看（官方控制列：头部 ‹ 图标）。
      await tapVisible(find.byKey(const ValueKey('question-prev')));
      expect(find.text('Redis'), findsOneWidget);
      await tapVisible(find.byKey(const ValueKey('question-next')));
      // 多选第二题：点 要+不要 后提交。
      await tapVisible(find.text('要'));
      await tapVisible(find.text('不要'));
      await tapVisible(find.textContaining('提交'));
      await tester.pump();
      expect(app.calls, hasLength(1));
      final call = app.calls.first;
      expect(call['interactionId'], 'iq1');
      expect(call['action'], 'accept');
      final content = call['content'] as Map<String, dynamic>;
      expect(content['answers'], {
        '用哪个库？': 'redis',
        '要不要持久化？': 'yes, no',
      });
      expect(content['answer_0'], 'redis');
      expect(content['answer_1'], ['yes', 'no']); // wire 选项序（确定性）
    });

    testWidgets('跳过=decline 无 content', (tester) async {
      final app = _RecordingAppState();
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: Scaffold(
              body: InteractionBanner(state: _stateWithQuestions(), sessionId: 's1'),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('跳过'));
      await tester.pump();
      await tester.tap(find.text('跳过'), warnIfMissed: false);
      await tester.pump();
      expect(app.calls, hasLength(1));
      expect(app.calls.first['action'], 'decline');
      expect(app.calls.first['content'], isNull);
    });

    // （三路同根）：作答判定只看
    // _qSelected 漏 _qCustom——官方 customAnswer 是合法作答，多选题仅填
    // 自定义时提交/翻页双锁死，唯一出路是跳过丢答案。修复后使能/计数/
    // 翻页统一按「选中或非空自定义」。
    testWidgets('多选仅自定义可提交：末题只填自定义答案不再死锁，载荷含 answer_N',
        (tester) async {
      final app = _RecordingAppState();
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: Scaffold(
              body: InteractionBanner(state: _stateWithQuestions(), sessionId: 's1'),
            ),
          ),
        ),
      );
      Future<void> tapVisible(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f, warnIfMissed: false);
        await tester.pump();
      }

      // 首题（单选）走自定义答案 → 自动进第二题（单选自定义顶替选项）。
      await tapVisible(find.byKey(const ValueKey('q-custom-open-0')));
      await tester.enterText(
          find.byKey(const ValueKey('q-custom-input-0')), 'LevelDB');
      await tapVisible(find.byKey(const ValueKey('q-custom-confirm-0')));
      expect(find.text('要'), findsOneWidget, reason: '单选自定义确认后自动推进');

      // 末题（多选）不勾任何选项、只填自定义 → 修复前提交钮恒禁用
      // （「选择后继续」），本断言红。
      await tapVisible(find.byKey(const ValueKey('q-custom-open-1')));
      await tester.enterText(
          find.byKey(const ValueKey('q-custom-input-1')), '视数据量定');
      await tapVisible(find.byKey(const ValueKey('q-custom-confirm-1')));
      expect(find.text('选择后继续'), findsNothing,
          reason: '修复前：多选仅自定义时提交钮死锁在禁用文案');
      expect(find.textContaining('提交（已选 2 题）'), findsOneWidget,
          reason: '计数含 custom-only 的题（修复前恒「已选 0 题」）');
      await tapVisible(find.textContaining('提交（已选 2 题）'));
      await tester.pump();
      expect(app.calls, hasLength(1));
      final content = app.calls.first['content'] as Map<String, dynamic>;
      expect(content['answers'], {
        '用哪个库？': 'LevelDB',
        '要不要持久化？': '视数据量定',
      });
      expect(content['answer_0'], 'LevelDB');
      expect(content['answer_1'], ['视数据量定'], reason: '多选题自定义=单元素数组');
    });

    testWidgets('单选自定义回看后正向导航不锁死；点选项清除自定义草稿（O2 P2-1）',
        (tester) async {
      final app = _RecordingAppState();
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: Scaffold(
              body: InteractionBanner(state: _stateWithQuestions(), sessionId: 's1'),
            ),
          ),
        ),
      );
      Future<void> tapVisible(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f, warnIfMissed: false);
        await tester.pump();
      }

      // 首题单选自定义 → 推进到第二题；‹ 回看第一题。
      await tapVisible(find.byKey(const ValueKey('q-custom-open-0')));
      await tester.enterText(
          find.byKey(const ValueKey('q-custom-input-0')), 'LevelDB');
      await tapVisible(find.byKey(const ValueKey('q-custom-confirm-0')));
      await tapVisible(find.byKey(const ValueKey('question-prev')));
      expect(find.text('Redis'), findsOneWidget);
      // 修复前：› 与主按钮都只看 _qSelected（自定义题为空集）→ 双双禁用，
      // 正向导航锁死。修复后自定义算已作答。
      final next = find.byKey(const ValueKey('question-next'));
      await tester.ensureVisible(next);
      await tester.pump();
      expect(tester.widget<IconButton>(next).onPressed, isNotNull,
          reason: '修复前：› 箭头对 custom-only 题禁用');
      expect(find.textContaining('下一题（已选 1 题）'), findsOneWidget,
          reason: '修复前：主按钮死锁在「选择后继续」');

      // 点选项=重置该题自定义草稿（官方 updateElicitationDraftsForOption
      // 单选分支 customAnswer:""）→ 提交载荷不再 answers 带 foo/answer_0
      // 不带的矛盾（修复前 answers['用哪个库？']='redis, LevelDB'）。
      await tapVisible(find.text('Redis'));
      expect(find.text('要'), findsOneWidget, reason: '单选选中即推进');
      await tapVisible(find.text('要'));
      await tapVisible(find.textContaining('提交'));
      await tester.pump();
      expect(app.calls, hasLength(1));
      final content = app.calls.first['content'] as Map<String, dynamic>;
      expect(content['answers'], {
        '用哪个库？': 'redis',
        '要不要持久化？': 'yes',
      });
      expect(content['answer_0'], 'redis');
      expect(content['answer_1'], ['yes']);
    });

    // 回填律（2026-10-22 真机反馈①）：AskUserQuestion 到达时会话常带
    // TodoWrite 计划——此前计划清单与问题互踩（标题变「执行计划？」、
    // 整份待办塞进提问卡）；且英文原样 prompt 不该示人。
    testWidgets('questions 优先于 plan：无计划清单、标题正确、英文 prompt 不渲染', (tester) async {
      final state = _stateWithQuestions()
        ..snapshot = {
          ...?_stateWithQuestions().snapshot,
          'plan': {
            'items': [
              {'content': '修复提问卡展示', 'status': 'completed'},
              {'content': '出包装机验收', 'status': 'pending'},
            ],
          },
        };
      // prompt 换成服务端真实英文原文，验证不透传。
      final interactions =
          state.snapshot!['pendingInteractions'] as List;
      (interactions.first as Map)['payload'] = {
        ...(interactions.first as Map)['payload'] as Map,
        'prompt': 'Tool AskUserQuestion requires user interaction',
      };
      await tester.pumpWidget(
        AppStateScope(
          app: _RecordingAppState(),
          child: MaterialApp(
            home: Scaffold(body: InteractionBanner(state: state, sessionId: 's1')),
          ),
        ),
      );
      expect(find.text('等待你的选择'), findsOneWidget);
      expect(find.text('执行计划？'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing); // 无计划条目行
      expect(find.textContaining('requires user interaction'), findsNothing);
      expect(find.text('Redis'), findsOneWidget); // 选项仍在
    });
  });
}
