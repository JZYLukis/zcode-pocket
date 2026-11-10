import 'dart:async';

import 'package:flutter/foundation.dart';

import '../transport/channel_client.dart';
import '../transport/companion_client.dart';
import '../transport/conversation.dart';
import '../transport/rpc_frame_transport.dart';
import 'demo_channel.dart';

/// 演示模式的假桥：实现 [BridgeSession] 全公开面，`channels` 返回
/// 脚本化的 [DemoChannel]，`conversation()` 返回**真实的**
/// [ConversationTransport]（按 scope 键缓存，与生产桥同语义）——
/// 会话/si/tasks-index 的订阅状态机、看门狗、CAS 水位全部原样运行。
class DemoBridge implements BridgeSession {
  DemoBridge({Map<String, dynamic>? bridgeInfo})
    : _bridgeInfo =
          bridgeInfo ??
          const {
            'bridgeSessionId': 'demo-bridge',
            'workspaceKey': 'demo-key',
            'workspacePath': 'G:/demo/pocket-demo',
            'workspaceIdentity': 'demo-ws',
            'kind': 'workspace',
          };

  final Map<String, dynamic> _bridgeInfo;
  final DemoChannel channel = DemoChannel();

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);

  final Map<String, ConversationTransport> _conversations = {};
  bool _disposed = false;

  @override
  Map<String, dynamic>? get projectIntent => null;

  @override
  Map<String, dynamic>? get taskIntent => null;

  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (_disposed) throw StateError('demo bridge disposed');
  }

  @override
  Map<String, dynamic> get bridge => _bridgeInfo;

  /// 演示模式无 relay 物理帧层；全仓无桥外消费者，不可达即抛。
  @override
  RpcFrameTransport get transport => throw UnimplementedError();

  @override
  ChannelClient get channels => channel;

  @override
  String? get workspaceKey => _bridgeInfo['workspaceKey'] as String?;

  @override
  String? get initialTaskId => _bridgeInfo['initialTaskId'] as String?;

  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) {
    final key = '${scope['workspaceIdentity'] ?? scope['workspacePath']}';
    return _conversations.putIfAbsent(
      key,
      () => ConversationTransport(session: this, scope: scope, onLog: onLog),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // ConversationTransport 自身无 dispose 面；其订阅由各注册表收口。
    channel.dispose();
    degraded.dispose();
    recovered.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
