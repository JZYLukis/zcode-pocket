import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

/// 新建对话 · 工作区选择层（2026-10-22 用户诉求：无项目对话路径太绕）。
/// 官方 mobile-task-home-design.md「workspace 级新建任务入口」对位：
/// 新建=悬浮按钮+工作区选择弹层（当前工作区/各项目/无项目对话）；
/// 无项目对话借最新未归类任务切默认会话区，一个都没有时置灰。

class _FakeConversation implements ConversationTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeAppState extends AppState {
  @override
  bool get loaded => true;

  @override
  ConversationTransport get conversation => _FakeConversation();

  @override
  String? get activeProjectId => 'p1';

  @override
  List<Map<String, dynamic>> get sidebarProjects => const [
        {'id': 'p1', 'name': '项目甲'},
        {'id': 'p2', 'name': '项目乙'},
        {'id': '__conversations__', 'name': '任务'},
      ];

  @override
  List<Map<String, dynamic>> get unclassifiedTasks => const [
        {
          'taskId': 't9',
          'title': '旧的无项目会话',
          'workspacePath': r'G:\demo\workspace\default',
        },
      ];

  @override
  Map<String, dynamic>? get activeWorkspace => {
        'workspacePath': r'G:\proj-a',
        'label': '项目甲',
        'kind': 'local',
      };
}

void main() {
  testWidgets('选择层：当前工作区/项目（排除任务伪区）/无项目对话可用', (tester) async {
    await tester.pumpWidget(
      AppStateScope(
        app: _FakeAppState(),
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showNewTaskSheet(ctx),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('当前工作区'), findsOneWidget);
    expect(find.text('项目甲'), findsOneWidget,
        reason: 'B 配套去重：当前项目只在「当前工作区」副标题出现一次');
    expect(find.text('项目乙'), findsOneWidget);
    expect(find.text('任务'), findsNothing); // 伪区不进选择层
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '无项目对话'),
    );
    expect(tile.enabled, isTrue); // 有未归类任务 → 可借道
  });

  testWidgets('无未归类任务时「无项目对话」置灰并提示去电脑端建', (tester) async {
    final app = _FakeAppState();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showNewTaskSheet(ctx),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    // 覆写为空（pumpWidget 后直接换实例更简单：重建）
    final empty = _EmptyUnclassified();
    await tester.pumpWidget(
      AppStateScope(
        app: empty,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showNewTaskSheet(ctx),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '无项目对话'),
    );
    expect(tile.enabled, isFalse);
    expect(find.textContaining('需先在电脑端'), findsOneWidget);
  });

  testWidgets('选「当前工作区」直接进草稿会话页', (tester) async {
    await tester.pumpWidget(
      AppStateScope(
        app: _FakeAppState(),
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showNewTaskSheet(ctx),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前工作区'));
    await tester.pumpAndSettle();
    expect(find.text('新建对话'), findsNothing); // sheet 已关
    expect(find.text('新会话'), findsWidgets); // 草稿页标题
  });
}

class _EmptyUnclassified extends _FakeAppState {
  @override
  List<Map<String, dynamic>> get unclassifiedTasks => const [];
}
