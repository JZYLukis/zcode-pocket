import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/inline_diff_preview.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart';
import 'package:zcode_pocket/ui/turn_model.dart';
import 'package:zcode_pocket/transport/conversation.dart';

/// 会话富卡片优化批行为锁定：
/// - #5 工具行运行进度条：row.progress（官方 product-projection.ts
///   onToolCallProgress：fraction 0-1 / message≤200，终态由服务端清空）
///   此前手机端零消费——determinate/indeterminate 两档 + message 尾随；
/// - #10 审批富预览：permission payload.detail（官方 PermissionDialog
///   getPermissionRequestPreview 同源工具入参）按工具分流——命令类=
///   等宽代码块、编辑/写入类=InlineDiffPreview、其余维持纯文本明细行；
/// - #11 Plan Mode 计划卡：ExitPlanMode 不再按普通工具行渲染（摘要=
///   计划前 72 字符），出专用卡片+全文页；计划正文提取对位官方
///   planToolCall.ts（input/inputText/output 三路 plan/text/content）。

class _RowsApp extends AppState {
  _RowsApp(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': '富卡片',
          'control': {'phase': 'idle'},
          'usage': {
            'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page) => AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: page),
    );

Future<void> _pump(WidgetTester tester, [int rounds = 15]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _turnRows(List<Map<String, dynamic>> work) => [
      {'rowId': 1, 'kind': 'userInput', 'text': '开工'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'running',
        'createdAt': 1,
      },
      ...work,
    ];

/// 会话页另有多处 LinearProgressIndicator（上下文/额度/状态条）——本批
/// 进度条统一挂 ValueKey('tool-progress')，断言按键过滤。
List<LinearProgressIndicator> _progressBars(WidgetTester tester) => tester
    .widgetList<LinearProgressIndicator>(
      find.byKey(const ValueKey('tool-progress')),
    )
    .toList();

/// #10：附件读取计数桩（断言视频/PDF 不发起 attachmentRead）。
class _AttachCountApp extends _RowsApp {
  _AttachCountApp(super.rows);
  int readCalls = 0;

  @override
  Future<({List<int> bytes, String? mediaType})> attachmentRead(
    String sessionId,
    String ref, {
    Map<String, dynamic>? target,
    int? attachmentIndex,
  }) async {
    readCalls++;
    return (bytes: const <int>[], mediaType: null);
  }
}

/// 问题卡用例：应答直接成功（不落网络/不弹错误条）。
class _NoopResolveApp extends AppState {
  final resolved = <Map<String, dynamic>>[];
  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    resolved.add({
      'id': interactionId,
      'optionId': optionId,
      'action': action,
      'content': content,
    });
    return const {'status': 'accepted'};
  }
}

void main() {
  group('extractPlanToolCallContent（官方 planToolCall.ts 取值链）', () {
    test('input 的 plan 键优先，planFilePath 同源读出', () {
      final plan = extractPlanToolCallContent({
        'kind': 'toolCall',
        'input': {
          'plan': '# 计划 A',
          'text': '# 计划 B',
          'planFilePath': 'docs/plan.md',
        },
      });
      expect(plan?.markdown, '# 计划 A');
      expect(plan?.planFilePath, 'docs/plan.md');
    });

    test('input 缺席时 inputText JSON 解析；再退 output', () {
      final fromText = extractPlanToolCallContent({
        'inputText': '{"content":"# 来自 inputText"}',
      });
      expect(fromText?.markdown, '# 来自 inputText');

      final fromOutput = extractPlanToolCallContent({
        'output': {'text': '# 来自 output'},
      });
      expect(fromOutput?.markdown, '# 来自 output');
    });

    test('流式半截 JSON 与三路全空 → null（调用方回落通用工具行）', () {
      expect(extractPlanToolCallContent({'inputText': '{"plan": "# 半'}), isNull);
      expect(extractPlanToolCallContent({}), isNull);
    });
  });

  group('#5 工具行运行进度条', () {
    testWidgets('运行中 + fraction：determinate 进度条 + message 尾随',
        (tester) async {
      await tester.pumpWidget(_host(
        _RowsApp(_turnRows([
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'mcp__demo__scan',
            'status': 'running',
            'input': '{"query":"all"}',
            'progress': {'fraction': 0.5, 'message': '扫描中'},
          },
        ])),
        const ConversationPage(sessionId: 'p1', title: '进度条'),
      ));
      await _pump(tester);
      final bars = _progressBars(tester);
      expect(bars, hasLength(1), reason: 'determinate 进度条一条');
      expect(bars.single.value, 0.5, reason: '应消费协议 fraction');
      expect(find.text('扫描中'), findsOneWidget, reason: 'message 尾随');
    });

    testWidgets('运行中 + 仅 message（无 fraction）：indeterminate 细条',
        (tester) async {
      await tester.pumpWidget(_host(
        _RowsApp(_turnRows([
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'mcp__demo__scan',
            'status': 'running',
            'progress': {'message': '准备中'},
          },
        ])),
        const ConversationPage(sessionId: 'p2', title: '进度条'),
      ));
      await _pump(tester);
      final bars = _progressBars(tester);
      expect(bars, hasLength(1), reason: 'indeterminate 细条一条');
      expect(bars.single.value, isNull, reason: '无 fraction 走 indeterminate');
      expect(find.text('准备中'), findsOneWidget);
    });

    testWidgets('无 progress 字段与完成行：不出进度条（状态 quo 保持）',
        (tester) async {
      await tester.pumpWidget(_host(
        _RowsApp([
          {'rowId': 1, 'kind': 'userInput', 'text': '完工'},
          {
            'rowId': 2,
            'kind': 'turnHeader',
            'state': 'completedSuccess',
            'createdAt': 1,
          },
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'Bash',
            'status': 'success',
            'inputText': '{"command":"echo hi"}',
            // 终态残留 progress（服务端本会清空——防御双保险）
            'progress': {'fraction': 0.9},
          },
        ]),
        const ConversationPage(sessionId: 'p3', title: '进度条'),
      ));
      await _pump(tester);
      expect(_progressBars(tester), isEmpty,
          reason: '无 progress 字段/终态残留均不出进度条');
    });
  });

  group('#10 审批富预览', () {
    Widget bannerApp(Map<String, dynamic> payload) {
      // 官方 permission 形状（refs snapshot.ts:227-232）：options 在
      // payload 内、kind ∈ allowOnce|allowAlways|deny|custom、
      // toolCallId/summary 必填（旧夹具 options 挂 interaction 顶层）。
      final officialPayload = <String, dynamic>{
        'toolCallId': 'call-1',
        'summary': 's',
        ...payload,
        'options': const [
          {'optionId': 'a1', 'label': 'Allow once', 'kind': 'allowOnce'},
          {'optionId': 'a2', 'label': 'Always allow', 'kind': 'allowAlways'},
          {'optionId': 'd1', 'label': 'Deny', 'kind': 'deny'},
          {'optionId': 'c1', 'label': '自定义', 'kind': 'custom'},
        ],
      };
      final state = ConversationState()
        ..snapshot = {
          'pendingInteractions': [
            {
              'interactionId': 'i1',
              'payload': officialPayload,
            },
          ],
        };
      return _host(
        AppState()..loaded = true,
        Scaffold(body: InteractionBanner(state: state, sessionId: 's1')),
      );
    }

    testWidgets('命令类（Bash）：等宽命令块替代纯文本明细行', (tester) async {
      await tester.pumpWidget(bannerApp({
        'kind': 'permission',
        'toolName': 'Bash',
        'detail': {'command': 'rm -rf build/cache'},
      }));
      await _pump(tester);
      expect(find.text('rm -rf build/cache'), findsOneWidget,
          reason: '命令全文等宽块直显');
      expect(find.textContaining('命令：'), findsNothing,
          reason: '富预览已含全文，纯文本明细行不再叠放');
      // 等宽渲染（协议载荷原文，命令是代码不是文案）。
      final cmd = tester.widget<Text>(find.text('rm -rf build/cache'));
      expect(cmd.style?.fontFamily, 'monospace');
    });

    testWidgets('编辑类（Edit）：old/new 合成 InlineDiffPreview', (tester) async {
      await tester.pumpWidget(bannerApp({
        'kind': 'permission',
        'toolName': 'Edit',
        'detail': {
          'file_path': 'lib/main.dart',
          'old_string': 'final a = 1;',
          'new_string': 'final a = 2;',
        },
      }));
      await _pump(tester);
      expect(find.byType(InlineDiffPreview), findsOneWidget);
      expect(find.textContaining('final a = 2;'), findsOneWidget);
      expect(find.textContaining('final a = 1;'), findsOneWidget);
    });

    testWidgets('读取类：无富预览，维持 R5 纯文本明细行', (tester) async {
      await tester.pumpWidget(bannerApp({
        'kind': 'permission',
        'toolName': 'Read',
        'detail': {'file_path': 'README.md'},
      }));
      await _pump(tester);
      expect(find.byType(InlineDiffPreview), findsNothing);
      expect(find.textContaining('文件：README.md'), findsOneWidget);
    });
  });

  group('问题卡切题状态复位（#13③）', () {
    testWidgets('选中选项时该题自定义输入框收起并清空，返回该题不复现旧文本',
        (tester) async {
      final state = ConversationState()
        ..snapshot = {
          'pendingInteractions': [
            {
              'interactionId': 'q1',
              'payload': {
                'kind': 'userInput',
                'toolName': 'AskUserQuestion',
                'questions': [
                  {
                    'question': '第一题',
                    'multiSelect': false,
                    'options': [
                      {'value': 'a', 'label': '选项A'},
                      {'value': 'b', 'label': '选项B'},
                    ],
                  },
                  {
                    'question': '第二题',
                    'multiSelect': false,
                    'options': [
                      {'value': 'x', 'label': '选项X'},
                    ],
                  },
                ],
              },
            },
          ],
        };
      final app = _NoopResolveApp()..loaded = true;
      await tester.pumpWidget(_host(
        app,
        Scaffold(body: InteractionBanner(state: state, sessionId: 's1')),
      ));
      await _pump(tester);

      // 展开第一题的自定义输入并输入一段放弃的文本。
      await tester.tap(find.byKey(const ValueKey('早前批次')));
      await tester.pump();
      expect(find.byKey(const ValueKey('早前批次')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('早前批次')),
        '放弃的自定义',
      );
      await tester.pump();

      // 单选选中选项=放弃自定义：应复位展开态并清空控制器，随后进第二题。
      // （展开的自定义输入框会把选项行挤出可视区——先滚回再点。）
      await tester.ensureVisible(
          find.text('选项A', findRichText: true));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('选项A', findRichText: true));
      await _pump(tester);
      expect(find.byKey(const ValueKey('早前批次')), findsNothing,
          reason: '第二题的自定义默认收起');

      // 返回第一题：自定义输入框不得仍以旧文本展开（旧实现残留）。
      await tester.tap(find.byKey(const ValueKey('question-prev')));
      await _pump(tester);
      expect(find.byKey(const ValueKey('早前批次')), findsNothing,
          reason: '选中选项后该题自定义输入框应已收起');
      expect(find.byKey(const ValueKey('早前批次')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('早前批次')));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('早前批次')),
      );
      expect(field.controller!.text, isEmpty,
          reason: '旧自定义文本不得复活（控制器已清空）');
    });
  });

  group('附件预览与行操作门控（#10/#11）', () {
    testWidgets('视频/PDF 附件：前置提示且不发起读取（死代码修复）',
        (tester) async {
      final app = _AttachCountApp([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '看视频',
          'entityId': 'e1',
          'attachments': [
            {'fileName': 'demo.mp4', 'mime': 'video/mp4', 'ref': 'r1'},
          ],
        },
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '好'},
      ]);
      await tester.pumpWidget(_host(
        app,
        const ConversationPage(sessionId: 'a1', title: '附件'),
      ));
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('attachment-r1')));
      await _pump(tester, 6);
      expect(find.textContaining('视频/PDF 预览排在后续版本'), findsOneWidget,
          reason: '专用提示不再被 previewable 分支挡住');
      expect(app.readCalls, 0, reason: '视频/PDF 不发起整包 attachmentRead');
      expect(find.textContaining('附件读取失败'), findsNothing);
    });

    testWidgets('缺 entityId 的助手行禁用「重试这轮」（#11 门控）',
        (tester) async {
      final app = _RowsApp([
        {'rowId': 1, 'kind': 'userInput', 'text': '问'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '答'},
      ]);
      await tester.pumpWidget(_host(
        app,
        const ConversationPage(sessionId: 'a2', title: '行操作'),
      ));
      await _pump(tester);

      // 展开末轮后长按助手正文出行操作菜单。
      await tester.tap(find.text('已处理'));
      await _pump(tester, 6);
      await tester.longPress(find.text('答'), warnIfMissed: false);
      await _pump(tester, 6);
      expect(find.text('复制'), findsOneWidget, reason: '纯本地操作保留');
      expect(find.text('重试这轮'), findsNothing,
          reason: '缺 entityId 时协议 target 必被 strict 拒绝（对齐 canCommand）');
      // 编辑并重发对 userInput 行用同一 hasEntity 门控（缺 entityId 的旧
      // 快照行同样禁用）——该路径由 SelectionArea 长按菜单转交，行为与
      // 此处同条件，代码单源。
    });
  });

  group('#11 ExitPlanMode 计划卡', () {
    testWidgets('有计划正文：专用卡片+复制按钮+查看完整计划入口', (tester) async {
      await tester.pumpWidget(_host(
        _RowsApp(_turnRows([
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'ExitPlanMode',
            'status': 'success',
            'input': {
              'plan': '# 实施计划\n\n1. 改造协议层\n2. 补齐回归测试',
              'planFilePath': 'docs/upgrade.md',
            },
          },
        ])),
        const ConversationPage(sessionId: 'e1', title: '计划卡'),
      ));
      await _pump(tester);
      expect(find.text('计划'), findsOneWidget);
      expect(find.text('upgrade.md'), findsOneWidget, reason: '计划文件叶子名');
      expect(
        find.textContaining('改造协议层', findRichText: true),
        findsOneWidget,
        reason: 'markdown 正文渲染',
      );
      expect(find.byIcon(Icons.build_circle_outlined), findsNothing,
          reason: '不再按普通工具行渲染');
      expect(find.text('查看完整计划'), findsOneWidget);
    });

    testWidgets('「查看完整计划」推全文页；返回回到卡片', (tester) async {
      await tester.pumpWidget(_host(
        _RowsApp(_turnRows([
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'ExitPlanMode',
            'status': 'success',
            'input': {'plan': '# 完整计划正文'},
          },
        ])),
        const ConversationPage(sessionId: 'e2', title: '计划卡'),
      ));
      await _pump(tester);
      await tester.tap(find.text('查看完整计划'));
      await _pump(tester);
      expect(
        find.textContaining('完整计划正文', findRichText: true),
        findsWidgets,
        reason: '全文页包含计划 markdown',
      );
      await tester.pageBack();
      await _pump(tester);
      expect(find.text('查看完整计划'), findsOneWidget);
    });

    testWidgets('计划正文三路全空：回落通用工具行（官方兜底语义）',
        (tester) async {
      await tester.pumpWidget(_host(
        _RowsApp(_turnRows([
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'ExitPlanMode',
            'status': 'running',
          },
        ])),
        const ConversationPage(sessionId: 'e3', title: '计划卡'),
      ));
      await _pump(tester);
      expect(find.text('查看完整计划'), findsNothing);
      expect(find.byIcon(Icons.build_circle_outlined), findsOneWidget);
    });
  });
}
