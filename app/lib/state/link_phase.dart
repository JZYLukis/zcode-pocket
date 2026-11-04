/// 连接状态（UI 视角），由 relay 状态机 + 失败信号派生。
enum LinkPhase {
  /// 无活跃档案（首次使用 / 已全部移除）。
  offline,

  connecting,
  waitingDesktop,
  online,
  reconnecting,

  /// 被其他手机页接管（协议每桌面会话仅一个 terminal，protocol-notes §1.4）。
  kicked,

  /// 凭据失效（桌面刷新了二维码，旧 URL 作废）→ 引导重扫。
  invalid,

  error,
}
