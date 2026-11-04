import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/status_badge.dart';

void main() {
  testWidgets('状态图标：运行中 sync、完成 check、空闲 schedule、等待 hand', (tester) async {
    Widget icon(String phase) => MaterialApp(
          home: Center(child: taskPhaseIcon(phase, const Color(0xFF16A34A))),
        );
    await tester.pumpWidget(icon('running'));
    expect(find.byIcon(Icons.sync), findsOneWidget);
    await tester.pumpWidget(icon('completedSuccess'));
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pumpWidget(icon('idle'));
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    await tester.pumpWidget(icon('waiting'));
    expect(find.byIcon(Icons.front_hand_outlined), findsOneWidget);
  });
}
