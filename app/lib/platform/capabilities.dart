// 平台能力矩阵（ios-adaptation-1 平台缝）。
//
// 职责：把「某能力在当前平台是否可用」收敛为单一判定点——UI/启动逻辑
// 消费 capability，而不是在各页面散落 Platform.isIOS。iOS 适配各批
// （D-H）落地 Swift 实现时逐项翻 true；未实现前 UI 隐藏/降级，不出现
// 「开关在、点了永远失败」的假功能（项目红线：UI 不撒谎）。
//
// 判定基准 = defaultTargetPlatform（非 dart:io Platform）：
// - 生产 Android/iOS 与框架目标平台一致；
// - widget 测试默认 android → 既有 Android 断言零适配（本批红线：
//   Android 零视觉变化，基线零重定）；
// - iOS 分支用例用 debugDefaultTargetPlatformOverride 覆写模拟，
//   无需本类自造测试缝（framework 自带）。
//
// 各能力的 iOS 计划见 docs/ios-adaptation-plan.md 批次表；结构性不可行
// 项（自更新/OEM 引导/FLAG_SECURE）永不翻转，注释里写明原因防后人
// 「顺手翻 true」。
import 'package:flutter/foundation.dart';

/// 平台能力只读判定。Android 当前全 true（零回归起点）。
abstract final class ZpCapabilities {
  static bool get _android => defaultTargetPlatform == TargetPlatform.android;

  /// 应用内自更新（下载安装包并调起安装器）。iOS 无侧载安装且 App
  /// Store 政策禁止下载可执行代码——结构性不可行，永不翻 true；
  /// iOS 更新走 TestFlight/App Store。消费点：settings 更新两行、
  /// app.dart 启动 30s 静默检查。
  static bool get supportsSelfUpdate => _android;

  /// 后台连接保活（Android 前台服务：审批提醒开=后台常连）。iOS 无
  /// 前台服务等价物，挂起后代码不执行——通知语义为「前台实时 + 回
  /// 前台对账补齐」（复用 notifyCoordinator.onResumed，零新开发）。
  /// 消费点：通知设置页「审批提醒」副标题文案分档。APNs 自建推送链
  /// 已拍板入 backlog（真痛点出现再立项），立项与否不影响本项语义。
  static bool get supportsBackgroundKeepAlive => _android;

  /// OEM 省电白名单/自启动引导（华为启动管理三开关等，notify-guide）。
  /// iOS 无此概念——结构性不可行，永不翻 true；通知权限引导走系统
  /// 设置页（iOS E 批）。消费点：通知设置页「后台保障设置」入口。
  static bool get supportsOemPowerGuide => _android;

  /// 系统凭证解锁（Android KeyguardManager / iOS LocalAuthentication）。
  /// iOS G 批接 LAContext（Face ID/设备密码）后翻 true；届时
  /// Info.plist 需 NSFaceIDUsageDescription。消费点：settings-security
  /// 系统锁屏档（G 批接线，本批不消费）。
  static bool get supportsSystemCredentialUnlock => _android;

  /// 锁定期防截屏/防任务栏缩略图（Android FLAG_SECURE）。iOS 无等价
  /// API（截屏不可拦截，最多做切换器遮罩）——结构性不可行，永不翻
  /// true；G 批按「切换器遮罩」降级呈现。消费点：settings-security
  /// 防泄露开关（G 批接线，本批不消费）。
  static bool get supportsSecureFlag => _android;
}
