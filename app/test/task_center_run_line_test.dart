// 宽屏紧凑行 workflow run 线回归（对抗审查中⑨）：官方
// WORKFLOW_RUN_LINE_MAX_LINES=2——最多 2 条行 + 「+n」尾；pending 无
// phase=等待中（不是运行中）；行高随 textScaler/行数动态（旧固定 68px
// 在 ≥2 条或大字号下溢出）。红=旧实现全量渲染且固定高度。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('run 行最多 2 条 + 「+n」尾巴（官方 MAX_LINES=2）', (tester) async {
    await tester.pumpWidget(
      _host(
        WorkflowRunLines(
          runs: [
            {'name': '构建', 'status': 'running', 'currentPhase': '编译'},
            {'name': '测试', 'status': 'running'},
            {'name': '发布', 'status': 'pending'},
          ],
        ),
      ),
    );
    expect(find.text('构建 · 编译'), findsOneWidget);
    expect(find.text('测试 · 运行中'), findsOneWidget);
    expect(find.textContaining('发布'), findsNothing,
        reason: '第 3 条 run 只折成 +1，不逐条堆叠');
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('pending 且无 phase：状态词=等待中（不是运行中）', (tester) async {
    await tester.pumpWidget(
      _host(
        WorkflowRunLines(
          runs: [
            {'name': '队列', 'status': 'pending'},
          ],
        ),
      ),
    );
    expect(find.text('队列 · 等待中'), findsOneWidget);
    expect(find.textContaining('运行中'), findsNothing,
        reason: 'pending 误显示「运行中」（红=旧 _runLine 分支合并）');
  });

  test('紧凑行高度：无 run=48，1/2 条递增，≥3 条封顶 3 行，随 textScaler 放大', () {
    expect(compactTaskRowHeight(0, TextScaler.noScaling), 48);
    final one = compactTaskRowHeight(1, TextScaler.noScaling);
    final two = compactTaskRowHeight(2, TextScaler.noScaling);
    final three = compactTaskRowHeight(3, TextScaler.noScaling);
    expect(one, greaterThan(48));
    expect(two, greaterThan(one));
    expect(three, greaterThan(two));
    expect(compactTaskRowHeight(9, TextScaler.noScaling), three,
        reason: '≥3 条只画 2 行+「+n」，高度封顶（官方 MAX_LINES=2）');
    expect(
      compactTaskRowHeight(3, const TextScaler.linear(2)),
      greaterThan(three),
      reason: '大字号必须加高（旧固定 68px 溢出的根因）',
    );
    // 行高系数覆盖实际渲染（M3 ≈1.43 行高 + 逐行 padding）——
    // 3 行 noScaling 至少 48+3*(14.5+3)=100.5（1.25 系数只给 97.25）。
    expect(three, greaterThanOrEqualTo(100),
        reason: '系数 1.25 低估实际行高，3 run+1.3× 仍溢出');
  });
}
