// 看板数据页真旅程：ui-coverage 声称
// render 面已覆盖，实际此前零断言（账实不符）。本组覆盖四渲染器
//（chart 断点/table/metrics/board 含「其他」列）+ hasMore 自动排空 +
// 空态 + 错误态重试 + 翻页失败保留已渲染条目（页脚行内错误/停止）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/workflow_dashboards.dart';

/// 脚本化取数：(call 次数, afterSequence) → 页；抛错=失败分支。
class _DashApp extends AppState {
  _DashApp(this.pageBuilder);
  final Map<String, dynamic> Function(int call, int? afterSequence) pageBuilder;
  final calls = <int?>[];

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> workflowRunArtifactData(
    String sessionId,
    String runId,
    String artifactId, {
    int? afterSequence,
    int? limit,
  }) async {
    calls.add(afterSequence);
    return pageBuilder(calls.length, afterSequence);
  }
}

Map<String, dynamic> _item(int seq, Map<String, dynamic> value) => {
      'sequence': seq,
      'siteId': 'report#1',
      'ordinal': seq,
      'item': value,
    };

Widget _host(AppState app, Map<String, dynamic> artifact) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: WorkflowDashboardPage(
          sessionId: 's1',
          runId: 'run-1',
          artifact: artifact,
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, dynamic> _artifact(
  String kind,
  Map<String, dynamic> spec, {
  String id = 'a-1',
  String title = '看板',
}) =>
    {'id': id, 'kind': kind, 'title': title, 'spec': spec};

void main() {
  testWidgets('metrics：单页渲染指标瓦片（最后一条带值者）', (tester) async {
    final app = _DashApp(
      (call, after) => {
        'items': [
          _item(1, {'n': 10}),
          _item(2, {'n': 123}),
        ],
        'hasMore': false,
      },
    );
    await _pump(
      tester,
      _host(
        app,
        _artifact('metrics', {
          'metrics': [
            {'field': 'n', 'label': '总量'},
          ],
        }),
      ),
    );
    expect(find.text('总量'), findsOneWidget);
    expect(find.text('123'), findsOneWidget);
    expect(app.calls, [null], reason: '单页到顶只取一次');
    expect(tester.takeException(), isNull);
  });

  testWidgets('table：列头+单元格渲染（DataTable）', (tester) async {
    final app = _DashApp(
      (call, after) => {
        'items': [
          _item(1, {'k': 'alpha', 'v': '1'}),
        ],
        'hasMore': false,
      },
    );
    await _pump(
      tester,
      _host(
        app,
        _artifact('table', {
          'columns': ['k', 'v'],
        }),
      ),
    );
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chart：中段 null 断点不崩且图表在场', (tester) async {
    final app = _DashApp(
      (call, after) => {
        'items': [
          _item(1, {'t': 1, 'v': 1}),
          _item(2, {'t': 2, 'v': null}),
          _item(3, {'t': 3, 'v': 3}),
        ],
        'hasMore': false,
      },
    );
    await _pump(
      tester,
      _host(
        app,
        _artifact('chart', {
          'x': 't',
          'y': 'v',
        }),
      ),
    );
    expect(find.byKey(const ValueKey('dashboard-chart')), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: '断点分段绘制不得抛错（旧实现段列表恒空）');
  });

  testWidgets('board：status 缺失的卡落「其他」列（红=旧实现丢弃）',
      (tester) async {
    final app = _DashApp(
      (call, after) => {
        'items': [
          _item(1, {'id': 'c1', 'st': 'todo', 'title': '正常卡'}),
          _item(2, {'id': 'c2', 'title': '缺状态卡'}),
        ],
        'hasMore': false,
      },
    );
    await _pump(tester, _host(app,
        _artifact('board', {
          'key': 'id',
          'status': 'st',
          'columns': ['todo', 'done'],
          'cardTitle': 'title',
        })));
    expect(find.text('其他'), findsOneWidget,
        reason: '存在 status 缺失的卡就必须有「其他」列接住');
    expect(find.text('缺状态卡'), findsOneWidget,
        reason: '修复前 status 缺失的卡无处可落直接消失（红）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('hasMore 自动排空：指标取到末页最新值', (tester) async {
    final app = _DashApp(
      (call, after) => call == 1
          ? {
              'items': [_item(1, {'n': 10})],
              'hasMore': true,
            }
          : {
              'items': [_item(2, {'n': 20})],
              'hasMore': false,
            },
    );
    await _pump(
      tester,
      _host(
        app,
        _artifact('metrics', {
          'metrics': [
            {'field': 'n', 'label': '最新'},
          ],
        }),
      ),
    );
    expect(app.calls, [null, 1], reason: '续页游标=上一页末条 sequence');
    expect(find.text('20'), findsOneWidget,
        reason: '自动排空后指标=末页最后一条值（>200 条看板的正确性）');
    expect(find.byKey(const ValueKey('dashboard-load-more')), findsNothing,
        reason: '排空后不再显示加载更多');
  });

  testWidgets('空数据态：提示文案', (tester) async {
    final app = _DashApp((call, after) => {'items': [], 'hasMore': false});
    await _pump(
      tester,
      _host(
        app,
        _artifact('metrics', {
          'metrics': [
            {'field': 'n'},
          ],
        }),
      ),
    );
    expect(find.text('该看板还没有数据'), findsOneWidget);
  });

  testWidgets('首载错误态：整页错误+重试可恢复', (tester) async {
    var fail = true;
    final app = _DashApp((call, after) {
      if (fail) throw StateError('rpc down');
      return {
        'items': [_item(1, {'n': 7})],
        'hasMore': false,
      };
    });
    await _pump(
      tester,
      _host(
        app,
        _artifact('metrics', {
          'metrics': [
            {'field': 'n', 'label': '恢复'},
          ],
        }),
      ),
    );
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('7'), findsOneWidget, reason: '重试成功内容回来');
    expect(find.textContaining('加载失败'), findsNothing);
  });

  testWidgets('翻页中途失败：保留已渲染条目，页脚行内错误可重试/停止',
      (tester) async {
    var fail = true;
    final app = _DashApp((call, after) {
      if (call == 1) {
        return {
          'items': [_item(1, {'n': 10})],
          'hasMore': true,
        };
      }
      if (fail) throw StateError('page down');
      return {
        'items': [_item(2, {'n': 20})],
        'hasMore': false,
      };
    });
    await _pump(
      tester,
      _host(
        app,
        _artifact('metrics', {
          'metrics': [
            {'field': 'n', 'label': '总量'},
          ],
        }),
      ),
    );
    // 红：旧实现 catch 置 _error 顶掉首帧已渲染的整页内容。
    expect(find.text('10'), findsOneWidget,
        reason: '翻页失败必须保留已渲染内容（不得整页错误）');
    expect(find.textContaining('加载失败：'), findsNothing,
        reason: '不得出现整页错误页');
    expect(
      find.byKey(const ValueKey('dashboard-load-more-error')),
      findsOneWidget,
      reason: '页脚行内错误',
    );

    // 重试成功 → 续页数据追加。
    fail = false;
    await tester.tap(find.text('重试'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('20'), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-load-more-error')),
        findsNothing);
  });

  testWidgets('翻页失败后点「停止」：页脚整段收起（不再重试）', (tester) async {
    final app = _DashApp((call, after) {
      if (call == 1) {
        return {
          'items': [_item(1, {'n': 1})],
          'hasMore': true,
        };
      }
      throw StateError('still down');
    });
    await _pump(
      tester,
      _host(
        app,
        _artifact('metrics', {
          'metrics': [
            {'field': 'n', 'label': 'x'},
          ],
        }),
      ),
    );
    expect(find.byKey(const ValueKey('dashboard-load-more-stop')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dashboard-load-more-stop')));
    await tester.pump();
    expect(find.byKey(const ValueKey('dashboard-load-more-error')),
        findsNothing);
    expect(find.byKey(const ValueKey('dashboard-load-more')), findsNothing,
        reason: '停止=放弃续页，按钮一并收起');
  });

  // 视觉补跑必修（Visual A）：5 列形态 375dp 下
  // 右缘硬切、第 2 列起不可见且零提示。红=修复前无 Scrollbar、
  // columnSpacing=56/horizontalMargin=24（桌面默认）、单元格无封顶。
  testWidgets('视觉：表格横向溢出有滚动条+间距收窄+单元格封顶', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _DashApp(
      (call, after) => {
        'items': [
          for (var i = 1; i <= 3; i++)
            _item(i, {
              'k': 'row-$i',
              'a': '较长的路径风格单元格内容 $i（逼出横向溢出）',
              'b': '较长的路径风格单元格内容 $i 第二列',
              'c': '较长的路径风格单元格内容 $i 第三列',
              'd': '较长的路径风格单元格内容 $i 第四列',
            }),
        ],
        'hasMore': false,
      },
    );
    await _pump(
      tester,
      _host(
        app,
        _artifact('table', {
          'columns': ['k', 'a', 'b', 'c', 'd'],
          'key': 'k',
        }),
      ),
    );
    expect(find.byType(Scrollbar), findsOneWidget,
        reason: '红=修复前横向溢出零提示（Android 默认不显滚动条）');
    final dt =
        tester.widget<DataTable>(find.byKey(const ValueKey('dashboard-table')));
    expect(dt.columnSpacing, 14, reason: '红=桌面默认 56，一行内边距吃掉 160dp');
    expect(dt.horizontalMargin, 12, reason: '红=桌面默认 24');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-table')),
        matching: find.byType(ConstrainedBox),
      ),
      findsWidgets,
      reason: '单元格 224dp 封顶（官方 max-w truncate 对位）',
    );
    // A 复签终版：底部 Scrollbar thumb 落在全表末端（折叠线外）——
    // 视口内提示改由随滚动位置显隐的右缘渐隐承担（5 列溢出→在场）。
    expect(find.byKey(const ValueKey('dashboard-table-right-fade')),
        findsOneWidget,
        reason: '红=正视区零横向提示（thumb 在 1630dp 全表底部不可见）');
    expect(tester.takeException(), isNull);
  });

  // b 体量态：35 行 table 单页必须整页有界
  // 滚动可达末行——防「5 行夹具全绿、35 行真机溢出/不可达」类
  // （bgworks 51 条同型）。
  testWidgets('体量：35 行表格有界滚动可达末行', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _DashApp(
      (call, after) => {
        'items': [
          for (var i = 1; i <= 35; i++)
            _item(i, {'k': 'row-$i', 'v': '值 $i'}),
        ],
        'hasMore': false,
      },
    );
    await _pump(
      tester,
      _host(
        app,
        _artifact('table', {
          'columns': ['k', 'v'],
          'key': 'k',
        }),
      ),
    );
    expect(
        find.byKey(const ValueKey('workflow-dashboard-body')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '35 行无布局异常');
    // 非懒 ListView 全树构建——用 hitTestable 断「视口内可见」而非「存在」。
    expect(find.text('row-1').hitTestable(), findsOneWidget);
    expect(find.text('row-35').hitTestable(), findsNothing,
        reason: '35 行远超一屏，末行初始不在视口');
    await tester.scrollUntilVisible(
      find.text('row-35'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('workflow-dashboard-body')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('row-35').hitTestable(), findsOneWidget,
        reason: '滚动可达末行');
    expect(tester.takeException(), isNull);
  });
}
