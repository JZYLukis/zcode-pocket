// 任务移动归属（docs/move-task-plan.md，用户 2026-10-24 立项）回填：
// 项目选择 sheet（候选=同 host 可见项目、当前归属标记、伪项目排除）、
// 点选→moveTask 调用形状、root-confirmation-required 二段确认
// （addMissingRoot 重发）、任务行缺失的降级提示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _MoveApp extends AppState {
  /// moveTask 桩：记录调用；(projectId, addMissingRoot) 列表；首次调用
  /// 可注入错误（模拟 root-confirmation-required）。
  final calls = <(String, bool)>[];
  Object? throwOnce;

  @override
  List<Map<String, dynamic>> get sidebarProjects => const [
        {'id': 'p1', 'name': '项目甲', 'hostId': 'local'},
        {'id': 'p2', 'name': '项目乙'},
        {'id': '__conversations__', 'name': '任务'},
        {'id': 'p-remote', 'name': '远程项目', 'hostId': 'host-b'},
      ];

  @override
  List<Map<String, dynamic>> get projectTasks => const [
        {
          'taskId': 't1',
          'title': '测试任务',
          'projectId': null,
          'workspacePath': r'G:\Demo App',
          'hostId': 'local',
        },
      ];

  @override
  Future<void> moveTask(
    Map<String, dynamic> task,
    String projectId, {
    bool addMissingRoot = false,
  }) async {
    final err = throwOnce;
    throwOnce = null;
    if (err != null) throw err;
    calls.add((projectId, addMissingRoot));
  }
}

TaskCardData _card() => TaskCardData(
      sessionId: 't1',
      title: '测试任务',
      phase: 'idle',
      preview: null,
      lastActivityAt: 0,
      createdAt: 0,
      pinned: false,
      hasBackgroundWork: false,
      goalStatus: null,
      unread: false,
      pendingInteraction: null,
      historical: false,
    );

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        // Scaffold 必需：SnackBar 由 Scaffold 呈现（无 Scaffold 时不显示）。
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showMoveToProjectSheet(ctx, _card()),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );




void main() {
  testWidgets('项目选择：同 host 候选+伪项目排除+未归属无当前标记',
      (tester) async {
    await tester.pumpWidget(_host(_MoveApp()));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('项目甲'), findsOneWidget);
    expect(find.text('项目乙'), findsOneWidget);
    expect(find.text('任务'), findsNothing, reason: '「任务」伪项目不可为目标');
    expect(find.text('远程项目'), findsNothing,
        reason: '官方跨 host 拒绝——hostId=host-b 不出现在 local 任务候选');
    expect(find.text('当前'), findsNothing, reason: '未归属任务无当前项目');
  });

  testWidgets('点选项目 → moveTask 携带目标 projectId', (tester) async {
    final app = _MoveApp();
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目乙'));
    // 固定推进（不 pumpAndSettle——会把 SnackBar 3s 寿命推完消失）。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.calls, [('p2', false)]);
    expect(find.textContaining('已移动到 项目乙'), findsOneWidget);
  });

  testWidgets('root-confirmation-required：二段确认后 addMissingRoot 重发',
      (tester) async {
    final app = _MoveApp()
      ..throwOnce = Exception(
          'project.root-confirmation-required: dir not in roots');
    await tester.pumpWidget(_host(app));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目甲'));
    await tester.pumpAndSettle();
    // 官方 ProjectSidebarNode.tsx:157-172 同款确认弹窗。
    expect(find.textContaining('加入目录并移动'), findsOneWidget);
    await tester.tap(find.text('加入并移动'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.calls, [('p1', true)],
        reason: '确认后带 addMissingRoot=true 重发');
    expect(find.textContaining('已移动到 项目甲'), findsOneWidget);
  });

  testWidgets('readTree 行缺失（数据未就绪）：提示不弹层', (tester) async {
    final app = _MoveApp();
    await tester.pumpWidget(
      AppStateScope(
        app: _MissApp(app),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showMoveToProjectSheet(ctx, _card()),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.textContaining('归属数据未就绪'), findsOneWidget);
    expect(find.text('项目甲'), findsNothing);
  });

}

/// projectTasks 返回空（模拟 readTree 未就绪）的包装。
class _MissApp extends AppState {
  _MissApp(this._inner);
  final _MoveApp _inner;
  @override
  List<Map<String, dynamic>> get projectTasks => const [];
  @override
  List<Map<String, dynamic>> get sidebarProjects => _inner.sidebarProjects;
}
