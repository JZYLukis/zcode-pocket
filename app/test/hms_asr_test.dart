import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/hms_asr.dart';

/// HMS 语音通道客户端（companion/hms_asr，结构性剥离 2026-10-29 批次）：
/// 协议映射矩阵——与 system_asr_test 同构的端到端桩测试（原生事件经
/// mock handler 回推）+ 默认构建误开（插件缺席）不悬挂。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    HmsAsr.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('companion/hms_asr'), null);
  });

  test('probe：原生在包返回 true（私包）', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/hms_asr'),
      (call) async => true,
    );
    expect(await HmsAsr.probe(), isTrue);
    expect(HmsAsr.available, isTrue);
  });

  test('probe：默认构建（MissingPluginException）安全回落 false', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/hms_asr'),
      (call) async => throw MissingPluginException('default build'),
    );
    expect(await HmsAsr.probe(), isFalse);
  });

  test('会话协议：prepare(apiKey)→start→partial…→final 收尾', () async {
    final calls = <MethodCall>[];
    final completer = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/hms_asr'),
      (call) async {
        calls.add(call);
        if (call.method == 'start') {
          // 原生侧事件回推（模拟 MLAsrListener：partial×2 → final）。
          completer.complete();
        }
        return null;
      },
    );

    final partials = <String>[];
    final finals = <String>[];
    final errors = <(int, String)>[];
    final session = HmsAsr.start(
      apiKey: 'agc-key-test',
      onPartial: partials.add,
      onFinal: (t) {
        finals.add(t);
      },
      onError: (c, m) => errors.add((c, m)),
    );
    await completer.future;
    // prepare 先于 start，且 API Key 随 prepare 注入。
    expect(calls.map((c) => c.method), ['prepare', 'start']);
    expect(calls.first.arguments, {'apiKey': 'agc-key-test'});

    // 回推事件：partial 不收尾、final 收尾。
    Future<void> push(Map<String, dynamic> payload) => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'companion/hms_asr',
          const MethodChannel('companion/hms_asr')
              .codec
              .encodeMethodCall(MethodCall('event', payload)),
          (data) {},
        );
    await push({'type': 'partial', 'text': '你好'});
    await push({'type': 'partial', 'text': '你好世界'});
    await push({'type': 'final', 'text': '你好世界。'});
    expect(partials, ['你好', '你好世界']);
    expect(finals, ['你好世界。']);
    expect(errors, isEmpty);

    await session.cancel();
    expect(calls.map((c) => c.method), contains('cancel'));
  });

  test('会话协议：error 收尾且携带 code/message', () async {
    final errors = <(int, String)>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/hms_asr'),
      (call) async => null,
    );
    final session = HmsAsr.start(
      onPartial: (_) {},
      onFinal: (_) {},
      onError: (c, m) => errors.add((c, m)),
    );
    await Future<void>.delayed(Duration.zero);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'companion/hms_asr',
          const MethodChannel('companion/hms_asr')
              .codec
              .encodeMethodCall(
                MethodCall('event', {'type': 'error', 'code': 11203, 'message': 'service unavailable'}),
              ),
          (data) {},
        );
    expect(errors, [(11203, 'service unavailable')]);
    session.cancel();
  });

  test('默认构建误开（无原生 handler）：start 即明确报错不悬挂', () async {
    final errors = <(int, String)>[];
    // 不挂 mock handler → invokeMethod 抛 MissingPluginException。
    final session = HmsAsr.start(
      onPartial: (_) {},
      onFinal: (_) {},
      onError: (c, m) => errors.add((c, m)),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(errors, isNotEmpty,
        reason: '原生缺席（默认构建误开 VOICE_HMS）必须立即报错走失败分支');
    expect(errors.first.$1, -1);
    await session.cancel();
  });

  test('空 partial 不回调（对齐系统通道噪音过滤）', () async {
    final partials = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/hms_asr'),
      (call) async => null,
    );
    final session = HmsAsr.start(
      onPartial: partials.add,
      onFinal: (_) {},
      onError: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'companion/hms_asr',
          const MethodChannel('companion/hms_asr')
              .codec
              .encodeMethodCall(
                const MethodCall('event', {'type': 'partial', 'text': ''}),
              ),
          (data) {},
        );
    expect(partials, isEmpty, reason: '空串 partial 不得触发 UI 状态翻转');
    session.cancel();
  });

}
