import 'dart:async';

import 'package:flutter/foundation.dart';

import '../transport/channel_client.dart';

/// 演示模式的脚本化通道：以最小面继承 [ChannelClient]，完全接管
/// RPC 分派（[call]）与事件监听（[addEventListener]），不触碰任何
/// 网络与帧编解码——真实 ConversationTransport 与三类订阅状态机
/// （会话/si/tasks-index）在其上原样运行。
///
/// 响应由演示脚本经 [rpcHandlers] 注入；服务端推送由 [fireEvent]
/// 模拟（订阅监听即普通回调集合）。未知方法一律回空对象兜底，
/// 与「协议按增量兼容设计：未知忽略」的容错语义一致。
class DemoChannel extends ChannelClient {
  DemoChannel() : super(sendBody: (_) {});

  /// RPC 分派表：`channel|method` → 处理器（入参=首个位置参数 Map，
  /// 返回值即 RPC 响应）。演示脚本注册；未注册的方法走空对象兜底。
  final Map<String, FutureOr<dynamic> Function(Map<String, dynamic> params)>
  rpcHandlers = {};

  /// 事件监听注册表：`channel|event` → {token: 回调}。
  /// token 唯一化以支持同一事件名多次注册/取消（重订阅在飞窗口）。
  final Map<String, Map<Object, void Function(dynamic event)>> _eventListeners =
      {};

  /// 经过本通道的全部调用（channel|method 计数诊断用）。
  final List<String> callLog = [];

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    callLog.add('$channel|$method');
    assert(() {
      debugPrint('[demo-channel] $channel|$method');
      return true;
    }());
    final params = args.isNotEmpty && args.first is Map
        ? (args.first as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final handler = rpcHandlers['$channel|$method'];
    if (handler == null) {
      return <String, dynamic>{};
    }
    return handler(params);
  }

  @override
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    final key = '$channel|$event';
    final token = Object();
    final set = _eventListeners.putIfAbsent(key, () => {});
    set[token] = onEvent;
    return () {
      set.remove(token);
      if (set.isEmpty) _eventListeners.remove(key);
    };
  }

  /// 模拟服务端推送：向 `channel|event` 的全部监听投递 [payload]。
  void fireEvent(String channel, String event, Object? payload) {
    final set = _eventListeners['$channel|$event'];
    if (set == null) return;
    for (final cb in List.of(set.values)) {
      cb(payload);
    }
  }

  /// 是否仍有活跃监听（脚本侧判断「订阅还在不在」）。
  bool hasListeners(String channel, String event) =>
      _eventListeners.containsKey('$channel|$event');
}
