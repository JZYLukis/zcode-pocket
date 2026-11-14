// 状态托盘（status-tray-1109）红绿：四源合并治理——单源直通零回归、
// ≥2 源合并单行摘要、展开体限高 240 内部滚动、段内动作原样可达、
// 体量（多源多账）有界。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/status_tray.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [child],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('单源：直接渲染原条带（零回归，不出托盘壳）', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_host(StatusTray(
      sections: [
        StatusTraySection(
          id: 'only',
          label: '排队',
          detail: '2 条',
          body: () => TextButton(
            key: const ValueKey('only-body'),
            onPressed: () => tapped++,
            child: const Text('排队 2 条'),
          ),
        ),
      ],
      expanded: false,
      onToggle: () {},
    )));
    expect(find.byKey(const ValueKey('only-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('status-tray')), findsNothing,
        reason: '单源=现状直通，不引入托盘壳（既有测试/肌肉记忆不变）');
    await tester.tap(find.byKey(const ValueKey('only-body')));
    expect(tapped, 1);
  });

  testWidgets('多源：合并单行摘要（段点+计数）+展开堆叠原条带+动作可达',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var acted = 0;
    Widget section(String id, String label, String detail,
            {double bodyHeight = 60}) =>
        SizedBox(
          key: ValueKey('body-$id'),
          height: bodyHeight,
          child: TextButton(
            key: ValueKey('act-$id'),
            onPressed: () => acted++,
            child: Text('$label $detail'),
          ),
        );
    var trayExpanded = false;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => StatusTray(
        sections: [
          StatusTraySection(
            id: 'queue',
            label: '排队',
            detail: '2 条',
            body: () => section('queue', '排队', '2 条'),
          ),
          StatusTraySection(
            id: 'unknown',
            label: '结果未知',
            detail: '',
            body: () => section('unknown', '结果未知', ''),
          ),
          StatusTraySection(
            id: 'unsent',
            label: '暂存消息',
            detail: '',
            body: () => section('unsent', '暂存消息', ''),
          ),
        ],
        expanded: trayExpanded,
        onToggle: () => setState(() => trayExpanded = !trayExpanded),
      ),
    )));
    // 折叠：一行摘要，三段在场，条带体不渲染。
    expect(find.byKey(const ValueKey('status-tray')), findsOneWidget);
    expect(find.text('排队 2 条'), findsOneWidget);
    expect(find.text('结果未知'), findsOneWidget);
    expect(find.text('暂存消息'), findsOneWidget);
    expect(find.byKey(const ValueKey('body-queue')), findsNothing);
    // 折叠行自身是 40dp 触控下限（bgworks 同款）。
    final toggle = tester.getSize(find.byKey(const ValueKey('status-tray-toggle')));
    expect(toggle.height, greaterThanOrEqualTo(40));

    // 展开：三段体堆叠在场，动作可达。
    await tester.tap(find.byKey(const ValueKey('status-tray-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('status-tray-body')), findsOneWidget);
    for (final id in ['queue', 'unknown', 'unsent']) {
      expect(find.byKey(ValueKey('body-$id')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('act-queue')));
    expect(acted, 1);
    await tester.tap(find.byKey(const ValueKey('act-unsent')));
    expect(acted, 2);
  });

  testWidgets('体量：多源长内容限高 240 内部滚动（红=无界堆叠）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(StatusTray(
      sections: [
        StatusTraySection(
          id: 'queue',
          label: '排队',
          detail: '30 条',
          body: () => Column(children: [
            for (var i = 1; i <= 30; i++)
              SizedBox(
                key: ValueKey('q-$i'),
                height: 24,
                child: Text('排队条目 $i'),
              ),
          ]),
        ),
        StatusTraySection(
          id: 'unknown-list',
          label: '结果未知',
          detail: '',
          body: () => Column(children: [
            for (var i = 1; i <= 51; i++)
              SizedBox(
                key: ValueKey('w-$i'),
                height: 24,
                child: Text('条目 $i'),
              ),
          ]),
        ),
      ],
      expanded: true,
      onToggle: () {},
    )));
    await tester.pump();
    final trayH =
        tester.getSize(find.byKey(const ValueKey('status-tray'))).height;
    expect(trayH, lessThan(320),
        reason: '81 项×24dp≈1944dp 堆叠也只占 240 限高+摘要行');
    // 非懒列表全树构建——可见性用 hitTestable；滚动可达末段。
    expect(find.text('条目 51').hitTestable(), findsNothing,
        reason: '初始视口在顶部');
    await tester.scrollUntilVisible(
      find.text('条目 51'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('status-tray-body')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    expect(find.text('条目 51').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
