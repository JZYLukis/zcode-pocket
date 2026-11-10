import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/relay_client.dart'
    show RelayClient, RelayFailure, RelayState;
import 'package:zcode_pocket/transport/relay_v2.dart';
import 'package:zcode_pocket/ui/device_list_page.dart' show pickAutoConnectDevice;

import 'fake_relay_v2.dart';

/// Relay V2 连接层：对 FakeRelayV2（官方夹具的 Dart 移植）
/// 跑协议行为——握手/配对/数据往返/心跳看门狗/KICKED/掉线宽限/失败映射。
/// 契约出处见 relay_v2.dart 头注释。
void main() {
  // 测试时序：全部加速（心跳 40ms/看门狗 300ms/退避 10ms 起）。
  const timing = RelayV2Timing(
    heartbeatBase: Duration(milliseconds: 40),
    heartbeatJitter: Duration.zero,
    ackTimeout: Duration(milliseconds: 300),
    waitingTimeout: Duration(milliseconds: 200),
    deviceOfflineGrace: Duration(milliseconds: 200),
    backoffInitial: Duration(milliseconds: 10),
    backoffMax: Duration(milliseconds: 50),
    kickFirstMin: Duration(milliseconds: 10),
    kickFirstMax: Duration(milliseconds: 20),
    kickWindow: Duration(milliseconds: 400),
  );

  Future<bool> until(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return cond();
  }

  Future<FakeRelayV2> setUpFake() async {
    final fake = FakeRelayV2();
    await fake.start();
    addTearDown(() => fake.close());
    return fake;
  }

  RelayV2Client setUpClient(
    FakeRelayV2 fake,
    String sid, {
    String jwt = 'jwt-alice',
    String? mid,
    RelayV2Timing? clientTiming,
  }) {
    final client = RelayV2Client(
      config: RelayV2Config(
        endpointOrigin: fake.origin,
        deviceSid: sid,
        deviceMid: mid,
        deviceName: '测试机',
        appVersion: 'test',
      ),
      jwtProvider: () async => jwt,
      timing: clientTiming ?? timing,
    );
    addTearDown(client.dispose);
    return client;
  }

  group('parseCompanionV2Params', () {
    test('V2 参数齐全解析；空白值剔除', () {
      final p = parseCompanionV2Params(
        'https://zcode.z.ai/remote/v4?sid=d_1&mid=m_1&name=%E6%A1%8C%E9%9D%A2&app_version=3.16.2',
      )!;
      expect(p.deviceSid, 'd_1');
      expect(p.deviceMid, 'm_1');
      expect(p.deviceName, '桌面');
      expect(p.appVersion, '3.16.2');
    });

    test('带 hash/t 的 V1 链接一律拒绝（含空值，无回退）', () {
      expect(
        parseCompanionV2Params('https://zcode.z.ai/remote/v4?sid=d&hash=h&t=1'),
        isNull,
      );
      expect(parseCompanionV2Params('https://zcode.z.ai/remote/v4?hash='), isNull);
      expect(parseCompanionV2Params('https://zcode.z.ai/remote/v4?t=123'), isNull);
    });

    test('全空参数合法（=设备列表流程）；非安全 scheme 拒绝', () {
      final p = parseCompanionV2Params('https://zcode.z.ai/remote/v4');
      expect(p, isNotNull);
      expect(p!.deviceSid, isNull);
      expect(parseCompanionV2Params('http://zcode.z.ai/remote/v4'), isNull);
    });

    // （三路同报）：Uri.parse 宽容接受
    // 非法/截断 UTF-8 百分号转义，异常延迟到 queryParameters 惰性解码才
    // 抛（本机 SDK 实测：裸 `%`/`%zz` 原样保留不抛；`%E4`/`%C3%28` 抛
    // FormatException）——此前 try 只包 Uri.parse，异常冒到配对页每键击
    // 的 _syncName/连接按钮。契约=无效一律返回 null，不得抛。
    test('畸形百分号转义按契约返回 null（不抛异常）', () {
      expect(
        parseCompanionV2Params('https://zcode.z.ai/remote/v4?sid=%E4'),
        isNull,
      );
      expect(
        parseCompanionV2Params('https://zcode.z.ai/remote/v4?sid=d&name=%C3%28'),
        isNull,
      );
      expect(
        () => isV2PairingUrl('https://zcode.z.ai/remote/v4?sid=%E4'),
        returnsNormally,
      );
      expect(
        CompanionConnectionParams.parse(
          'https://zcode.z.ai/remote/v4?sid=abc&hash=h&t=1&name=%E4',
        ),
        isNull,
      );
    });

    test('isV2PairingUrl：官方域+带参才路由，垃圾/空参/异域一律 false', () {
      expect(
        isV2PairingUrl('https://zcode.z.ai/remote/v4?sid=d_1&name=桌面'),
        isTrue,
      );
      expect(isV2PairingUrl('https://example.com/not-a-remote-url'), isFalse);
      expect(isV2PairingUrl('https://zcode.z.ai/remote/v4'), isFalse,
          reason: '全空参数=设备列表专用入口，粘贴框按无效处理');
      expect(
        isV2PairingUrl('https://zcode.z.ai/remote/v4?sid=d&hash=h&t=1'),
        isFalse,
      );
    });

    test('pickAutoConnectDevice：恰好一台在线直连，其余场景列表自选', () {
      RelayV2Device d(String sid, bool online) => RelayV2Device(
        deviceSid: sid,
        deviceMid: 'm',
        online: online,
      );
      expect(pickAutoConnectDevice([d('a', true), d('b', false)]), 'a');
      expect(pickAutoConnectDevice([d('a', true), d('b', true)]), isNull);
      expect(pickAutoConnectDevice([d('a', false)]), isNull);
      expect(pickAutoConnectDevice(const []), isNull);
    });
  });

  group('RelayV2Api（HTTP）', () {
    test('token 签发/未知 JWT 401/设备列表按账号隔离', () async {
      final fake = await setUpFake();
      final aliceSid = fake.registerDevice('jwt-alice');
      fake.registerDevice('jwt-alice');
      fake.registerDevice('jwt-bob');

      final api = RelayV2Api(
        origin: fake.origin,
        jwtProvider: () async => 'jwt-alice',
      );
      final token = await api.fetchToken(role: 'terminal');
      expect(token.length, 22);

      final bobApi = RelayV2Api(
        origin: fake.origin,
        jwtProvider: () async => 'jwt-unknown',
      );
      await expectLater(
        bobApi.fetchToken(role: 'terminal'),
        throwsA(isA<RelayV2AuthRequired>()),
      );

      final devices = await api.listDevices();
      expect(devices.length, 2);
      expect(devices.first.deviceSid, aliceSid);
      expect(devices.every((d) => !d.online), isTrue);
    });

    test('jwtProvider 返回空 = auth-required', () async {
      final fake = await setUpFake();
      final api = RelayV2Api(origin: fake.origin, jwtProvider: () async => null);
      await expectLater(
        api.fetchToken(role: 'terminal'),
        throwsA(isA<RelayV2AuthRequired>()),
      );
    });

    // （三路同报）：此前"非 5xx 即终态"
    // ——429 限流（重连风暴恰是最易触发路径）、408 超时、captive portal
    // 302 重定向（followRedirects=false 不跟随）全被钉死在不可重试的
    // relay-unavailable 终态。仅 401/403/404 保持终态。
    test('HTTP 状态分级：429/408/3xx 归瞬态退避；403/404 保持终态', () async {
      var status = 429;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await utf8.decoder.bind(req).drain();
        req.response.statusCode = status;
        if (status == 302) {
          // portal 形态：重定向+空 body（非 JSON）。
          req.response.headers.set(
            HttpHeaders.locationHeader,
            'https://portal.example/login',
          );
        } else {
          req.response.write('{"code":${status}00,"msg":"test"}');
        }
        await req.response.close();
      });
      final api = RelayV2Api(
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        jwtProvider: () async => 'jwt-x',
      );
      Future<bool> retryableOf(int s) async {
        status = s;
        try {
          await api.fetchToken(role: 'terminal');
          fail('HTTP $s 应抛 RelayV2Unavailable');
        } on RelayV2Unavailable catch (e) {
          return e.retryable;
        }
      }
      expect(await retryableOf(429), isTrue, reason: '限流应退避重试');
      expect(await retryableOf(408), isTrue, reason: '请求超时应重试');
      expect(await retryableOf(302), isTrue, reason: 'portal 重定向应重试（不跟随）');
      expect(await retryableOf(403), isFalse, reason: 'WAF/权限拒绝不自愈');
      expect(await retryableOf(404), isFalse, reason: '路径不存在不自愈');
    });

    // 响应体 join 无字节数上限——恶意/异常中间盒灌
    // 巨 body 会整页进内存耗尽可用内存；超限须按失败处理（且不可重试，
    // 重试只会再拖一遍巨 body）。
    test('响应体超上限按终态失败（修复前=整页 join 进内存）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await utf8.decoder.bind(req).drain();
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        try {
          // 5MiB 垃圾 body（上限 4MiB，超限即断）。
          req.response.add(
            Uint8List(5 * 1024 * 1024)..fillRange(0, 5 * 1024 * 1024, 0x61),
          );
          await req.response.close();
        } catch (_) {
          // 客户端超限即断——服务端剩余写入报错属预期。
        }
      });
      final api = RelayV2Api(
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        jwtProvider: () async => 'jwt-x',
      );
      await expectLater(
        api.fetchToken(role: 'terminal'),
        throwsA(
          // 巨 body 重试无意义，须终态。
          isA<RelayV2Unavailable>()
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });
  });

  group('RelayV2Client（ws2 全链路）', () {
    test('注册+桌面在线：token→ws2→auth_init→paired，数据双向往返', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final client = setUpClient(fake, sid);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);

      // 手机→桌面
      client.sendPayload({'zcode_type': 'bootstrap-request', 'requestId': 'r1'});
      final got = await device.waitFor('data', const Duration(seconds: 2));
      expect(got, isNotNull);
      expect((got!['payload'] as Map)['zcode_type'], 'bootstrap-request');

      // 桌面→手机
      final received = <Map<String, dynamic>>[];
      final sub = client.payloads.listen(received.add);
      addTearDown(() => sub.cancel());
      device.sendPayload({'zcode_type': 'workspace-list-updated'});
      expect(
        await until(() => received.any((p) => p['zcode_type'] == 'workspace-list-updated')),
        isTrue,
      );
    });

    test('出站队列：waiting 期发送的业务载荷在 paired 后冲刷', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');

      final client = setUpClient(fake, sid);
      client.start();
      expect(await until(() => client.state == RelayState.waiting), isTrue);
      client.sendPayload({'zcode_type': 'bootstrap-request', 'requestId': 'q1'});

      final device = await fake.connectDevice(sid);
      addTearDown(device.close);
      expect(await until(() => client.state == RelayState.paired), isTrue);
      final got = await device.waitFor('data', const Duration(seconds: 2));
      expect(got, isNotNull);
      expect((got!['payload'] as Map)['requestId'], 'q1');
    });

    test('waiting 超时：发一次 desktop-disconnected，保持 waiting 可恢复', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: timing,
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();

      expect(await until(() => client.state == RelayState.waiting), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        failures.where((f) => f.reason == 'desktop-disconnected').length,
        1, // 每个 waiting episode 只一次，不随 30s 重武装刷屏
      );
      expect(client.state, RelayState.waiting);

      // 桌面上线 → 自动配上。
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);
      expect(await until(() => client.state == RelayState.paired), isTrue);
    });

    test('账号不符：AUTH_FAILED → device-not-owned 终态', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-bob',
        timing: timing,
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();

      expect(await until(() => client.state == RelayState.error), isTrue);
      expect(failures.map((f) => f.reason), contains('device-not-owned'));
    });

    test('JWT 缺失：auth-required 终态（不重试）', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => null,
        timing: timing,
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();

      expect(await until(() => client.state == RelayState.error), isTrue);
      expect(failures.map((f) => f.reason), contains('auth-required'));
    });

    // dispose 与在飞 fetchToken 的 401/凭据缺失交错时，
    // RelayV2AuthRequired catch 无 _disposed 守卫——对已 dispose 的
    // ValueNotifier 赋值+向已 close 的 _failureController add，从
    // unawaited(_connect()) 逃逸为未捕获异步错误（release 抛 StateError）。
    // jwt 迟到返回 null（jwtProvider 判空先于 HTTP，无需真实服务）。
    test('dispose 与 auth-required 竞态：迟到的凭据失败不触碰已释放资源', () async {
      final client = RelayV2Client(
        config: RelayV2Config(
          endpointOrigin: Uri.parse('http://127.0.0.1:9'),
          deviceSid: 'd-dispose-race',
        ),
        jwtProvider: () async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return null; // 迟到抛 RelayV2AuthRequired（等效 401 竞态）
        },
        timing: timing,
      );
      client.start();
      // 在飞 token 窗口内拆栈（真实路径：90s 断连 suspend/删电脑 disposeStack）。
      await client.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(client.state, RelayState.closed);
    });

    test('KICKED：首次 2~5s 重连恢复；窗口内二次=session-conflict 终态；手动恢复可用', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: timing,
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);

      // 第一次被踢（测试时序 kickFirst=10~20ms）：自动恢复。
      await fake.stealTerminal(sid);
      expect(
        await until(() => client.state == RelayState.paired),
        isTrue,
        reason: '首次 KICKED 应自动重连恢复',
      );

      // 窗口内（kickWindow=400ms）第二次 → 终态。
      await fake.stealTerminal(sid);
      expect(await until(() => client.state == RelayState.kicked), isTrue);
      expect(failures.map((f) => f.reason), contains('session-conflict'));

      // 用户主动恢复 → 再次 paired。
      client.retryAfterKicked();
      expect(await until(() => client.state == RelayState.paired), isTrue);
    });

    test('DEVICE_OFFLINE：最小退避重连进 waiting，宽限到发 desktop-disconnected', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      await fake.connectDevice(sid);

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: timing,
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);
      final connectionsBefore = fake.wsConnections;

      fake.dropDevice(sid); // 桌面掉线（无 close 帧销毁）
      // waiting 推送先到（旧 socket），重连在其后——两条件合并等待防竞态
      // （15s 上限：全量套件下机器负载会显著放大重连耗时，实测偶发 5s+）。
      expect(
        await until(
          () =>
              client.state == RelayState.waiting &&
              fake.wsConnections > connectionsBefore,
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: 'DEVICE_OFFLINE 应触发退避重连并进入 waiting'
            '（state=${client.state} conns=${fake.wsConnections}/$connectionsBefore）',
      );
      expect(
        await until(
          () => failures.any((f) => f.reason == 'desktop-disconnected'),
          // 负载余量（测试稳定性根治 2026-10-29 批次）：宽限 200ms 语义
          // 不变，满载套件下事件循环被拉长时 2s 上限偶发不足（已知偶发
          // 家族）；断言是次序语义（waiting→宽限→失败），放宽不弱化。
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: '宽限（200ms）内未重新 paired 应发 desktop-disconnected',
      );
      expect(client.state, RelayState.waiting);
    });

    // _armOfflineGrace 武装的 15s 宽限定时器
    // 被紧随其后的 _reconnect() 内 _cancelTimers() 同步撤销——宽限永不可
    // 达（死代码），信号退化到 30s waiting 超时。既有用例 grace/waiting
    // 同为 200ms 且只断言 reason，完全掩盖此路径。本用例用可区分 timing
    // （宽限 150ms << waiting 1000ms）+ 断言宽限专属文案「桌面端已离线」。
    test('DEVICE_OFFLINE 宽限真实触发：150ms 宽限先于 waiting 超时发「桌面端已离线」', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      await fake.connectDevice(sid);

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: const RelayV2Timing(
          heartbeatBase: Duration(milliseconds: 40),
          heartbeatJitter: Duration.zero,
          ackTimeout: Duration(milliseconds: 300),
          // （终审批1）：waitingTimeout 与 grace 拉开 33 倍余量——
          // 原 1000ms vs 150ms 在负载下宽限回调被推迟 >1s 即误红。
          waitingTimeout: Duration(milliseconds: 5000),
          deviceOfflineGrace: Duration(milliseconds: 150),
          backoffInitial: Duration(milliseconds: 10),
          backoffMax: Duration(milliseconds: 50),
          kickFirstMin: Duration(milliseconds: 10),
          kickFirstMax: Duration(milliseconds: 20),
          kickWindow: Duration(milliseconds: 400),
        ),
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);

      fake.dropDevice(sid);
      expect(
        await until(
          () => failures.any((f) => f.message == '桌面端已离线'),
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: '宽限（150ms）到仍未 paired 应发宽限专属文案「桌面端已离线」'
            '——修复前该定时器被 _reconnect 的 _cancelTimers 同步撤销，'
            '此事件永不可能出现（failures=${failures.map((f) => f.message)}）',
      );
      // 到达时刻必须早于 waiting 超时（5000ms）——证明信号源是宽限而非
      // waiting 超时路径（其文案为「桌面端不在线」）。
      expect(
        failures.where((f) => f.message == '桌面端不在线'),
        isEmpty,
        reason: 'waiting 超时（5000ms）不应已触发——事件必须来自宽限',
      );
    });

    // 协议传输批（2026-11-08）：官方 recoverFromDeviceOffline 的宽限是
    // **一次性武装**（webRemoteControlTransport.ts:614-619 `if
    // (!desktopOfflineFailureTimer)`）——旧实现每次事件 cancel+重排，桌面
    // 持续离线时宽限被无限续期，desktop-disconnected 永不落地；且
    // `_reconnect(delay: Duration.zero)` 把"桌面不在"放大成零退避重连风暴。
    test('DEVICE_OFFLINE 宽限一次性+退避：连续事件只发一次失败，不零延迟重连', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final failures = <RelayFailure>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: const RelayV2Timing(
          heartbeatBase: Duration(milliseconds: 40),
          heartbeatJitter: Duration.zero,
          ackTimeout: Duration(milliseconds: 300),
          waitingTimeout: Duration(milliseconds: 5000),
          deviceOfflineGrace: Duration(milliseconds: 200),
          // 可区分档：零延迟重连会立即 +1 条连接，本断言抓"无退避"。
          backoffInitial: Duration(milliseconds: 150),
          backoffMax: Duration(milliseconds: 300),
          kickFirstMin: Duration(milliseconds: 10),
          kickFirstMax: Duration(milliseconds: 20),
          kickWindow: Duration(milliseconds: 400),
        ),
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);
      fake.vanishDevice(sid); // 桌面在 relay 侧消失：重连后进 waiting
      final connsBefore = fake.wsConnections;

      // 第一拍：武装 200ms 宽限 + 排 150ms 退避重连。
      client.debugHandleRelayFrame({'type': 'error', 'code': 'DEVICE_OFFLINE'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // 退避窗口内的连续事件：不得重排宽限、不得取消在途退避。
      client.debugHandleRelayFrame({'type': 'error', 'code': 'DEVICE_OFFLINE'});
      client.debugHandleRelayFrame({'type': 'error', 'code': 'DEVICE_OFFLINE'});
      expect(fake.wsConnections, connsBefore,
          reason: 'DEVICE_OFFLINE 重连须走最小退避（修复前 delay:zero 立即 +1）');

      // 宽限到点：发一次「桌面端已离线」；之后同一 episode 连续事件
      // 不得把定时器续期/重复发事件。
      expect(
        await until(
          () => failures.any((f) => f.message == '桌面端已离线'),
          timeout: const Duration(seconds: 10),
        ),
        isTrue,
      );
      for (var i = 0; i < 6; i++) {
        client.debugHandleRelayFrame({
          'type': 'error',
          'code': 'DEVICE_OFFLINE',
        });
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      expect(
        failures.where((f) => f.message == '桌面端已离线').length,
        1,
        reason: '宽限一次性：同一离线 episode 不得重复刷失败事件',
      );
      expect(fake.wsConnections, greaterThan(connsBefore),
          reason: '退避到点后确实重连（不是永不重连）');
      expect(
        await until(
          () => client.state == RelayState.waiting,
          timeout: const Duration(seconds: 10),
        ),
        isTrue,
      );
    });

    // 协议传输批（2026-11-08）：官方 relay 在 data 找不到对端设备时回
    // `{type:'error', code:'INTERNAL'}`（fake-relay-v2.ts），客户端保持
    // WS 降级 waiting 继续查询（enterWaitingForDeviceAfterRelayError）。
    // 旧夹具静默丢弃 data，该降级路径全仓零覆盖。
    test('INTERNAL 降级：保持连接进 waiting；重配后新 episode 再发一次失败', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      var device = await fake.connectDevice(sid);

      final failures = <RelayFailure>[];
      final logs = <String>[];
      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        // 专用时序：心跳/看门狗放远，纯等 waiting 超时（避免无关 ACK
        // 把 INTERNAL 武装的 waiting 定时器清掉——_applyPairStatus 的
        // 曾配对 waiting 分支会 clearWaitingTimer）。
        timing: const RelayV2Timing(
          heartbeatBase: Duration(seconds: 2),
          heartbeatJitter: Duration.zero,
          ackTimeout: Duration(seconds: 5),
          waitingTimeout: Duration(milliseconds: 200),
          deviceOfflineGrace: Duration(seconds: 2),
          backoffInitial: Duration(milliseconds: 10),
          backoffMax: Duration(milliseconds: 50),
          kickFirstMin: Duration(milliseconds: 10),
          kickFirstMax: Duration(milliseconds: 20),
          kickWindow: Duration(seconds: 2),
        ),
        onLog: logs.add,
      );
      client.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);
      final connsAtPair = fake.wsConnections;

      // 桌面在 relay 侧消失但手机 WS 未收到任何通知：发 data → INTERNAL。
      fake.vanishDevice(sid);
      client.sendPayload({'zcode_type': 'probe', 'requestId': 'p1'});
      expect(
        await until(() => logs.any((l) => l.contains('relay error: INTERNAL'))),
        isTrue,
        reason: 'relay 对无对端 data 回 INTERNAL（错误帧只带 code）',
      );
      expect(await until(() => client.state == RelayState.waiting), isTrue);
      expect(fake.wsConnections, connsAtPair,
          reason: 'INTERNAL 不重建连接——保持 WS 降级 waiting 继续查询');
      expect(
        await until(
          () => failures.any((f) => f.message == '桌面端不在线'),
          timeout: const Duration(seconds: 10),
        ),
        isTrue,
      );
      expect(client.state, RelayState.waiting);

      // 桌面回来：重新配对会取消 waiting 超时。
      device = await fake.connectDevice(sid);
      addTearDown(device.close);
      expect(await until(() => client.state == RelayState.paired), isTrue);

      // 第二个 episode：paired→waiting 迁移必须复位一次性事件门。
      fake.vanishDevice(sid);
      client.sendPayload({'zcode_type': 'probe', 'requestId': 'p2'});
      expect(
        await until(
          () => failures.where((f) => f.message == '桌面端不在线').length == 2,
          timeout: const Duration(seconds: 10),
        ),
        isTrue,
        reason: '新 episode 必须重新发一次（_waitingFailureEmitted 复位）',
      );
      // waiting 内重复 INTERNAL：重武装超时但不得重复刷事件。
      client.debugHandleRelayFrame({'type': 'error', 'code': 'INTERNAL'});
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        failures.where((f) => f.message == '桌面端不在线').length,
        2,
      );
    });

    test('心跳看门狗：relay 停止应答 → 15s 语义重连，恢复应答后回到 paired', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final client = setUpClient(fake, sid);
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);
      final connectionsBefore = fake.wsConnections;

      fake.terminalAcksEnabled = false; // 停止喂狗
      expect(
        await until(
          () => fake.wsConnections > connectionsBefore,
          // 负载余量（测试稳定性根治 2026-10-29 批次）：看门狗 300ms 语义
          // 不变，满载下 2s 上限偶发不足（已知偶发家族）。
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: '看门狗（300ms 无 ACK）应触发重连',
      );
      fake.terminalAcksEnabled = true;
      expect(await until(() => client.state == RelayState.paired), isTrue);
    });

    // 电量专项（2026-10-28）：审批提醒保活退后台放宽心跳。时序注意——
    // 本用例客户端用独立 timing（后台档 600ms > 前台看门狗 300ms），
    // 若看门狗不随后台档放宽，慢心跳必被 300ms 看门狗误杀成重连风暴。
    test('后台自适应心跳：慢档不触发看门狗重连，回前台恢复快档', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final client = setUpClient(
        fake,
        sid,
        clientTiming: const RelayV2Timing(
          heartbeatBase: Duration(milliseconds: 40),
          heartbeatJitter: Duration.zero,
          heartbeatBackground: Duration(milliseconds: 600),
          ackTimeout: Duration(milliseconds: 300),
          waitingTimeout: Duration(milliseconds: 200),
          deviceOfflineGrace: Duration(milliseconds: 200),
          backoffInitial: Duration(milliseconds: 10),
          backoffMax: Duration(milliseconds: 50),
          kickFirstMin: Duration(milliseconds: 10),
          kickFirstMax: Duration(milliseconds: 20),
          kickWindow: Duration(milliseconds: 400),
        ),
      );
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);
      final connectionsAtPair = fake.wsConnections;

      // 后台档：600ms 心跳 + （修复后）900ms 看门狗——静置 1.2s 应零重连、
      // 查询节奏明显放缓（600ms 档 ≤2 次；40ms 档会是 ~30 次）。
      client.setBackgroundHeartbeat(true);
      final q0 = fake.terminalQueries;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final bgQueries = fake.terminalQueries - q0;
      expect(fake.wsConnections, connectionsAtPair,
          reason: '后台慢心跳不得被看门狗误杀成重连');
      expect(bgQueries, lessThanOrEqualTo(3),
          reason: '后台档心跳应放缓到 600ms 级');
      expect(bgQueries, greaterThanOrEqualTo(1), reason: '后台档仍在喂狗');

      // 回前台：恢复 40ms 快档——400ms 内至少 5 次查询，且零重连。
      client.setBackgroundHeartbeat(false);
      final q1 = fake.terminalQueries;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(fake.terminalQueries - q1, greaterThanOrEqualTo(5),
          reason: '回前台应恢复快档心跳');
      expect(fake.wsConnections, connectionsAtPair);
      expect(client.state, RelayState.paired);
    });

    // 电量优化批 #17（2026-10-31）：90s 断连倒计时窗口完全静默——不发
    // 心跳、不看门狗（服务器对安静客户端无超时，--heartbeat 探针 120s
    // 静默连接不断实证）。时序注意——本用例客户端前台快档 40ms 心跳 +
    // 300ms 看门狗：静默 1.2s 若看门狗未随静默停掉，必被误杀成重连。
    test('完全静默档：静默期零心跳零重连，退出恢复且连接存活', () async {
      final fake = await setUpFake();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final client = setUpClient(
        fake,
        sid,
        clientTiming: const RelayV2Timing(
          heartbeatBase: Duration(milliseconds: 40),
          heartbeatJitter: Duration.zero,
          heartbeatBackground: Duration(milliseconds: 600),
          ackTimeout: Duration(milliseconds: 300),
          waitingTimeout: Duration(milliseconds: 200),
          deviceOfflineGrace: Duration(milliseconds: 200),
          backoffInitial: Duration(milliseconds: 10),
          backoffMax: Duration(milliseconds: 50),
          kickFirstMin: Duration(milliseconds: 10),
          kickFirstMax: Duration(milliseconds: 20),
          kickWindow: Duration(milliseconds: 400),
        ),
      );
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);
      final connectionsAtPair = fake.wsConnections;

      // 静默档：1.2s 内零查询（后台慢档会是 ~2 次、前台快档 ~30 次），
      // 零重连（看门狗已停，不因无 ACK 误杀）。
      client.setRelaySilent(true);
      final q0 = fake.terminalQueries;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(fake.terminalQueries - q0, 0,
          reason: '静默档不发心跳（90s 窗口连接本就拆除，无需喂狗）');
      expect(fake.wsConnections, connectionsAtPair,
          reason: '静默档不挂看门狗，不得误杀成重连');
      expect(client.state, RelayState.paired);

      // 退出静默（回前台路径）：心跳恢复、连接存活（增量语义——静默期
      // 服务器不超时，退出无需重建）。
      client.setRelaySilent(false);
      final q1 = fake.terminalQueries;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(fake.terminalQueries - q1, greaterThanOrEqualTo(5),
          reason: '退出静默应立即恢复快档心跳');
      expect(fake.wsConnections, connectionsAtPair);
      expect(client.state, RelayState.paired);
    });

    // （三路同报）：WS 连接悬挂黑洞（TCP
    // 通、Upgrade 永不回——VPN 断隧道/DROP 型防火墙）时：
    // - connect 无 connectTimeout → socket.ready 永不落定；
    // - 握手 deadline 触发的 _reconnect() 无界 await sink.close()——适配
    //   层失败路径不给 outbound controller 挂监听者，done future 永不完成
    //   → 状态机停在 authenticating、定时器全清、poke 非 paired 早退，
    //   无任何自愈入口（内核 TCP 超时前 ~2min 死窗）。
    // 修复=connectTimeout 传 timing.ackTimeout + close fire-and-forget +
    // 接住 ready 的错误（否则成为 zone 未捕获异步错误直接判红）。
    test('连接悬挂黑洞：Upgrade 停滞在 ackTimeout 内转失败并继续退避自愈', () async {
      final fake = await setUpFake();
      fake.wsUpgradeBlackHole = true; // 接受 TCP 但永不回 101
      final sid = fake.registerDevice('jwt-alice');

      final client = setUpClient(fake, sid); // timing.ackTimeout=300ms
      client.start();
      expect(
        await until(
          () => client.state == RelayState.reconnecting,
          timeout: const Duration(seconds: 5),
        ),
        isTrue,
        reason: '悬挂 connect 应在 ackTimeout(300ms) 内转失败并进入退避重连'
            '——修复前 state 永停 authenticating（state=${client.state}）',
      );
      // 退避循环持续推进（非终态、非卡死）。
      expect(fake.log.any((l) => l.contains('black-holed')), isTrue);
    });
  });

  group('RelayClient（V1 LAN 备通道）悬挂防护', () {
    // 的 V1 变体（同病同修）：await socket.ready 无超时
    // + _connectInFlight 无 finally——悬挂时互斥永真，poke/重连定时器
    // 全被闸死，永久卡在 connecting。V1 是 pass_hash 旧档案的现行生产
    // 路径（双栈 ），非死代码。
    test('TLS 握手悬挂：wsConnectTimeout 内转瞬态退避重连', () async {
      // 黑洞服务器：接受 TCP 后完全静默（wss 的 TLS ClientHello 无应答）。
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((socket) {
        // 故意不读不写不关——连接悬挂。
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close();
      });

      final params = CompanionConnectionParams.parse(
        'https://127.0.0.1:${server.port}/remote/v4?sid=d_1&hash=hk&t=1',
      )!;
      final client = RelayClient(
        params,
        wsConnectTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(client.dispose);
      unawaited(client.start());
      expect(
        await until(
          () => client.state == RelayState.reconnecting,
          timeout: const Duration(seconds: 5),
        ),
        isTrue,
        reason: '悬挂 connect 应在 wsConnectTimeout(300ms) 内转瞬态失败'
            '进退避重连——修复前互斥卡死在 connecting（state=${client.state}）',
      );
    });
  });
}
