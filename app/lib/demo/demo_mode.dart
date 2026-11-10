/// 演示模式开关（`--dart-define=ZP_DEMO=1`）。
///
/// 演示模式让 app 在无账号、无配对、无网络的条件下以真实渲染运行：
/// [DemoAppState] 以脚本化的 [DemoChannel] 驱动真实的传输层与状态层，
/// 用于宣传截图与演示视频的采集。默认关闭，正式包行为零变化。
///
import 'package:flutter/foundation.dart' show kReleaseMode;

/// 解析用 String 语义并宽容 'true'：`bool.fromEnvironment` 只认字面
/// 'true'（传 '1' 恒 false 且无任何征兆），构建脚本统一传 '1'。
const String _zpDemoDefine = String.fromEnvironment('ZP_DEMO');

/// 演示模式是否启用（编译期常量）。
///
/// release 构建强制关闭：演示壳展示的是全合成数据，任何渠道误发都会
/// 让用户看到"像真的一样"的假界面（信任事故）。素材采集用 debug/
/// profile 构建（profile 为 AOT，录制帧率足够，release 不需要也不允许）。
const bool demoModeEnabled =
    !kReleaseMode && (_zpDemoDefine == '1' || _zpDemoDefine == 'true');

/// 自动演绎（`--dart-define=ZP_DEMO_AUTO=1`，仅演示模式内生效）。
///
/// 录制宣传视频时 MuMu 的 screenrecord 会冻结系统级输入注入（tap/am
/// start 均不生效，应用内部计时器不受影响）——启动自动演绎后审批卡
/// 在展示数秒后自行放行，录像全程零外部输入，素材可重复生成。
const String _zpDemoAutoDefine = String.fromEnvironment('ZP_DEMO_AUTO');

const bool demoAutoEnabled =
    demoModeEnabled && (_zpDemoAutoDefine == '1' || _zpDemoAutoDefine == 'true');
