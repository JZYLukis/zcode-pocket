// A 批（2026-11-08 拍板⑥⑧）红绿：看板 spec 宽松解析+字段取数+四渲染器
// 数据准备（官方 presets/spec.ts 对位）+会话内 run 卡+任务行 run 线。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/workflow_dashboards.dart';
import 'package:zcode_pocket/ui/workflow_runs_page.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';

void main() {
  group('视觉补跑必修（早前批次，Visual A）', () {
    test('图表刻度标签：4 档网格线对位+顶格带单位', () {
      expect(chartTickLabels(0, 300, 'ms'), ['300ms', '200', '100', '0'],
          reason: '顶格=maxY 带单位，其余裸值（红=修复前图表零刻度零信息量）');
      expect(chartTickLabels(0, 9, ''), ['9', '6', '3', '0']);
      expect(chartTickLabels(5, 5, 'x'), ['6x', '5.7', '5.3', '5'],
          reason: 'maxY==minY 时撑开一格避免除零（5..6 线性四等分）');
    });
    test('紧凑数值格式：k 记法/一位小数/取整', () {
      expect(fmtChartNum(1234), '1.2k');
      expect(fmtChartNum(2000), '2k');
      expect(fmtChartNum(0.5), '0.5');
      expect(fmtChartNum(42), '42');
      expect(fmtChartNum(-3.25), '-3.3');
    });
  });

  group('readArtifactField（官方 readWorkflowArtifactField 对位）', () {
    final item = <String, dynamic>{
      'timing': {'after': 12.5},
      'rounds': [
        {'ms': 100},
        {'ms': 200},
      ],
      'name': 'r1',
    };
    test('对象键/嵌套/数组下标/字符串', () {
      expect(readArtifactField(item, 'timing.after'), 12.5);
      expect(readArtifactField(item, 'rounds.0.ms'), 100);
      expect(readArtifactField(item, 'rounds.1.ms'), 200);
      expect(readArtifactField(item, 'name'), 'r1');
    });
    test('走不通=-null（缺键/越界/标量穿透/null item）', () {
      expect(readArtifactField(item, 'timing.nope'), isNull);
      expect(readArtifactField(item, 'rounds.5.ms'), isNull);
      expect(readArtifactField(item, 'name.x'), isNull);
      expect(readArtifactField(null, 'a'), isNull);
      expect(readArtifactField(item, 'rounds.-1'), isNull);
    });
  });

  group('parseDashboardSpec 宽松解析', () {
    test('chart：必填 x+y；type/scale 缺省；y 单字段或列表', () {
      final spec = parseDashboardSpec(
          'chart', {'x': 't', 'y': {'field': 'v', 'unit': 'ms'}, 'type': 'bar'});
      expect(spec, isNotNull);
      expect(spec!.chartType, 'bar');
      expect(spec.x!.field, 't');
      expect(spec.ys.single.unit, 'ms');
      expect(parseDashboardSpec('chart', {'y': 'v'}), isNull,
          reason: '缺 x=不可渲染');
    });
    test('table/metrics/board 必填与缺省', () {
      expect(parseDashboardSpec('table', {'columns': ['a', 'b']}), isNotNull);
      expect(parseDashboardSpec('table', {'columns': []}), isNull);
      expect(
          parseDashboardSpec('metrics', {
            'metrics': [
              {'field': 'm', 'label': '指标'}
            ]
          }),
          isNotNull);
      final board = parseDashboardSpec('board', {
        'key': 'id',
        'status': 'st',
        'columns': ['todo', 'done'],
      });
      expect(board, isNotNull);
      expect(board!.boardColumns, ['todo', 'done']);
      expect(parseDashboardSpec('board', {'key': 'id'}), isNull,
          reason: '缺 status');
      expect(parseDashboardSpec('chart', 'not-a-map'), isNull);
    });
  });

  group('渲染数据准备', () {
    test('F2：声明 key 但条目缺值——siteId@ordinal 身份不塌缩（红=旧互撞）',
        () {
      final spec = parseDashboardSpec('table', {
        'columns': ['k', 'v'],
        'key': 'k',
      })!;
      // 协议每条必带 siteId/ordinal（workflow-artifacts.ts:238-247）。
      final rows = buildTableRows(spec, [
        const ArtifactDataItem(1, {'k': 'a', 'v': '1'}, siteId: 's1'),
        const ArtifactDataItem(2, {'v': '2'}, siteId: 'report#1', ordinal: 2),
        const ArtifactDataItem(3, {'v': '3'}, siteId: 'report#1', ordinal: 3),
      ]);
      // 官方：3 行（缺 key 用 siteId@ordinal 身份逐条追加）。
      expect(rows, hasLength(3), reason: '缺 key 行不得互相覆盖丢数据');
      expect(rows[0], ['a', '1']);
    });

    test('F2：数字 key 原样格式化（1.234 与 1.23 是两行，不合并）', () {
      final spec = parseDashboardSpec('table', {
        'columns': ['k', 'v'],
        'key': 'k',
      })!;
      final rows = buildTableRows(spec, [
        const ArtifactDataItem(1, {'k': 1.234, 'v': 'a'}),
        const ArtifactDataItem(2, {'k': 1.23, 'v': 'b'}),
      ]);
      expect(rows, hasLength(2), reason: 'toFixed(2) 会把两个 key 错误合并');
    });

    test('table key 替换语义（同 key 后到覆盖）', () {
      final spec = parseDashboardSpec('table', {
        'columns': ['k', 'v'],
        'key': 'k',
      })!;
      final rows = buildTableRows(spec, [
        const ArtifactDataItem(1, {'k': 'a', 'v': '1'}),
        const ArtifactDataItem(2, {'k': 'b', 'v': '2'}),
        const ArtifactDataItem(3, {'k': 'a', 'v': '3'}),
      ]);
      expect(rows, [
        ['a', '3'],
        ['b', '2'],
      ], reason: 'a 行被后到条目替换，顺序保持');
    });
    test('metrics=最后一条带该字段的值', () {
      final spec = parseDashboardSpec('metrics', {
        'metrics': [
          {'field': 'n', 'unit': '次'}
        ]
      })!;
      final tiles = buildMetricTiles(spec, [
        const ArtifactDataItem(1, {'n': 3}),
        const ArtifactDataItem(2, {'x': 1}),
        const ArtifactDataItem(3, {'n': 7}),
      ]);
      expect(tiles.single, ('n', '7 次'));
    });

    test('数值格式化：全精度原样输出（官方 String(value) 对位）', () {
      final tiles = buildMetricTiles(
        parseDashboardSpec('metrics', {
          'metrics': [
            {'field': 'v', 'unit': 'ms'},
          ],
        })!,
        [const ArtifactDataItem(1, {'v': 1.234})],
      );
      // 红=旧实现 toStringAsFixed(2) 截成 '1.23 ms'。
      expect(tiles.single.$2, '1.234 ms');
      final rows = buildTableRows(
        parseDashboardSpec('table', {
          'columns': ['v'],
        })!,
        [const ArtifactDataItem(1, {'v': 1.234})],
      );
      expect(rows.single.single, '1.234');
      // 整数值仍去 .0（JS String(3.0)==='3'）。
      final intRows = buildTableRows(
        parseDashboardSpec('table', {
          'columns': ['v'],
        })!,
        [const ArtifactDataItem(1, {'v': 3.0})],
      );
      expect(intRows.single.single, '3');
    });

    test('splitChartLineSegments：null 断线分段（红=旧画笔丢段/整线消失）',
        () {
      // 中段断点 → 2 段，段落含正确下标与值。
      final two = splitChartLineSegments([1, 2, null, 4, 5]);
      expect(two, hasLength(2));
      expect(two[0].map((p) => p.index), [0, 1]);
      expect(two[1].map((p) => p.index), [3, 4]);
      expect(two[1].map((p) => p.value), [4, 5]);
      // 末点 null → 末段保留（旧实现整线消失）。
      final trailing = splitChartLineSegments([1, 2, null]);
      expect(trailing, hasLength(1));
      expect(trailing.single.map((p) => p.value), [1, 2]);
      // 全 null → 0 段。
      expect(splitChartLineSegments([null, null]), isEmpty);
      // 首点 null / 单点段。
      final singles = splitChartLineSegments([null, 3, null, 7]);
      expect(singles, hasLength(2));
      expect(singles.every((s) => s.length == 1), isTrue);
    });
  });

  testWidgets('F3：run 卡 toolCallId 联接（工具行 output 无结构化字段）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      AppStateScope(
        app: _FakeWorkflowApp(),
        child: MaterialApp(
          home: Scaffold(
            body: WorkflowRunCard(
              sessionId: 's1',
              // v4 工具行 output 只有散文——runId/status 在
              // workflowRuns 投影按 toolCallId 联接。
              runs: const [
                {
                  'runId': 'run-9',
                  'toolCallId': 'tc-1',
                  'status': 'completed',
                },
              ],
              row: {
                'rowId': 7,
                'toolName': 'CreateWorkflow',
                'toolCallId': 'tc-1',
                'status': 'success',
                'inputText': '{"name":"内容流水线"}',
                'output': {
                  'text': '工作流已启动',
                  'truncated': false,
                },
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('内容流水线'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget, reason: '状态词映射');
    await tester.tap(find.byKey(const ValueKey('早前批次')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('F3 补充：run 卡名称优先结构化 input（run 早期 inputText 未定稿）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      AppStateScope(
        app: _FakeWorkflowApp(),
        child: MaterialApp(
          home: Scaffold(
            body: WorkflowRunCard(
              sessionId: 's1',
              runs: const [
                {
                  'runId': 'run-9',
                  'toolCallId': 'tc-1',
                  'status': 'running',
                },
              ],
              row: {
                'rowId': 8,
                'toolName': 'CreateWorkflow',
                'toolCallId': 'tc-1',
                'status': 'running',
                // 结构化入参先到、inputText 仍是空串（流式早期/重放档）。
                'input': {'name': '结构化工作流名'},
                'inputText': '',
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 红=旧实现只解析 inputText → 名称退化成「工作流」。
    expect(find.text('结构化工作流名'), findsOneWidget);
    expect(find.text('工作流'), findsNothing);
  });
}

class _FakeWorkflowApp extends AppState {
  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async =>
      {'runs': const []};

  @override
  Future<dynamic> workflowRunEvents(
          String sessionId, String runId,
          {int? afterSequence, int? limit}) async =>
      {'events': const [], 'hasMore': false};

  @override
  Future<dynamic> workflowRunArtifacts(
          String sessionId, String runId) async =>
      {'artifacts': const []};
}
