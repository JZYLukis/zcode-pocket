// 自研 companion/* 平台通道注册表（ios-adaptation-1 平台缝）。
//
// 单一事实源：Dart 侧全部自研通道名 + 双平台实现状态。
// channel_contract_test 据此做双向静态契约：
//   ① lib/ 里出现的 MethodChannel('companion/...') 字面量必须登记在册
//      （新增通道忘登记/名字漂移即拦）；
//   ② 登记项的通道名必须在 Android Kotlin 源（app/android/**.kt）中出现
//      （原生侧删通道/改名即拦）。
// iOS 批次（D/E/F/G/H）落地 Swift 实现时在此更新 iosPlan/iosNote——
// 注册表即 iOS 适配进度账。
//
// 注意：插件自带通道（flutter_local_notifications / mobile_scanner 等）
// 不在此列——平台差异由插件自身解决，Dart 调用点不感知。

/// iOS 实现计划档位。
enum CompanionIosPlan {
  /// 待实现 Swift 对位（iosNote 标注目标批次与要点）。
  swift,

  /// iOS 不实现：调用点由 ZpCapabilities 门控隐藏，或通道调用按既有
  /// catch 语义降级（no-op）——iosNote 标注降级方式。
  notApplicable,
}

/// 一条自研通道的登记项。
class CompanionChannel {
  const CompanionChannel({
    required this.name,
    required this.androidOwner,
    required this.iosPlan,
    required this.iosNote,
  });

  /// 通道名（MethodChannel 构造参数原样，含 companion/ 前缀）。
  final String name;

  /// Android 实现位置（供人工对位；契约测试只校验通道名在 Kotlin 源）。
  final String androidOwner;

  /// iOS 计划档位。
  final CompanionIosPlan iosPlan;

  /// iOS 计划说明（目标批次 + 实现要点或降级方式）。
  final String iosNote;
}

/// 全部自研通道（与 lib/ 内 MethodChannel('companion/...') 字面量全集
/// 一一对应——channel_contract_test 双向钉死，两边谁多谁少都红）。
const kCompanionChannels = <CompanionChannel>[
  CompanionChannel(
    name: 'companion/notify',
    androidOwner: 'MainActivity.kt + ForegroundService.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'E 批：UNUserNotificationCenter 本地通知/权限/跳系统设置；'
        'startForeground/stopForeground/updateForeground 等 FGS 语义在 iOS '
        'no-op（supportsBackgroundKeepAlive=false，前台+对账档）',
  ),
  CompanionChannel(
    name: 'companion/sys_asr',
    androidOwner: 'SystemAsrPlugin.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'H 批：SFSpeechRecognizer+AVAudioEngine，保持 isAvailable/'
        'start/stop/cancel/event 协议形态（1 分钟识别上限、音频会话中断处理）；'
        'Info.plist 需 NSSpeechRecognitionUsageDescription',
  ),
  CompanionChannel(
    name: 'companion/app_lock',
    androidOwner: 'AppLockPlugin.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'G 批：LAContext.evaluatePolicy（deviceOwnerAuthentication）'
        '对位 requestSystemUnlock；setSecureFlag 降级为切换器遮罩或 no-op'
        '（supportsSecureFlag=false）',
  ),
  CompanionChannel(
    name: 'companion/share',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'D 批：UIActivityViewController（iPhone 模态；iPad 需 '
        'popoverPresentationController 指定 sourceView——设备族若含 iPad 再议）',
  ),
  CompanionChannel(
    name: 'companion/appinfo',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'D 批：NSBundle（CFBundleShortVersionString/CFBundleVersion）',
  ),
  CompanionChannel(
    name: 'companion/timezone',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'D 批：TimeZone.current.identifier',
  ),
  CompanionChannel(
    name: 'companion/battery',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'D 批：UIDevice（batteryLevel/batteryState）；电压/温度 iOS '
        '不可得返回 -1（battery_journal 已有 -1 守卫）',
  ),
  CompanionChannel(
    name: 'companion/surface',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.notApplicable,
    iosNote: 'F 批：Activity.recreate 无 iOS 等价（华为扫码黑屏专治），'
        'recreate 返回 false/no-op；帧看门狗按平台关闭（main.dart）',
  ),
  CompanionChannel(
    name: 'companion/test',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.swift,
    iosNote: 'I 批：launchOptions/UIApplicationShortcutItem 对位长按图标'
        '快捷入口；getLaunchArgs 自动化缝按需（iOS 集成测试形态另定）',
  ),
  CompanionChannel(
    name: 'companion/update',
    androidOwner: 'MainActivity.kt',
    iosPlan: CompanionIosPlan.notApplicable,
    iosNote: 'iOS 永不实现（无安装包侧装）；入口由 supportsSelfUpdate '
        '门控隐藏（settings 两行 + 启动检查），通道调用点不可达',
  ),
  CompanionChannel(
    name: 'companion/hms_asr',
    androidOwner: 'src/voiceHms 条件源集 HmsAsrPlugin.kt（仅 -PvoiceHms）',
    iosPlan: CompanionIosPlan.notApplicable,
    iosNote: 'iOS 永不编译 HMS（无对应源集，VOICE_HMS 仅 Android 注入）；'
        'hmsVoiceConfigured 在 iOS 恒 false，语音自动走 sys_asr',
  ),
];
