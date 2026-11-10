// ignore_for_file: avoid_print
import 'dart:async';

import 'fake_relay_v2.dart';

/// FakeRelayV2 常驻 runner（ 模拟器冒烟用，非测试）：
/// 启动本地假中继 + 注册一台"桌面"设备并保持 device 角色在线——
/// 模拟器里的 app 经 `--es relay_v2_origin http://10.0.2.2:<port>` +
/// `--es account_jwt injected-test-jwt` 注入后即可走完整 V2 流程
/// （设备列表→选电脑→token→ws2→paired→业务载荷往返）。
///
/// 用法：dart run test/fake_relay_v2_runner.dart [端口，默认 8582]
/// （固定端口便于 E2E 复跑；被占用时换一个并同步改 --dart-define。）
Future<void> main(List<String> args) async {
  const testJwt = 'injected-test-jwt';
  // jwt-bob：E2E 异账号路径用（device-not-owned）。
  final fake = FakeRelayV2(users: {
    testJwt: 'user-test',
    'jwt-bob': 'user-bob',
  });
  final port = args.isNotEmpty ? int.tryParse(args[0]) ?? 8582 : 8582;
  await fake.start(port: port, loopbackOnly: false);
  final sid = fake.registerDevice(testJwt, mid: 'mumu-test-desktop');
  final device = await fake.connectDevice(sid);
  print('FAKE_READY origin=${fake.origin} sid=$sid jwt=$testJwt');
  print('device 角色已在线；等待手机 app 连接…');

  // 打印手机侧发来的业务载荷（bootstrap-request 等）——日志断言靶。
  // 用事件流消费（waitFor 轮询历史会自旋，见 FakeDeviceSide.onData 注释）。
  device.onData.listen((payload) {
    print('TERMINAL_PAYLOAD $payload');
  });

  Timer.periodic(const Duration(seconds: 30), (_) {
    print('alive wsConnections=${fake.wsConnections} events=${fake.log.length}');
  });

  await Completer<void>().future; // 常驻
}
