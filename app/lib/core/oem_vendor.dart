// 设备厂商识别与「后台与通知保障」引导页文案档位。
//
// 背景：引导页此前文案与跳转组件全是华为写死（阶段 3 后台专项时唯一
// 目标机是单一华为折叠屏）；开源后用户机型多样，
// 华为术语（"应用启动管理三开关"）在其他品牌上找不到对位入口。
//
// 分工：原生侧只回传 Build.MANUFACTURER 原始串（companion/notify 的
// manufacturer 方法）；规范化与文案选择全在 Dart——纯函数可测，且改
// 文案不必动原生。跳转组件候选仍按厂商写在原生侧（Activity 直跳只能
// 原生做），两边 key（枚举）保持一致。

/// 规范化后的设备厂商档位。
enum OemVendor { huawei, honor, vivo, xiaomi, oppo, other }

/// Build.MANUFACTURER → 档位。匹配用小写包含（真机上报形态如
/// "HUAWEI"/"HONOR"/"vivo"/"Xiaomi"/"OnePlus"，包含匹配可吸收子品牌：
/// Redmi/PoCo→xiaomi、iQOO→vivo、realme→oppo）。荣耀档在华为之前
/// 判（分家后 MANUFACTURER="HONOR"，与 "huawei" 不含同串不会互抢）。
OemVendor oemVendorFromManufacturer(String raw) {
  final m = raw.toLowerCase();
  if (m.contains('honor')) return OemVendor.honor;
  if (m.contains('huawei')) return OemVendor.huawei;
  if (m.contains('vivo') || m.contains('iqoo')) return OemVendor.vivo;
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return OemVendor.xiaomi;
  }
  if (m.contains('oppo') || m.contains('oneplus') || m.contains('realme')) {
    return OemVendor.oppo;
  }
  return OemVendor.other;
}

/// 引导页第 1 步（自启动/后台开关）的按厂商文案。
/// 华为档文案与 2026-10 阶段 3 原版逐字一致——主设备零回归（测试钉死）。
class OemStartupGuide {
  final String title;
  final String body;
  /// 跳转成功（直命中厂商组件）的 footnote。
  final String startupNote;
  /// 回退到应用详情页的 footnote。
  final String detailsNote;

  const OemStartupGuide({
    required this.title,
    required this.body,
    required this.startupNote,
    required this.detailsNote,
  });
}

const _huaweiGuide = OemStartupGuide(
  title: '启动管理三开关',
  body: '设置 → 应用 → 应用启动管理 → ZCode Pocket → 改为"手动管理"，'
      '开启 自启动 / 关联启动 / 后台活动 三个开关。',
  startupNote: '已跳到「启动管理」：找到 ZCode Pocket 改为手动管理，'
      '开启自启动/关联启动/后台活动三个开关',
  detailsNote: '已跳到应用详情页：请点「启动管理」（或「应用启动管理」）'
      '进入后改为手动管理，开三个开关',
);

const _honorGuide = OemStartupGuide(
  title: '启动管理三开关',
  body: '设置 → 应用 → 应用启动管理 → ZCode Pocket → 改为"手动管理"，'
      '开启 自启动 / 关联启动 / 后台活动 三个开关（老系统在 手机管家 内）。',
  startupNote: '已跳到「启动管理」：找到 ZCode Pocket 改为手动管理，'
      '开启自启动/关联启动/后台活动三个开关',
  detailsNote: '已跳到应用详情页：请点「启动管理」（或「应用启动管理」）'
      '进入后改为手动管理，开三个开关',
);

const _vivoGuide = OemStartupGuide(
  title: '自启动与后台运行',
  body: '设置 → 应用 → 应用管理 → ZCode Pocket → 开启「自启动」；'
      '再到 设置 → 电池 → 后台耗电管理，允许 ZCode Pocket 后台运行'
      '（OriginOS 的后台清理不在应用详情页，须从电池侧放行）。',
  startupNote: '已跳到后台管理页：开启 ZCode Pocket 的自启动与后台运行',
  detailsNote: '已跳到应用详情页：请开启「自启动」；再到 设置 → 电池 → '
      '后台耗电管理 允许后台运行',
);

const _xiaomiGuide = OemStartupGuide(
  title: '自启动与省电策略',
  body: '设置 → 应用设置 → 应用管理 → ZCode Pocket → 开启「自启动」；'
      '省电策略 选「无限制」（MIUI 的后台白名单在省电策略里）。',
  startupNote: '已跳到自启动管理页：开启 ZCode Pocket 的自启动，'
      '省电策略选无限制',
  detailsNote: '已跳到应用详情页：请开启「自启动」；省电策略选「无限制」',
);

const _oppoGuide = OemStartupGuide(
  title: '自启动与后台运行',
  body: '设置 → 应用 → 应用管理 → ZCode Pocket → 允许自启动、允许后台运行'
      '（部分版本在「耗电管理」内）；再到 设置 → 电池 → 应用速冻，'
      '将 ZCode Pocket 移出速冻名单。',
  startupNote: '已跳到自启动管理页：允许 ZCode Pocket 自启动与后台运行',
  detailsNote: '已跳到应用详情页：请允许「自启动/后台运行」；'
      '电池 → 应用速冻 移出本应用',
);

const _otherGuide = OemStartupGuide(
  title: '自启动与后台运行',
  body: '请在系统设置中找到 ZCode Pocket 的应用信息页，开启 自启动 / '
      '后台运行 相关开关（不同品牌的入口名称与路径不同，通常在应用详情'
      '或电池/省电设置内）。',
  startupNote: '已跳到后台管理页：开启 ZCode Pocket 的自启动与后台运行',
  detailsNote: '已跳到应用详情页：请在应用信息内找到 自启动/后台运行 '
      '开关开启',
);

/// 档位 → 引导文案（华为档=原版文案，勿改——回归测试钉死）。
OemStartupGuide oemStartupGuideFor(OemVendor vendor) => switch (vendor) {
      OemVendor.huawei => _huaweiGuide,
      OemVendor.honor => _honorGuide,
      OemVendor.vivo => _vivoGuide,
      OemVendor.xiaomi => _xiaomiGuide,
      OemVendor.oppo => _oppoGuide,
      OemVendor.other => _otherGuide,
    };
