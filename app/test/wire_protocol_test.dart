import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

/// ：本周新增协议调用的 wire 信封钉死——
/// workflow 四方法与 compact 命令信封此前只有
/// AppState 层 override 测试（夹具不经信封层），参数名/形状 typo 全绿
/// （审查 D5a/D5b 双向确认）。本组用假通道直钉 method 名+args 形状。
class _WireChannel extends ChannelClient {
  _WireChannel() : super(sendBody: (_) {});
  final calls = <(String, Map<String, dynamic>)>[];

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((
      method,
      args.isEmpty
          ? const <String, dynamic>{}
          : (args.first as Map).cast<String, dynamic>(),
    ));
    switch (method) {
      case 'readWorkspacePresentation':
        return {'mode': 'build', 'slashCommands': const <dynamic>[]};
      case 'handshakeV4':
        return {'ok': true};
      case 'conversationWorkflowRunsV4':
        // 官方 v4ConversationWorkflowRunSummarySchema（transport.ts
        // 706-749，.strict()）：**没有** lastEventSequence——那是快照
        // workflowRuns 投影的字段（workflow-runs.ts:581）。
        return {
          'runs': [
            {
              'runId': 'run-1',
              'toolCallId': 'tc-1',
              'label': '每日简报',
              'updatedAt': 1700000000000,
              'status': 'completed',
              'resumable': false,
            },
            // lineage/失败面全字段形态（有条件在场，老 CLI 不发）。
            {
              'runId': 'run-2',
              'status': 'stopped',
              'stopReason': 'superseded',
              'resumedFrom': 'run-1',
              'supersededBy': 'run-3',
              'failureCode': 'Interrupted',
              'failureMessage': '用户中断',
              'resumable': true,
            },
          ],
        };
      case 'conversationWorkflowRunEventsV4':
        return {'events': const [], 'hasMore': false};
      case 'conversationWorkflowRunArtifactsV4':
        return {
          'artifacts': [
            {'id': 'a1', 'kind': 'file', 'version': 2},
          ],
        };
      case 'conversationWorkflowRunArtifactDataV4':
        return {'items': const [], 'hasMore': false};
      case 'conversationWorkflowRunArtifactReadV4':
        return {
          'dataBase64': '',
          'mediaType': 'text/plain',
          'totalBytes': 0,
          'nextOffset': null,
        };
      default:
        return <String, dynamic>{};
    }
  }
}

class _WireBridge implements BridgeSession {
  _WireBridge(this.channel);
  final _WireChannel channel;

  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-wire';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

void main() {
  late _WireChannel channel;
  late ConversationTransport conv;

  setUp(() {
    channel = _WireChannel();
    conv = ConversationTransport(
      session: _WireBridge(channel),
      scope: const {'workspacePath': r'C:\demo'},
    );
  });

  /// 快照 workflowRuns 投影里该 run 的 lastEventSequence（目录查询没有
  /// 该字段，详情页「最新一页」反推=投影值-页大小）。
  const projectionLastEventSequence = 1200;

  test('workflow 五方法：method 名 + scope 平铺 + 可选参数缺省省略', () async {
    await conv.workflowRuns('s-1');
    await conv.workflowRunEvents('s-1', 'run-1');
    await conv.workflowRunEvents(
      's-1',
      'run-1',
      afterSequence: projectionLastEventSequence - 500,
    );
    await conv.workflowRunArtifacts('s-1', 'run-1');
    await conv.workflowRunArtifactData('s-1', 'run-1', 'a1');
    await conv.workflowRunArtifactData(
      's-1',
      'run-1',
      'a1',
      afterSequence: 7,
      limit: 200,
    );
    await conv.workflowRunArtifactRead(
      's-1',
      'run-1',
      'a1',
      version: 2,
      offset: 0,
      limit: 512 * 1024,
    );

    final byMethod = <String, Map<String, dynamic>>{
      for (final (m, a) in channel.calls) m: a,
    };
    expect(
      byMethod.keys,
      containsAll([
        'conversationWorkflowRunsV4',
        'conversationWorkflowRunEventsV4',
        'conversationWorkflowRunArtifactsV4',
        'conversationWorkflowRunArtifactDataV4',
        'conversationWorkflowRunArtifactReadV4',
      ]),
      reason: 'wire 方法名 typo=全套门全绿只能真机发现（审查 D5 实锤）',
    );
    // scope 平铺在参数顶层（官方 {...workspace, ...} 同构）。
    expect(byMethod['conversationWorkflowRunsV4']!['workspacePath'], r'C:\demo');
    expect(byMethod['conversationWorkflowRunsV4']!['sessionId'], 's-1');
    expect(
      byMethod['conversationWorkflowRunsV4']!.containsKey('limit'),
      isFalse,
      reason: '可选参数缺省必须省略（官方 strict/最小化语义）',
    );
    // afterSequence 缺省=从头取（官方语义）——不传时不带键；有投影序号
    // 时=投影值-500 反推最新页。
    final eventsCalls = channel.calls
        .where((c) => c.$1 == 'conversationWorkflowRunEventsV4')
        .toList();
    expect(eventsCalls.first.$2.containsKey('afterSequence'), isFalse);
    expect(eventsCalls[1].$2['afterSequence'], projectionLastEventSequence - 500,
        reason: '最新页反推（run lastEventSequence-500）经此参数到达');
    // workflowRunArtifactData：sessionId/runId/artifactId 三参必带，
    // afterSequence/limit 缺省省略（官方 strict 语义）。
    final dataCalls = channel.calls
        .where((c) => c.$1 == 'conversationWorkflowRunArtifactDataV4')
        .toList();
    expect(dataCalls, hasLength(2));
    expect(dataCalls.first.$2['sessionId'], 's-1');
    expect(dataCalls.first.$2['runId'], 'run-1');
    expect(dataCalls.first.$2['artifactId'], 'a1');
    expect(dataCalls.first.$2.containsKey('afterSequence'), isFalse,
        reason: '缺省=从头取（官方同语义，不带键）');
    expect(dataCalls.first.$2.containsKey('limit'), isFalse);
    expect(dataCalls[1].$2['afterSequence'], 7);
    expect(dataCalls[1].$2['limit'], 200);
    final read = byMethod['conversationWorkflowRunArtifactReadV4']!;
    expect(read['artifactId'], 'a1');
    expect(read['version'], 2);
    expect(read['offset'], 0);
    expect(read['limit'], 512 * 1024,
        reason: '分块上限=官方 attachmentChunkMaxBytes');
  });

  test('compact 命令信封：空载荷 + 全字段', () async {
    await conv.sendCompact('s-1');
    final sent = channel.calls
        .firstWhere((c) => c.$1 == 'sendConversationCommandV4')
        .$2;
    final compact = (sent['envelope'] as Map).cast<String, dynamic>();
    // sendCompact → sendCommand('compact', {})：payload 恒空对象。
    expect(compact['payload'], isEmpty);
    expect(compact['type'], 'compact');
    expect(compact['commandId'], isNotEmpty);
    expect(compact['sessionId'], 's-1');
    expect(compact['issuedAt'], isPositive);
    expect(sent['workspacePath'], r'C:\demo',
        reason: 'scope 平铺在 params 顶层（官方 commandParams 同构）');
    // 官方 3.17 给 compact 加了可选 modelSelection——{} 仍合法（对照
    // refs/snapshot-3171 command.ts:169）。
  });

  test('cancelBackgroundWork 命令信封：workId 载荷（B 批 2026-11-08）',
      () async {
    await conv.cancelBackgroundWork('s-1', 'w-9');
    final sent = channel.calls
        .firstWhere((c) => c.$1 == 'sendConversationCommandV4')
        .$2;
    final cmd = (sent['envelope'] as Map).cast<String, dynamic>();
    expect(cmd['type'], 'cancelBackgroundWork');
    expect(cmd['payload'], {'workId': 'w-9'}, reason: '官方 command.ts:269');
    expect(cmd['sessionId'], 's-1');
    expect(cmd['commandId'], isNotEmpty);
  });

  test('sendText 重放沿用钉住的 commandId（队列双发红线）', () async {
    await conv.sendText('s-1', 'hi', replayCommandId: 'pinned-id');
    Map<String, dynamic> lastEnvelope() => (channel.calls
            .lastWhere((c) => c.$1 == 'sendConversationCommandV4')
            .$2['envelope'] as Map)
        .cast<String, dynamic>();
    final env = lastEnvelope();
    expect(env['type'], 'sendText');
    expect(env['commandId'], 'pinned-id',
        reason: '离线队列崩溃窗口重放必须同 ID（服务端幂等去重）');
    await conv.sendText('s-1', 'fresh');
    expect(lastEnvelope()['commandId'], isNot('pinned-id'),
        reason: '正常发送照常生成新 ID');
  });
}
