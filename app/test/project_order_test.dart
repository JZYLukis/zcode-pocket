// 项目排序（2026-10-26 拍板③，官方 preferences.reorder 同语义=本地
// 偏好不同步）：纯函数序应用 + 排序弹层拖动保存 + chip 行尾显式入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _OrderApp extends AppState {
  List<String> order = const [];

  final List<Map<String, dynamic>> base = [
    {'id': 'p-1', 'name': '甲'},
    {'id': 'p-2', 'name': '乙'},
    {'id': 'p-3', 'name': '丙'},
    {'id': 'p-4', 'name': '新'},
    conversationsPseudoProject(),
  ];

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  List<Map<String, dynamic>> get sidebarProjects =>
      applyProjectOrder(base, order.isEmpty ? null : order);

  @override
  List<Map<String, dynamic>> get unclassifiedTasks => const [];

  @override
  List<Map<String, dynamic>> get workspaceTasks => [
        for (final p in base)
          if ('${p['id']}' != conversationsPseudoProjectId)
            {
              'taskId': 't-${p['id']}',
              'title': '任务${p['name']}',
              'projectId': p['id'],
              'workspacePath': 'D:/示例/${p['id']}',
              'updatedAt': 1800000000000,
              'displayStatus': 'idle',
            },
      ];

  @override
  List<Map<String, dynamic>> get projectTasks => workspaceTasks;

  List<String>? savedIds;

  @override
  Future<void> setProjectOrder(List<String> ids) async {
    savedIds = ids;
    order = ids;
    notifyListeners();
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const TaskCenterPage(),
      ),
    );

void main() {
  test('applyProjectOrder：命中按序/未记录追加/伪项目恒尾/null 原序', () {
    final entries = <Map<String, dynamic>>[
      {'id': 'p-1', 'name': '一'},
      {'id': 'p-2', 'name': '二'},
      {'id': 'p-3', 'name': '三'},
      {'id': 'p-new', 'name': '新'},
      conversationsPseudoProject(),
    ];
    final ordered = applyProjectOrder(entries, ['p-3', 'p-1']);
    expect(ordered.map((e) => e['id']),
        ['p-3', 'p-1', 'p-2', 'p-new', conversationsPseudoProjectId],
        reason: '命中前置按序；未记录按原序追加；「任务」恒尾');
    expect(applyProjectOrder(entries, null), same(entries),
        reason: 'null=原序不动');
    expect(applyProjectOrder(entries, []), same(entries));
  });

  testWidgets('主页更多菜单排序入口开弹层，拖动即存并即时生效', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _OrderApp();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    // B 方案：排序从「更多」进入，不再依赖横向 chip 行尾。
    expect(find.byKey(const ValueKey('project-order-entry')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目排序'));
    await tester.pumpAndSettle();
    expect(find.text('调整项目顺序'), findsOneWidget);

    // 拖第一项（甲项目）到第三位：按住手柄长按拖动。
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(app.savedIds, ['p-2', 'p-3', 'p-1', 'p-4'],
        reason: '拖完即存（伪项目不入序）');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目'));
    await tester.pump();
    double groupY(String id) =>
        tester.getTopLeft(find.byKey(ValueKey('home-group:project:$id'))).dy;
    expect(groupY('p-2') < groupY('p-3'), isTrue);
    expect(groupY('p-3') < groupY('p-1'), isTrue);
    expect(groupY('p-1') < groupY('p-4'), isTrue,
        reason: '项目组按新顺序即时重排');
  });
}
