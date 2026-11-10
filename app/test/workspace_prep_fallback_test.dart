import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

/// H08-8A 红绿（2026-10-29 批次）：zcode-task.prepareWorkspace（zemote
/// 遗产，官方快照零命中）兜底退役——readWorkspacePresentation 失败时
/// 走重试+缓存回落，不再回退自创 RPC。修复前红：旧兜底应答使调用
/// 成功且 legacy RPC 被调用。

class _PrepChannel extends ChannelClient {
  _PrepChannel() : super(sendBody: (_) {});
  int legacyCalls = 0;

  /// 'throw'=readWorkspacePresentation 抛错；'malformed'=返回非 Map。
  String behavior = 'throw';

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (method == 'readWorkspacePresentation') {
      if (behavior == 'malformed') return 'not-a-map';
      throw Exception('method not found');
    }
    if (method == 'prepareWorkspace') {
      legacyCalls++;
      return {
        'configOptions': <dynamic>[],
        'slashCommands': <dynamic>[],
      };
    }
    return <String, dynamic>{};
  }
}

class _PrepBridge implements BridgeSession {
  final _PrepChannel channel = _PrepChannel();
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-prep';
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
  test('readWorkspacePresentation 失败不再回退旧 prepareWorkspace RPC', () async {
    final bridge = _PrepBridge();
    final conv = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': r'C:\demo'},
    );

    await expectLater(
      conv.prepareWorkspace(),
      throwsStateError,
      reason: '官方路径失败应显式失败（重试后抛），由调用方缓存回落兜住',
    );
    expect(
      bridge.channel.legacyCalls,
      0,
      reason: 'H08-8A：zemote 遗产 zcode-task.prepareWorkspace 不得再被调用',
    );
  });

  test('readWorkspacePresentation 非法载荷按失败处理（不吞成空目录）', () async {
    final bridge = _PrepBridge();
    bridge.channel.behavior = 'malformed';
    final conv = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': r'C:\demo'},
    );

    await expectLater(
      conv.prepareWorkspace(),
      throwsStateError,
      reason: '非 Map 载荷必须按失败处理（旧实现会静默落入空目录路径）',
    );
  });
}
