/// createSession 已接受并分配 id，但栈内预订阅失败。调用方必须保留 id 并
/// 走自己的重订阅/错误路径，不能退回草稿再次 createSession 形成重复首发。
class SessionCreatedSubscriptionError implements Exception {
  final String sessionId;
  final Object error;
  const SessionCreatedSubscriptionError(this.sessionId, this.error);

  @override
  String toString() => 'session created; subscription failed: $error';
}

/// 会话注册在 demote/close 清场窗口内被作废（注册代际/transport 身份/
/// `_closing` 任一命中）。ComputerStack 包装层按本类型识别「等清场后
/// 重试一次」的自愈路径（开源审查 I1 P3-7/I3 P3-2：此前靠错误文案子串
/// 匹配，文案一旦改动/本地化即静默退化为直接抛给页面）。
///
/// 继承 StateError：注册表既有测试与调用方的 `on StateError` 处置继续
/// 生效；toString 保持人话文案——UI 层的 contains 匹配
/// （conversation_page）继续生效。
class SessionSubscriptionResetError extends StateError {
  SessionSubscriptionResetError()
    : super('会话订阅已重置（正在切换电脑或工作区），请重试');
}
