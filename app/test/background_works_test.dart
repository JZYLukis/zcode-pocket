// 后台工作二级页（早前批次 反馈②）：后台工作撤出
// 输入区一级空间，入口=会话 ⋮ 任务菜单（带计数）→ 页面（列表+取消）。
// 红=旧实现无页面（输入区常驻面板占位）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/background_works_page.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

ConversationSeed _seed(List<Map<String, dynamic>> works) => ConversationSeed(
      rows: const [
        {'rowId': 1, 'kind': 'userInput', 'text': '跑构建', 'createdAt': 1700000000000},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess', 'createdAt': 1700000000500},
      ],
      logEpoch: 'e1',
      seq: 2,
      firstRowId: 1,
      totalCount: 2,
      snapshot: {
        'title': '后台工作会话',
        'control': const {'phase': 'idle'},
        'backgroundWorks': works,
      },
    );

Widget _host(ConversationState state, List<Map<String, dynamic>> calls) =>
    MaterialApp(
      theme: buildAppTheme(),
      home: BackgroundWorksPage(
        sessionId: 's1',
        state: state,
        onCancel: (sid, workId) async {
          calls.add({'sessionId': sid, 'workId': workId});
        },
      ),
    );

void main() {
  testWidgets('后台工作页：列表渲染+运行项取消（红=无页面）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = ConversationState()
      ..applySeed(_seed([
        {
          'workId': 'w-bash',
          'kind': 'bash',
          'title': '跑构建脚本',
          'status': 'running',
          'cancellable': true,
          'startedAt': 1700000000000,
          'anchorRowId': 1,
        },
        {
          'workId': 'w-sub',
          'kind': 'subagent',
          'title': '视觉走查',
          'status': 'resultPending',
          'startedAt': 1700000000100,
          'anchorRowId': 2,
        },
      ]));
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(state, calls));
    await tester.pump();
    expect(find.text('后台工作 · 2'), findsOneWidget, reason: '标题带计数');
    expect(find.text('跑构建脚本'), findsOneWidget);
    expect(find.text('已完成待投递'), findsOneWidget);
    // 仅 running+cancellable 可取消。
    expect(find.byKey(const ValueKey('background-work-cancel-w-bash')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('background-work-cancel-w-sub')),
        findsNothing);
    await tester
        .tap(find.byKey(const ValueKey('background-work-cancel-w-bash')));
    await tester.pump();
    expect(calls, [
      {'sessionId': 's1', 'workId': 'w-bash'}
    ]);
    // 状态驱动刷新：清空 works → 空态。
    state.applySeed(_seed(const []));
    state.notifyListeners();
    await tester.pump();
    expect(find.text('当前没有后台工作'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('体量：51 条整页滚动可达末项', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = ConversationState()
      ..applySeed(_seed([
        {
          'workId': 'w-run',
          'kind': 'workflow',
          'title': '正在跑的发布门',
          'status': 'running',
          'cancellable': true,
          'startedAt': 1700000000000,
          'anchorRowId': 1,
        },
        for (var i = 1; i <= 50; i++)
          {
            'workId': 'w-pending-$i',
            'kind': 'bash',
            'title': '历史批次任务 $i',
            'status': 'resultPending',
            'startedAt': 1700000000200 + i,
            'anchorRowId': 2,
          },
      ]));
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(state, calls));
    await tester.pump();
    expect(find.text('后台工作 · 51'), findsOneWidget);
    expect(find.text('历史批次任务 50').hitTestable(), findsNothing,
        reason: '51 行远超一屏，末项初始不在视口');
    await tester.scrollUntilVisible(
      find.text('历史批次任务 50'),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('background-works-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    expect(find.text('历史批次任务 50').hitTestable(), findsOneWidget,
        reason: '滚动可达末项');
    expect(tester.takeException(), isNull);
  });

  menuEntryTests();
}

// 菜单入口（唯一入口必须有测试钉住）：works 非空→⋮ 菜单出现带计数
// 项；空→不出现。
class _MenuSub implements ConversationSubscription {
  _MenuSub(this.sid, this.state);
  final String sid;
  @override
  final ConversationState state;
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-$sid';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sid';
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MenuApp extends AppState {
  _MenuApp(this.sub);
  final _MenuSub sub;
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  Future<ConversationSubscription> ensureConversation(String sessionId,
      {Object? seedCacheEntry}) async {
    return sub;
  }
}

Widget _menuHost(_MenuApp app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's1', title: '后台工作会话'),
      ),
    );

void menuEntryTests() {
  testWidgets('菜单入口：works 非空出现带计数项/空不出现', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final st = ConversationState()
      ..applySeed(_seed([
        {
          'workId': 'w-bash',
          'kind': 'bash',
          'title': '跑构建脚本',
          'status': 'running',
          'cancellable': true,
          'startedAt': 1700000000000,
          'anchorRowId': 1,
        },
      ]));
    final app = _MenuApp(_MenuSub('s1', st));
    await tester.pumpWidget(_menuHost(app));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 输入区不再有面板/托盘 bgworks 段（反馈②=零一级占位）。
    expect(find.byKey(const ValueKey('background-works-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('task-menu')));
    await tester.pumpAndSettle();
    expect(find.text('后台工作 · 1'), findsOneWidget, reason: '唯一入口');

    // 清空 → 菜单项消失。
    await tester.tapAt(const Offset(10, 10)); // 关菜单
    await tester.pumpAndSettle();
    st.applySeed(_seed(const []));
    st.notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('task-menu')));
    await tester.pumpAndSettle();
    expect(find.textContaining('后台工作 · '), findsNothing,
        reason: '菜单项消失（页面标题含「后台工作会话」不算）');
    expect(tester.takeException(), isNull);
  });
}
