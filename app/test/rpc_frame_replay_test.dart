import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/crc32.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

/// 协议传输层修复批（2026-11-08）：rpc-frame 判重从「物理 seq」改为
/// 「messageSeq 已交付」——官方 replayUnacknowledged 按原物理 seq 重发
/// 未确认整批帧（webRemoteControlAcknowledgedRelayProtocol.ts:190/
/// 244-260），旧实现把物理 seq 回退一律当重复丢弃，组装缺片永远补不齐
/// →无 ack→replayGraceExceeded 断桥循环。
void main() {
  late List<Map<String, dynamic>> sent;
  late List<Uint8List> received;
  late int gaps;
  late RpcFrameTransport transport;

  setUp(() {
    sent = [];
    received = [];
    gaps = 0;
    transport = RpcFrameTransport(
      bridgeSessionId: 'b1',
      sendPayload: sent.add,
      onLog: (_) {},
    );
    transport.messages.listen(received.add);
    transport.onGapDetected = () => gaps++;
  });

  tearDown(() => transport.dispose());

  Map<String, dynamic> frame({
    required int seq,
    required int messageSeq,
    required int index,
    required int count,
    required Uint8List chunk,
    required Uint8List fullMessage,
  }) => {
    'zcode_type': 'rpc-frame',
    'bridgeSessionId': 'b1',
    'seq': seq,
    'messageSeq': messageSeq,
    'fragmentIndex': index,
    'fragmentCount': count,
    'messageBytes': fullMessage.length,
    'checksum': {'algorithm': 'crc32', 'value': Crc32.hexOf(fullMessage)},
    'dataBase64': base64.encode(chunk),
  };

  test('replay 补齐缺片：物理 seq 回退但 messageSeq 组装中→放行（修复前红）',
      () async {
    final full = Uint8List.fromList(utf8.encode('abcdefghij'));
    final part0 = Uint8List.sublistView(full, 0, 5);
    final part1 = Uint8List.sublistView(full, 5, 10);

    // 先收到 1 号分片（seq=2），0 号丢失。
    transport.acceptPayload(frame(
      seq: 2,
      messageSeq: 7,
      index: 1,
      count: 2,
      chunk: part1,
      fullMessage: full,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    // 1 号分片重复（同一物理 seq）——组装中且已收到，丢弃。
    transport.acceptPayload(frame(
      seq: 2,
      messageSeq: 7,
      index: 1,
      count: 2,
      chunk: part1,
      fullMessage: full,
    ));
    // 官方 replay 用原物理 seq 重发 0 号分片：修复前 seq<=last 直接丢，
    // 组装永不完成；修复后按 messageSeq 判重，缺片放行。
    transport.acceptPayload(frame(
      seq: 1,
      messageSeq: 7,
      index: 0,
      count: 2,
      chunk: part0,
      fullMessage: full,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1), reason: 'replay 必须补齐缺片并交付');
    expect(utf8.decode(received.single), 'abcdefghij');
    expect(
      sent.where((p) => p['zcode_type'] == 'rpc-frame-ack').length,
      1,
      reason: '交付即回 ack（ackMessageSeq 同 messageSeq）',
    );
    expect(gaps, 0, reason: '物理 seq 回退是 replay 正常形态，不得误报丢帧');
  });

  test('已完整交付过的 messageSeq 重复帧丢弃（物理 seq 重复）', () async {
    final full = Uint8List.fromList(utf8.encode('hello'));
    final f = frame(
      seq: 5,
      messageSeq: 11,
      index: 0,
      count: 1,
      chunk: full,
      fullMessage: full,
    );
    transport.acceptPayload(f);
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    transport.acceptPayload(f); // ack 丢失后的整批重放
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1), reason: '已交付消息不得二次交付');
    expect(sent.where((p) => p['zcode_type'] == 'rpc-frame-ack').length, 1);
  });

  test('正常跳号仍触发 gap 回调（物理 seq 审计不受判重改造影响）', () async {
    final a = Uint8List.fromList(utf8.encode('a'));
    final b = Uint8List.fromList(utf8.encode('b'));
    transport.acceptPayload(frame(
      seq: 10,
      messageSeq: 1,
      index: 0,
      count: 1,
      chunk: a,
      fullMessage: a,
    ));
    transport.acceptPayload(frame(
      seq: 12, // 11 丢失
      messageSeq: 2,
      index: 0,
      count: 1,
      chunk: b,
      fullMessage: b,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(gaps, 1);
    expect(received, hasLength(2));
  });
}
