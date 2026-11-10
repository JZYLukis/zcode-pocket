import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme.dart';

/// 扫码添加电脑：对准桌面端远程控制二维码，扫到后 pop 返回 URL 文本。
/// 相机不可用（未授权/模拟器）时提示改用粘贴链接。
///
/// 扫码黑屏终局方案：**不再挂载 MobileScanner 预览
/// 纹理**——agent 自动复现实证，相机纹理（Flutter texture registry）的
/// 生命周期在部分华为机型会把渲染管线楔死（窗口黑、进程健康；Skia 回退/
/// 停流先行/帧看门狗三层防御均不治，帧仍在产但合成器输出黑=检测面之
/// 外）。改为 controller 纯分析模式（相机仅出分析流，不建预览纹理），
/// UI 用静态取景框引导瞄准——从根上移除纹理，代价是无实时取景画面
/// （个人应用可接受，后续 Flutter 引擎修复后可复测恢复预览）。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  StreamSubscription<BarcodeCapture>? _sub;
  bool _handled = false;
  bool _cameraError = false;
  String? _cameraErrorText;

  @override
  void initState() {
    super.initState();
    _sub = _controller.barcodes.listen(
      (capture) {
        for (final barcode in capture.barcodes) {
          _accept(barcode.rawValue);
          if (_handled) break;
        }
      },
      onError: (Object e) {
        debugPrint('[qr-scan] barcodes stream error: $e');
      },
    );
    // 不手动 start：零尺寸挂载的 MobileScanner(widget) 携 autoStart 启动
    // （教训：手动 start 与 widget 自动启动竞态抛 controllerInitializing
    // ——测试环境实测；插件要求 controller 必须挂 widget，启动责任归 widget）。
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  //相机错误浮出到页面级：
  /// `_cameraError` 此前是死状态——mobile_scanner 默认 errorBuilder 渲染
  /// 在 0×0 挂载盒内不可见，权限被拒/无相机=静默死页。一次性闩锁
  /// （mobile_scanner 的错误态不随重试自动清除）；错误态只出文字提示+
  /// 「粘贴链接」引导，不恢复预览纹理（拍板取舍不变）。
  void _onCameraError(MobileScannerException error) {
    debugPrint('[qr-scan] camera error: $error');
    if (_cameraError) return;
    _cameraError = true;
    final text = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => '未授权相机',
      MobileScannerErrorCode.unsupported => '设备无可用相机',
      _ => null,
    };
    // errorBuilder 在 build 期回调——setState 推迟到帧尾。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _cameraErrorText = text);
    });
  }

  /// 停流后再退出（根治层 2，保留）：检测命中与系统返回统一走
  /// "停相机→等一拍→pop"，彻底避免与路由转场并发。
  /// ：stop 加 1s 超时——异常设备上 stop 挂起时返回键
  /// 会被永久吞掉（_handled 已置位+pop 永不到达）。
  Future<void> _stopCameraThenPop([String? result]) async {
    if (_handled) return;
    _handled = true;
    try {
      await _sub?.cancel();
      await _controller.stop().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    Navigator.of(context).pop(result?.trim());
  }

  void _accept(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    _stopCameraThenPop(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码添加电脑')),
      // 系统返回也走停相机序列：直接 pop 会与相机生命周期竞态。
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _stopCameraThenPop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 无预览模式的暗色底（原为相机画面）。
            Container(color: Colors.black87),
            // 零尺寸挂载 MobileScanner（诊断实证：mobile_scanner 7.5.0
            // 的 controller 必须挂上 widget 才能 start——controllerNotAttached
            // 异常=相机从未启动=用户"相机不可用"）。零尺寸=纹理注册、参与
            // 扫描分析流，但不绘制任何像素（渲染管线零负担）。
            SizedBox(
              width: 0,
              height: 0,
              child: MobileScanner(
                controller: _controller,
                // 相机失败（未授权/无相机/控制器错误）的唯一可见出口——
                // 默认 errorBuilder 会渲染在 0×0 盒内=不可见。
                errorBuilder: (context, error) {
                  _onCameraError(error);
                  return const SizedBox.shrink();
                },
              ),
            ),
            // 取景框提示（视觉引导，不做裁剪）——V1 审美优化：四角 L 形
            // 扫描框线（品牌蓝点睛位），扫码页的强心智预期（评审 2.3#4）。
            // 始终渲染（相机降级时错误文案叠加其上，与旧行为一致）。
            Center(
              child: SizedBox(
                width: 240,
                height: 240,
                child: Stack(
                  children: [
                    // Stack 对 non-positioned 子级是松约束——CustomPaint
                    // 必须显式给 size，否则塌缩 0×0（视觉验收 实锤）。
                    CustomPaint(
                      key: const ValueKey('corner-frame'),
                      size: const Size(240, 240),
                      painter: _CornerFramePainter(
                        color: context.colors.brandAccent,
                      ),
                    ),
                    // V3 动效包#6：扫描线（1.8s 循环；系统关动画时隐藏）。
                    const _ScanLine(),
                  ],
                ),
              ),
            ),
            if (_cameraError)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _cameraErrorText == null
                        ? '相机不可用，请返回改用「粘贴链接」添加'
                        : '相机不可用（$_cameraErrorText），请返回改用「粘贴链接」添加',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.colors.foregroundSubtle),
                  ),
                ),
              )
            else
              Positioned(
                left: 0,
                right: 0,
                bottom: 32,
                child: Text(
                  '对准桌面端 ZCode → 远程控制 显示的二维码（无取景预览：对准框内即可识别）',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: AppType.uiCaption,
                    shadows: const [
                      Shadow(blurRadius: 4, color: Colors.black54),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 四角 L 形取景框线（V1 审美优化：替代原整圈描边空框）。
class _CornerFramePainter extends CustomPainter {
  final Color color;

  const _CornerFramePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const arm = 26.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    void seg(Offset a, Offset b) => canvas.drawLine(a, b, paint);
    final tl = Offset.zero;
    final tr = Offset(size.width, 0);
    final bl = Offset(0, size.height);
    final br = Offset(size.width, size.height);
    seg(tl, Offset(arm, 0));
    seg(tl, Offset(0, arm));
    seg(tr, Offset(size.width - arm, 0));
    seg(tr, Offset(size.width, arm));
    seg(bl, Offset(arm, size.height));
    seg(bl, Offset(0, size.height - arm));
    seg(br, Offset(size.width - arm, size.height));
    seg(br, Offset(size.width, size.height - arm));
  }

  @override
  bool shouldRepaint(_CornerFramePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 取景框扫描线（V3 动效包）：品牌蓝 2px 横线沿框上下往返，两端渐隐。
class _ScanLine extends StatefulWidget {
  const _ScanLine();

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final top = 8 + _c.value * (240 - 16 - 2);
        return Positioned(
          left: 14,
          right: 14,
          top: top,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  context.colors.brandAccent.withValues(alpha: 0),
                  context.colors.brandAccent,
                  context.colors.brandAccent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
