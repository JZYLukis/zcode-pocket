// 阶段 6.1 多机型防御性适配：
// ① 系统字号全局钳制上限 1.3（用户拍板）——经真 App 根 builder 生效
//    （ZcodeCompanionApp 全路由/弹层统一），2.0 档压到 1.3、1.2 档原样
//    透传（尊重调小与中间档）、1.0 档不受影响。
// ② 多分辨率不爆版由游览测试扩展档位承担（ui_v4_visual_tour_test
//    w320/w320s13/w840 三档环绕既有全部场景——RenderFlex 溢出在 widget
//    测试即抛错，无需基线）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/app.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/ui/home_shell.dart';

void main() {
  testWidgets('字号钳制：系统 2.0 档被压到 1.3 上限（全路由生效）', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(ZcodeCompanionApp(app: AppState()));
    await tester.pump(const Duration(milliseconds: 200));
    final ctx = tester.element(find.byType(HomeShell));
    final scaler = MediaQuery.of(ctx).textScaler;
    expect(scaler.scale(20), closeTo(26, 0.01), reason: '2.0 应钳到 1.3');
  });

  testWidgets('字号钳制：1.2 档原样透传（未达上限不拦）', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(ZcodeCompanionApp(app: AppState()));
    await tester.pump(const Duration(milliseconds: 200));
    final ctx = tester.element(find.byType(HomeShell));
    expect(MediaQuery.of(ctx).textScaler.scale(20), closeTo(24, 0.01));
  });

  testWidgets('字号钳制：1.0 档不受影响', (tester) async {
    await tester.pumpWidget(ZcodeCompanionApp(app: AppState()));
    await tester.pump(const Duration(milliseconds: 200));
    final ctx = tester.element(find.byType(HomeShell));
    expect(MediaQuery.of(ctx).textScaler.scale(20), 20);
  });
}
