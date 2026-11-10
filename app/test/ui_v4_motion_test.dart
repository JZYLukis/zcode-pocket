// V3/V4 审美优化轮：动效组件与扫码页四角框的渲染断言
// （模拟器盲导航截图效率低，按「日志断言优先」纪律改 finder 断言；
// 视觉细节由装机窗口人工肉眼验收。）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/motion.dart';
import 'package:zcode_pocket/ui/qr_scan_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('RunningPulseDot：细旋转图标（动画 ticker 不炸、无 glow）', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RunningPulseDot(
              color: AppThemeSpec.light.colors.running,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(RunningPulseDot), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.byType(RotationTransition), findsWidgets);
  });

  testWidgets('ShimmerText：文本渲染且 ShaderMask 生效', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ShimmerText(
              text: '正在思考',
              style: TextStyle(
                fontSize: 13,
                color: AppThemeSpec.light.colors.foreground,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1)); // 扫掠前半周期
    expect(find.text('正在思考'), findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);
  });

  testWidgets('EntryFadeSlide / PressScale / SlideIn：pump 不炸且子内容在', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            EntryFadeSlide(child: Text('new-row')),
            PressScale(child: Text('send')),
            SlideIn(child: Text('banner')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('new-row'), findsOneWidget);
    expect(find.text('send'), findsOneWidget);
    expect(find.text('banner'), findsOneWidget);
  });

  testWidgets('QrScanPage：四角框 CustomPaint + 相机降级文案', (tester) async {
    // 测试环境相机通道未注册时 invokeMethod 永不返回（start 挂起、错误态
    // 永不到达）——mock 成「权限被拒」让真实失败路径走到 errorBuilder。
    const scannerChannel = MethodChannel(
      'dev.steenbakker.mobile_scanner/scanner/method',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      scannerChannel,
      (call) async {
        switch (call.method) {
          case 'state':
            return 0; // undetermined → 触发 request
          case 'request':
            return false; // 拒绝 → MobileScannerException(permissionDenied)
          default:
            return null; // debug 模式 stop(force) 等
        }
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(scannerChannel, null),
    );
    // 四角 L 形框线（_CornerFramePainter 的 CustomPaint）与扫描线
    // （_ScanLine）叠加在降级文案上，均应存在且无溢出。扫描线是无限
    // 循环动画，用固定时长 pump（pumpAndSettle 永不静止）。
    await tester.pumpWidget(const MaterialApp(home: QrScanPage()));
    await tester.pump(const Duration(milliseconds: 500));
    // 回填律（视觉验收 S07 实锤）：CustomPaint 在 Stack 松约束下曾塌缩
    // 0×0——断言取景框盒子实际尺寸 240×240。
    final box = find
        .byKey(const ValueKey('corner-frame'))
        .evaluate()
        .first
        .renderObject! as RenderBox;
    expect(box.size, const Size(240, 240));
    expect(find.byType(QrScanPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 相机失败必须浮出页面级提示——
    // 修复前 _cameraError 是死状态（errorBuilder 渲染在 0×0 盒内不可见），
    // 权限被拒/无相机=静默死页，本断言红。errorBuilder→帧尾 setState。
    await tester.pump();
    expect(find.textContaining('相机不可用（未授权相机）'), findsOneWidget,
        reason: '修复前：错误态文案不可达（_cameraError 全文件零赋值）');
    expect(find.textContaining('改用「粘贴链接」'), findsOneWidget);
    expect(find.textContaining('对准桌面端'), findsNothing,
        reason: '错误态下底部的扫码引导文案应让位');
    expect(tester.takeException(), isNull);
  });
}
