import '../transport/connection_params.dart';

/// 连接档案：一条远控凭据 = 一台桌面。
sealed class ConnectionProfile {
  const ConnectionProfile();
}

/// 设备档案公共面（ 双栈）：V1（扫码 URL）与 V2（账号+设备 sid）
/// 共用 deviceSid 唯一键、标签/失效标记/工作区恢复字段——栈注册表
/// （deviceSid→ComputerStack）与 UI 列表对栈版本无感。
abstract class DeviceProfile extends ConnectionProfile {
  const DeviceProfile();

  String get deviceSid;
  String get label;
  DateTime get addedAt;
  bool get invalid;
  String? get lastWorkspaceKey;
  DeviceProfile copyWith({
    String? label,
    bool? invalid,
    String? lastWorkspaceKey,
  });
}

/// 中继档案（扫码/粘贴远控 URL 获得）。
class RelayProfile extends DeviceProfile {
  final CompanionConnectionParams params;

  @override
  String get deviceSid => params.deviceSid;

  @override
  final String label; // 桌面备注名（默认取 QR name 参数）
  @override
  final DateTime addedAt;

  /// 凭据失效标记（桌面刷新二维码后旧 URL 报会话不存在/过期，
  /// 捕获后置位并引导重扫；重新添加同 sid 档案时清除）。
  @override
  final bool invalid;

  /// 上次使用的工作区（账号数据按档案隔离——重连后恢复现场）。
  @override
  final String? lastWorkspaceKey;

  const RelayProfile({
    required this.params,
    required this.label,
    required this.addedAt,
    this.invalid = false,
    this.lastWorkspaceKey,
  });

  @override
  RelayProfile copyWith({
    String? label,
    bool? invalid,
    String? lastWorkspaceKey,
  }) => RelayProfile(
    params: params,
    label: label ?? this.label,
    addedAt: addedAt,
    invalid: invalid ?? this.invalid,
    lastWorkspaceKey: lastWorkspaceKey ?? this.lastWorkspaceKey,
  );
}

/// V2 账号档案：凭据核心=账号登录（多账号批 2026-10-25 起
/// AccountStore 支持多账号并存，档案经 [accountId] 绑定所属账号；null=
/// 尚未迁移/新建未绑定——连接时退最近使用账号）。档案只记目标桌面设备
/// （sid/mid/name）——官方 3.16 二维码形态。
class AccountV2Profile extends DeviceProfile {
  @override
  final String deviceSid;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;

  /// 所属账号 id（account_store.deriveAccountId 口径）。
  final String? accountId;

  @override
  final String label;
  @override
  final DateTime addedAt;

  /// 失效标记（V2 下常见=auth-required 后用户确认重登/删除档案）。
  @override
  final bool invalid;

  @override
  final String? lastWorkspaceKey;

  const AccountV2Profile({
    required this.deviceSid,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    this.accountId,
    required this.label,
    required this.addedAt,
    this.invalid = false,
    this.lastWorkspaceKey,
  });

  @override
  AccountV2Profile copyWith({
    String? label,
    bool? invalid,
    String? lastWorkspaceKey,
    String? accountId,
  }) => AccountV2Profile(
    deviceSid: deviceSid,
    deviceMid: deviceMid,
    deviceName: deviceName,
    appVersion: appVersion,
    accountId: accountId ?? this.accountId,
    label: label ?? this.label,
    addedAt: addedAt,
    invalid: invalid ?? this.invalid,
    lastWorkspaceKey: lastWorkspaceKey ?? this.lastWorkspaceKey,
  );
}

/// 局域网档案（zcode --web 备用通道，阶段 1 实装）。
class LanProfile extends ConnectionProfile {
  final Uri baseUrl; // http(s)://host:3030
  final String? token;

  const LanProfile({required this.baseUrl, this.token});
}

// 阶段 0 骨架遗存的
// TransportPhase/ZTransport/RelayTransport 全仓库零引用（且内含未经
// 检验的缺陷——attachWorkspace 的监听订阅不保存、_bridge 覆盖不
// dispose），已删除。本文件仅保留连接/设备
// 档案数据类。
