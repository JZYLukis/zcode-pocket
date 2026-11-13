// 机会项#1（2026-11-08 拍板）：新建项目——workspace-create 直发
// （名字校验→创建→切换进新项目）。红=旧代码无此入口（手机完全不能
// 新建本地项目）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _CreateApp extends AppState {
  _CreateApp({this.createDelay = Duration.zero});

  /// 慢创建夹具（进度/取消用例）：真实 host RPC 最长 45s。
  final Duration createDelay;
  List<String> createCalls = [];
  Map<String, dynamic>? switchedProject;

  @override
  bool get loaded => true;
  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  List<Map<String, dynamic>> get sidebarProjects => const [
        {'id': 'p1', 'name': '示例项目A'},
      ];

  @override
  Future<Map<String, dynamic>> createWorkspace(String name) async {
    createCalls.add(name);
    if (createDelay != Duration.zero) {
      await Future<void>.delayed(createDelay);
    }
    return {
      'success': true,
      'workspacePath': 'D:/ZCodeProjects/$name',
      'workspaceKey': 'D:/ZCodeProjects/$name',
      'projectId': 'np-1',
    };
  }

  @override
  Future<void> switchToProject(Map project,
      {bool keepHomePreview = false}) async {
    switchedProject = project.cast<String, dynamic>();
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: const TaskCenterPage()),
    );

void main() {
  testWidgets('新建项目：选择器行→名字对话框→键盘校验→创建+切换+进新会话', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _CreateApp();
    await tester.pumpWidget(_host(app));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 打开新建选择器。
    await tester.tap(find.byKey(const ValueKey('new-session')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 红点：新建项目行在场。
    expect(find.byKey(const ValueKey('new-project-row')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-project-row')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('new-project-name')), findsOneWidget);

    // 键盘提交空名（红点：旧 onSubmitted 绕过校验直接 pop 空名，服务端
    // 必拒且对话框消失）。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('名字不能为空'), findsOneWidget);
    expect(app.createCalls, isEmpty, reason: '空名不得发起 workspace-create');

    // 分隔符校验（同键盘提交路径）。
    await tester.enterText(
        find.byKey(const ValueKey('new-project-name')), 'a/b');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.textContaining('名字不能包含'), findsOneWidget);
    expect(app.createCalls, isEmpty, reason: '含 / 的名字不得发起创建');

    // 合法名（键盘提交覆盖 onSubmitted 成功路径）。
    await tester.enterText(
        find.byKey(const ValueKey('new-project-name')), '新实验项目');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.createCalls, ['新实验项目'], reason: 'workspace-create 直发');
    // 切换载荷形状：projectId/name/roots[].rootPath+isPrimary（roots 字符串
    // 数组是旧实现自造形状，project intent 解析拿不到根目录）。
    final switched = app.switchedProject;
    expect(switched, isNotNull, reason: '创建成功后切换进新项目');
    expect(switched!['id'], 'np-1');
    expect(switched['name'], '新实验项目');
    final roots = switched['roots'] as List;
    expect(roots, hasLength(1));
    expect((roots.first as Map)['rootPath'], 'D:/ZCodeProjects/新实验项目');
    expect((roots.first as Map)['isPrimary'], true);
    // 成功后直接进入新会话草稿（注释语义：切换进新项目继续新建对话）。
    expect(find.byType(ConversationPage), findsOneWidget,
        reason: '切换完成后进入新会话');
    expect(tester.takeException(), isNull);
  });

  // 对抗审查中⑧①：创建等待（host RPC 最长 45s）必须有可取消进度 UI；
  // 取消=放弃等待但创建可能已提交——文案明说结果未知。红=旧实现
  // 零反馈不可中断。
  testWidgets('创建等待：进度对话框可取消（结果未知文案）+取消后不切换', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _CreateApp(createDelay: const Duration(seconds: 2));
    await tester.pumpWidget(_host(app));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('new-session')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('new-project-row')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(
        find.byKey(const ValueKey('new-project-name')), '慢项目');
    await tester.tap(find.byKey(const ValueKey('new-project-confirm')));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.textContaining('正在创建项目 慢项目'), findsOneWidget,
        reason: '创建等待期必须有可见进度');
    expect(find.byKey(const ValueKey('new-project-progress-cancel')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-project-progress-cancel')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('已提交创建，结果未知'), findsOneWidget,
        reason: '取消≠撤销创建：文案必须说明结果未知');
    expect(app.switchedProject, isNull, reason: '取消后不得擅自切换进新项目');

    // 创建在后台完成：仍不切换、不进入新会话。
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.createCalls, ['慢项目']);
    expect(app.switchedProject, isNull);
    expect(find.byType(ConversationPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
