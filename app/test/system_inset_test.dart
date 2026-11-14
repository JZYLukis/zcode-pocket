// dual-pane-collapse-2 r3：底部安全区原生直推通道（vivo MediaQuery 透传
// 断裂的终局方案——原生监听 insets 推 dp 值，Dart ValueNotifier 接收）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/system_inset.dart' show systemInsetBottomDp, initSystemInsetBridge, refreshSystemInset;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    systemInsetBottomDp.value = 0;
  });

  test('原生 systemInsetChanged 推送更新值（clamp 0~200）', () async {
    initSystemInsetBridge();
    final binary =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 模拟原生反向调用（vivo 展开态任务栏≈64dp）。
    await binary.handlePlatformMessage(
      'companion/notify',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('systemInsetChanged', 64.2),
      ),
      (_) {},
    );
    expect(systemInsetBottomDp.value, 64.2);

    // 异常值钳制：负值/超大值不透传原样。
    await binary.handlePlatformMessage(
      'companion/notify',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('systemInsetChanged', -5),
      ),
      (_) {},
    );
    expect(systemInsetBottomDp.value, 0);
    await binary.handlePlatformMessage(
      'companion/notify',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('systemInsetChanged', 9999),
      ),
      (_) {},
    );
    expect(systemInsetBottomDp.value, 200);
  });

  test('r5：init 主动拉一次当前值（handler 先注册后拉取）', () async {
    initSystemInsetBridge();
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    // 拦截原生方向调用（currentSystemInset）返回 64.2——先注册 handler
    // 再拉取的时序由 init 内部保证。
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/notify'),
      (call) async {
        if (call.method == 'currentSystemInset') return 64.2;
        return null;
      },
    );
    systemInsetBottomDp.value = 0;
    await refreshSystemInset();
    expect(systemInsetBottomDp.value, 64.2);
    messenger.setMockMethodCallHandler(const MethodChannel('companion/notify'), null);
  });

  test('非 num 载荷静默忽略；重复 init 幂等', () async {
    initSystemInsetBridge();
    initSystemInsetBridge();
    final binary =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await binary.handlePlatformMessage(
      'companion/notify',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('systemInsetChanged', 'garbage'),
      ),
      (_) {},
    );
    expect(systemInsetBottomDp.value, 0, reason: '非 num 不更新');
  });
}
