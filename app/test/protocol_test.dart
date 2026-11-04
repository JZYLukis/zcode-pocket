import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/crc32.dart';
import 'package:zcode_pocket/transport/ipc_codec.dart';
import 'package:zcode_pocket/transport/proof.dart';

void main() {
  group('proof（官方测试向量，refs/ZCode packages/shared/src/web-remote-control.ts:202-217）', () {
    test('role=device 向量', () {
      expect(
        calculateProof(
          passHash: 'dGVzdF9oYXNo',
          nonce: 'nonce-1',
          role: 'device',
          deviceSid: 'device-1',
        ),
        'XK0m7u-26VS88uk7ISAX5Z_9pjzq8jqyP77N-HkCsPE',
      );
    });

    test('role=terminal 向量（跨角色防重放：同参数不同 proof）', () {
      final terminalProof = calculateProof(
        passHash: 'dGVzdF9oYXNo',
        nonce: 'nonce-1',
        role: 'terminal',
        deviceSid: 'device-1',
      );
      expect(terminalProof, 'YkqkJy-p-iZK1g1AcoGd0Q83REOggX1EygWkcxW4oLU');
    });
  });

  group('connection params（QR URL 解析）', () {
    test('合法远控 URL', () {
      final p = CompanionConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=d_abc&hash=hk&t=1760000000&mid=m1&name=MyPC&app_version=3.15.3',
      );
      expect(p, isNotNull);
      expect(p!.deviceSid, 'd_abc');
      expect(p.passHash, 'hk');
      expect(p.timestamp, 1760000000);
      expect(p.deviceMid, 'm1');
      expect(p.deviceName, 'MyPC');
      expect(p.relayWsUri.toString(), 'wss://zcode.z.ai/ws?mid=m1');
    });

    test('缺 sid/hash/t 拒绝', () {
      expect(
        CompanionConnectionParams.parse('https://zcode.z.ai/remote/v4'),
        isNull,
      );
      expect(
        CompanionConnectionParams.parse(
          'https://zcode.z.ai/remote/v4?sid=a&hash=b',
        ),
        isNull,
      );
    });

    test('http scheme 拒绝（必须 https/wss）', () {
      expect(
        CompanionConnectionParams.parse(
          'http://zcode.z.ai/remote/v4?sid=a&hash=b&t=1',
        ),
        isNull,
      );
    });
  });

  group('ipc codec（值编码回环，refs/zemote lib/protocol/ipc_codec.dart）', () {
    test('全类型回环', () {
      final w = ValueWriter();
      final value = <Object?>[
        null,
        '字符串 with 中文 and emoji 🎯',
        42,
        Uint8List.fromList([1, 2, 3, 255]),
        <Object?>['nested', 7, null],
        <String, Object?>{'k': 'v', 'n': 3, 'b': true},
      ];
      for (final v in value) {
        encodeValue(w, v);
      }
      final r = ValueReader(w.toBytes());
      expect(decodeValue(r), value[0]);
      expect(decodeValue(r), value[1]);
      expect(decodeValue(r), value[2]);
      expect(decodeValue(r), value[3]);
      expect(decodeValue(r), value[4]);
      final map = decodeValue(r) as Map;
      expect(map['k'], 'v');
      expect(map['n'], 3);
      expect(map['b'], true);
    });

    test('请求头数组编码格式 [reqType, reqId, channel, method]', () {
      final w = ValueWriter();
      encodeValue(w, [100, 7, 'zcode-agent', 'helloConversationV4']);
      encodeValue(w, <Object?>[]);
      final bytes = w.toBytes();
      final r = ValueReader(bytes);
      final header = decodeValue(r) as List;
      expect(header[0], 100);
      expect(header[1], 7);
      expect(header[2], 'zcode-agent');
      expect(header[3], 'helloConversationV4');
    });
  });

  group('crc32（rpc-frame 校验，多项式 0xedb88320）', () {
    test('已知向量', () {
      expect(Crc32.hexOf(utf8.encode('123456789')), 'cbf43926');
      expect(Crc32.hexOf(<int>[]), '00000000');
    });

    test('8 位小写 hex 输出', () {
      final hex = Crc32.hexOf(utf8.encode('zcode-protocol-v4'));
      expect(hex, matches(RegExp(r'^[0-9a-f]{8}$')));
    });
  });
}
