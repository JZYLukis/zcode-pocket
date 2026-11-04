import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/ipc_codec.dart';

Uint8List _frame(List<Object?> header, [Object? data]) {
  final writer = ValueWriter();
  encodeValue(writer, header);
  if (data != null || header[0] != ChannelClient.resInitialize) {
    encodeValue(writer, data);
  }
  return writer.toBytes();
}

void main() {
  test('解码上限单一真源：16-64MiB 值合法解码（开源审查 G2 P2-3/G3 P2-4）', () async {
    // rpc-frame 重组层允许 ≤64MiB 的逻辑消息——解码层旧上限 16MiB 使
    // 16-64MiB 消息在重组成功后被静默丢弃（issue #9"大快照=永久
    // spinner"在上一层复活）。两层上限统一后 17MiB 必须可解码。
    final big = Uint8List(17 * 1024 * 1024);
    final writer = ValueWriter();
    encodeValue(writer, big);
    final decoded = decodeValue(ValueReader(writer.toBytes()));
    expect(decoded is Uint8List && decoded.length == big.length, isTrue);
    // 超过 64MiB 仍拒绝（上限是安全护栏，不是取消）。
    final huge = Uint8List(ValueReader.maxValueBytes + 1);
    final w2 = ValueWriter();
    encodeValue(w2, huge);
    expect(
      () => decodeValue(ValueReader(w2.toBytes())),
      throwsFormatException,
    );
  });

  test('载荷解码失败：在途 call 立即失败而非静默等 timeout（开源审查 G2 P2-3/G3 P2-4）', () async {
    final client = ChannelClient(sendBody: (_) {});
    client.handleMessage(_frame([ChannelClient.resInitialize]));
    await client.ready;

    final rpc = client.call('zcode-agent', 'subscribeConversationV4', const []);
    await Future<void>.delayed(Duration.zero); // id=0 已登记
    final rpcFailure = expectLater(
      rpc,
      throwsA(
        isA<ChannelRpcError>().having(
          (e) => e.message,
          'message',
          contains('response frame lost'),
        ),
      ),
    );

    // header 合法（resPromiseSuccess, id=0）+ 载荷超限（>64MiB bytes）——
    // 旧实现只打一行日志，在途 call 只能干等 30s timeout。
    client.handleMessage(
      _frame(
        [ChannelClient.resPromiseSuccess, 0],
        Uint8List(ValueReader.maxValueBytes + 1),
      ),
    );
    await rpcFailure;
    client.dispose();
  });

  test('SEQ GAP 只失败在途 RPC，持久 event listener 继续接收后续事件', () async {
    final client = ChannelClient(sendBody: (_) {});
    client.handleMessage(_frame([ChannelClient.resInitialize]));
    await client.ready;

    final rpc = client.call('zcode-task', 'listTaskList', const []);
    await Future<void>.delayed(Duration.zero); // RPC 先登记 id=0，监听随后 id=1。
    final events = <dynamic>[];
    final cancel = client.addEventListener(
      'window-controller',
      'onTasksIndexChanged',
      events.add,
    );
    await Future<void>.delayed(Duration.zero);
    final rpcFailure = expectLater(
      rpc,
      throwsA(
        isA<ChannelRpcError>().having(
          (e) => e.message,
          'message',
          contains('response frame lost'),
        ),
      ),
    );

    client.failPendingOnGap();
    await rpcFailure;
    client.handleMessage(
      _frame([ChannelClient.resEventFire, 1], {
        'kind': 'snapshot',
        'tasks': <Object?>[],
      }),
    );

    expect(events, hasLength(1), reason: '持久监听不属于在途 RPC，不得随丢帧清除');
    cancel();
    client.handleMessage(_frame([ChannelClient.resEventFire, 1], {'late': true}));
    expect(events, hasLength(1), reason: '显式 cancel 仍须完整移除监听');
    client.dispose();
  });
}
