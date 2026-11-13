// 2026-10-23 用户反馈批（回填律）：「桌面短对话末尾有复制/赞/踩/分支
// 按钮可以考虑加上」——桌面 ConversationRowView.tsx:1580-1649 轮尾
// action bar 对位。本文件锁：轮尾四钮（仅完成态轮尾）、反馈乐观切换、
// 缺 entityId 协议钮禁用、分支 ack 打开子会话。
// 2026-10-24 对抗审查回填：fork 桩改真实信封形状（ack.result.sessionId
// ——此前扁平桩形状与 wire 不符把 bug 盖住）；rejected 回滚；
// 中断轮不出操作行；guided 一轮多段只挂末段；复制=整轮
// 正文合并。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _TailApp extends AppState {
  _TailApp(this.rows, {this.fbStatus = 'accepted'});
  final List<Map<String, dynamic>> rows;

  /// 反馈 ack 状态注入（rejected 用例）。
  final String fbStatus;
  final calls = <String>[];

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
          'title': '轮尾操作',
          'control': {'phase': 'idle'},
          'usage': {
            'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );

  @override
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) async {
    calls.add('fb:$feedback');
    return {'status': fbStatus};
  }

  @override
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) async {
    calls.add('fork');
    // 真实 wire 形状（command.ts:392-401/450-463）：sessionId 嵌套在
    // ack.result 下，顶层只有 commandId/status/result 等字段。
    return {
      'status': 'accepted',
      'result': {'type': 'forkAssistant', 'sessionId': 'fork-9'},
    };
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: const _Home()),
    );

/// 简单壳：测试里直接 push ConversationPage 便于断言导航叠加。
class _Home extends StatelessWidget {
  const _Home();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(
                  builder: (_) => const ConversationPage(
                    sessionId: 's1',
                    title: '轮尾操作',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _rows({
  bool entityId = true,
  String turnState = 'completedSuccess',
  String textState = 'success',
}) => [
      {'rowId': 1, 'kind': 'userInput', 'text': '总结'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': turnState},
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': textState,
        'text': '答案正文',
        if (entityId) 'entityId': 'e3',
      },
    ];

void main() {
  testWidgets('完成态轮尾：四钮齐全（复制/赞/踩/分支）', (tester) async {
    final app = _TailApp(_rows());
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    // 完成轮默认收起——外置正文+轮尾行可见。
    expect(find.text('答案正文'), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down_outlined), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
  });

  testWidgets('点赞：乐观切换+命令带 like，再点取消回 null', (tester) async {
    final app = _TailApp(_rows());
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await _pump(tester);
    expect(app.calls, ['fb:like']);
    // 乐观：实心+品牌色（图标换 thumb_up）。
    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    await tester.tap(find.byIcon(Icons.thumb_up));
    await _pump(tester);
    expect(app.calls, ['fb:like', 'fb:null']);
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
  });

  testWidgets('反馈被拒（ack status=rejected）：回滚+提示，不当成功', (tester) async {
    final app = _TailApp(_rows(), fbStatus: 'rejected');
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await _pump(tester);
    // 官方 SessionPane.tsx:4084-4094 同款：rejected 必须回滚本地乐观值。
    expect(find.byIcon(Icons.thumb_up), findsNothing,
        reason: '被拒后乐观态回滚');
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    expect(find.textContaining('反馈未生效'), findsOneWidget);
  });

  testWidgets('缺 entityId：赞/踩/分支禁用，复制仍可用', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    final app = _TailApp(_rows(entityId: false));
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    IconButton iconBtn(IconData i) => tester.widget<IconButton>(
          find
              .ancestor(of: find.byIcon(i), matching: find.byType(IconButton))
              .first,
        );
    expect(iconBtn(Icons.thumb_up_outlined).onPressed, isNull,
        reason: '缺 entityId 协议钮禁用（H1 纪律）');
    expect(iconBtn(Icons.account_tree_outlined).onPressed, isNull);
    await tester.tap(find.byIcon(Icons.copy_outlined), warnIfMissed: false);
    await tester.pump();
    expect(copied, '答案正文');
  });

  testWidgets('运行中/流式：不出轮尾行', (tester) async {
    final app = _TailApp(
      _rows(turnState: 'running', textState: 'streaming'),
    );
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    expect(find.byIcon(Icons.account_tree_outlined), findsNothing,
        reason: '官方仅完成态轮尾渲染 action bar');
    expect(find.byIcon(Icons.copy_outlined), findsNothing);
  });

  testWidgets('中断轮：不出轮尾行（官方只认 complete）', (tester) async {
    final app = _TailApp(_rows(turnState: 'completedInterrupted'));
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    expect(find.text('答案正文'), findsOneWidget, reason: '正文仍可见');
    expect(find.byIcon(Icons.account_tree_outlined), findsNothing,
        reason: '中断轮的反馈/分支大概率被服务端 guard 拒（审查 B3）');
  });

  testWidgets('分支：ack.result 带子会话 id → 打开分支会话页', (tester) async {
    final app = _TailApp(_rows());
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    await tester.tap(find.byIcon(Icons.account_tree_outlined));
    await _pump(tester);
    expect(app.calls, ['fork']);
    // 原页面被新路由盖住后默认 finder 会跳过（skipOffstage）——连
    // 盖住的算上应有两页。
    expect(find.byType(ConversationPage, skipOffstage: false),
        findsNWidgets(2),
        reason: 'forkAssistant ack.result.sessionId=分支子会话，直接打开');
  });

  testWidgets('guided 追问一轮两段：只挂一条轮尾行（末段）', (tester) async {
    final app = _TailApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '开始'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'success',
        'text': '第一段答案',
        'entityId': 'e3',
      },
      {'rowId': 4, 'kind': 'userInput', 'guided': true, 'text': '继续'},
      {
        'rowId': 5,
        'kind': 'assistantText',
        'state': 'success',
        'text': '第二段答案',
        'entityId': 'e5',
      },
    ]);
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget,
        reason: '官方一轮只有一条 action bar（审查 B2：guided 每段都挂'
            '=一轮 N 条四钮行）');
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
  });

  testWidgets('轮尾复制=整轮正文合并（官方 join 换行规范）', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    final app = _TailApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '开始'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'success',
        'text': '第一段答案',
        'entityId': 'e3',
      },
      {'rowId': 4, 'kind': 'userInput', 'guided': true, 'text': '继续'},
      {
        'rowId': 5,
        'kind': 'assistantText',
        'state': 'success',
        'text': '第二段答案',
        'entityId': 'e5',
      },
    ]);
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    await tester.tap(find.byIcon(Icons.copy_outlined), warnIfMissed: false);
    await tester.pump();
    expect(copied, '第一段答案\n\n第二段答案',
        reason: '官方 ConversationTurnGroup.tsx:1336：整轮全部 text 段 '
            'join("\\n\\n")——此前只复制末段（审查 B1）');
  });

  testWidgets('正文→文件卡间距定稿值锁定（用户六轮拍板 2026-10-24）', (tester) async {
    // 间距堆栈定稿：外置正文底边距 0+卡外距 0+卡头贴正文侧 4——
    // 总空隙 5dp（第四补位纪律：拍板值布局断言锁死防漂移）。
    final app = _TailApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '改文件'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'entityId': 'e2',
        'fileChanges': {'files': 1, 'additions': 3, 'deletions': 1},
      },
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'success',
        'text': '改完了',
        'entityId': 'e3',
      },
    ]);
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('open'));
    await _pump(tester);
    expect(find.byKey(const ValueKey('早前批次')), findsOneWidget);
    // 卡外距=0。
    final card = tester.widget<Container>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('早前批次')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(card.margin, EdgeInsets.zero,
        reason: '间距定稿：卡外距归零（空隙由卡内距表达）');
    // 卡头内距 top=4（贴正文侧收窄档）——锚定卡标题文字（key 在
    // InkWell 上，其 child Padding 不在祖先链）。
    final paddings = tester
        .widgetList<Padding>(
          find.ancestor(
            of: find.textContaining('个文件已更改'),
            matching: find.byType(Padding),
          ),
        )
        .map((p) => p.padding)
        .toSet();
    expect(paddings.contains(const EdgeInsets.fromLTRB(12, 4, 12, 6)), isTrue,
        reason: '间距定稿：卡头 fromLTRB(12,4,12,6)');
    // 外置正文底边距清零（vertical:0 的 Padding 存在于正文链上）。
    expect(
      tester
          .widgetList<Padding>(find.byType(Padding))
          .any((p) => p.padding == const EdgeInsets.symmetric(vertical: 0)),
      isTrue,
      reason: '间距定稿：外置正文自身底边距清零（空隙不再叠加）');
  });
}
