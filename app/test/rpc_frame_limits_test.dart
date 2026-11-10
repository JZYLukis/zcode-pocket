import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/crc32.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

/// rpc-frame 收/发两侧限额分离 + 入站装配
/// 资源闸。发送侧收紧到官方限额（16MiB/64 分片——官方接收端超限整条
/// 丢弃，发出去也永远无 ack）；接收侧维持 zemote 宽容值（64MiB/256），
/// 但补上官方 logicalFrameAssembly 语义的资源闸（并发装配数 + 暂存字节
/// 总量，超限逐出最老装配）与单分片解码上限（合规对端解码分片
/// ≤~768KiB，超 1MiB 即非合规，丢弃）。
/// 红绿：发送超 16MiB 拒绝、超 1MiB 单分片丢弃、并发/暂存逐出在旧实现
/// （64MiB 发送上限、无资源闸）下均不成立。
void main() {
  late List<Map<String, dynamic>> sent;
  late List<Uint8List> received;
  late List<String> logs;
  late RpcFrameTransport transport;

  RpcFrameTransport makeTransport({
    int? maxConcurrent,
    int? maxStaged,
  }) => RpcFrameTransport(
    bridgeSessionId: 'b1',
    sendPayload: sent.add,
    onLog: logs.add,
    maxConcurrentAssemblies: maxConcurrent ?? 32,
    maxStagedAssemblyBytes: maxStaged ?? RpcFrameTransport.maxMessageBytes + 16 * 1024 * 1024,
  );

  setUp(() {
    sent = [];
    received = [];
    logs = [];
    transport = makeTransport();
    transport.messages.listen(received.add);
  });

  tearDown(() => transport.dispose());

  Map<String, dynamic> frame({
    required int seq,
    required int messageSeq,
    required int index,
    required int count,
    required int messageBytes,
    required String checksum,
    required Uint8List chunk,
  }) => {
    'zcode_type': 'rpc-frame',
    'bridgeSessionId': 'b1',
    'seq': seq,
    'messageSeq': messageSeq,
    'fragmentIndex': index,
    'fragmentCount': count,
    'messageBytes': messageBytes,
    'checksum': {'algorithm': 'crc32', 'value': checksum},
    'dataBase64': base64.encode(chunk),
  };

  group('发送侧官方限额（16MiB / 64 分片）', () {
    test('超过 16MiB 拒绝（旧实现 64MiB 上限下可发=修复前红）', () {
      final bytes = Uint8List(RpcFrameTransport.sendMaxMessageBytes + 1);
      expect(
        () => transport.sendMessage(bytes),
        throwsStateError,
      );
      expect(sent, isEmpty, reason: '拒绝时一个物理帧都不得发出');
    });

    test('恰 16MiB 不误伤：32 分片全部发出', () {
      final bytes = Uint8List(RpcFrameTransport.sendMaxMessageBytes);
      transport.sendMessage(bytes);
      final frames =
          sent.where((p) => p['zcode_type'] == 'rpc-frame').toList();
      expect(frames, hasLength(32));
      expect(frames.last['fragmentCount'], 32);
    });
  });

  group('接收侧单分片解码上限', () {
    test('解码后 >1MiB 的分片丢弃且不建装配', () async {
      final big = Uint8List(RpcFrameTransport.maxPhysicalFrameBytes + 1);
      transport.acceptPayload(frame(
        seq: 1,
        messageSeq: 7,
        index: 0,
        count: 2,
        messageBytes: 8 * 1024 * 1024,
        checksum: 'deadbeef',
        chunk: big,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      expect(
        logs.any((l) => l.contains('dropped oversized fragment')),
        isTrue,
        reason: '超物理帧预算的解码分片必须留痕丢弃',
      );
      // 后到的合法分片只能开一个新装配（缺 0 号片），不得凭空完成交付。
      transport.acceptPayload(frame(
        seq: 2,
        messageSeq: 7,
        index: 1,
        count: 2,
        messageBytes: 8 * 1024 * 1024,
        checksum: 'deadbeef',
        chunk: Uint8List.fromList(utf8.encode('tail')),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty, reason: '半条消息不得交付');
    });
  });

  group('入站装配资源闸', () {
    test('并发装配超上限：新消息入场逐出最老装配', () async {
      transport.dispose();
      transport = makeTransport(maxConcurrent: 3);
      transport.messages.listen(received.add);

      Uint8List part(String s) => Uint8List.fromList(utf8.encode(s));
      String crcOf(int i) => Crc32.hexOf(part('head${i}tail$i'));
      // 三个两分片消息各到 0 号片 → 三个装配驻留。
      for (var i = 0; i < 3; i++) {
        transport.acceptPayload(frame(
          seq: i + 1,
          messageSeq: 101 + i,
          index: 0,
          count: 2,
          messageBytes: 10,
          checksum: crcOf(i),
          chunk: part('head$i'),
        ));
      }
      // 第 4 个新消息入场 → 最老（101）被逐出。
      transport.acceptPayload(frame(
        seq: 4,
        messageSeq: 104,
        index: 0,
        count: 2,
        messageBytes: 10,
        checksum: crcOf(4),
        chunk: part('head4'),
      ));
      expect(
        logs.any((l) => l.contains('evicted assembly 101')),
        isTrue,
        reason: '资源闸必须逐出最老装配并留痕',
      );
      // 被逐出的 101 补片 → 只能重开新装配，不得交付。
      transport.acceptPayload(frame(
        seq: 5,
        messageSeq: 101,
        index: 1,
        count: 2,
        messageBytes: 10,
        checksum: crcOf(0),
        chunk: part('tail0'),
      ));
      // 104 补齐 → 正常交付。
      transport.acceptPayload(frame(
        seq: 6,
        messageSeq: 104,
        index: 1,
        count: 2,
        messageBytes: 10,
        checksum: crcOf(4),
        chunk: part('tail4'),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1), reason: '只有 104 完整交付');
      expect(utf8.decode(received.single), 'head4tail4');
    });

    test('暂存字节超上限：新消息入场逐出最老装配', () async {
      transport.dispose();
      transport = makeTransport(maxStaged: 1024);

      Uint8List blob(int n) => Uint8List(n);
      // 两个 600B 分片驻留 → 1200B ≥ 1024B，第三个新消息入场触发逐出。
      transport.acceptPayload(frame(
        seq: 1,
        messageSeq: 201,
        index: 0,
        count: 2,
        messageBytes: 2048,
        checksum: 'a',
        chunk: blob(600),
      ));
      transport.acceptPayload(frame(
        seq: 2,
        messageSeq: 202,
        index: 0,
        count: 2,
        messageBytes: 2048,
        checksum: 'b',
        chunk: blob(600),
      ));
      transport.acceptPayload(frame(
        seq: 3,
        messageSeq: 203,
        index: 0,
        count: 2,
        messageBytes: 2048,
        checksum: 'c',
        chunk: blob(600),
      ));
      expect(
        logs.any((l) => l.contains('evicted assembly 201')),
        isTrue,
        reason: '暂存字节闸必须逐出最老装配',
      );
    });

    test('完成交付后暂存归零：不挤压后续装配', () async {
      transport.dispose();
      transport = makeTransport(maxStaged: 512);
      transport.messages.listen(received.add);

      final full = Uint8List.fromList(utf8.encode('0123456789abcdef'));
      final c = Crc32.hexOf(full);
      transport.acceptPayload(frame(
        seq: 1,
        messageSeq: 1,
        index: 0,
        count: 2,
        messageBytes: full.length,
        checksum: c,
        chunk: Uint8List.sublistView(full, 0, 8),
      ));
      transport.acceptPayload(frame(
        seq: 2,
        messageSeq: 1,
        index: 1,
        count: 2,
        messageBytes: full.length,
        checksum: c,
        chunk: Uint8List.sublistView(full, 8, 16),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(logs.any((l) => l.contains('evicted')), isFalse,
          reason: '正常小消息不得触发资源闸');
    });
  });
}
