import 'dart:async' show Timer;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show MethodChannel;
import 'core/localized_text.dart';
import 'core/system_asr.dart';

import 'core/theme.dart';
import 'app.dart';
import 'demo/demo_app_state.dart';
import 'demo/demo_mode.dart';

/// release 取证探针（2026-10-16 真机复验教训）：
/// release 构建里未捕获的构建异常默认渲染为黑/空屏且无日志——
/// 配对后黑屏无现场可查。这里把三类异常全部落到 logcat（[app] 前缀，
/// 与既有监控管线一致），并把黑屏改为可见的红字错误卡，黑屏必留栈。
void _installForensicProbes() {
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('[app] [flutter-error] ${details.exception}\n'
        '${details.stack.toString().split('\n').take(12).join('\n')}');
    FlutterError.presentError(details);
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint('[app] [error-widget] ${details.exception}');
    // 深色模式批1：ErrorWidget 在失败子树原位渲染（仍处于主题树内），
    // 用 Builder 读当前套——builder 签名无 context。
    // MaterialApp 之上的子树（根 builder 等）出错时
    // 无 Theme 祖先，Theme.of 抛异常会让红卡自身 build 失败退回框架
    // 灰屏——字面色兜底保证任何层级都能渲染取证红卡（日志已先行落
    // logcat，不受影响）。
    return Builder(
      builder: (context) {
        Color destructive;
        try {
          destructive = context.colors.destructive;
        } catch (_) {
          // 单源：AppThemeSpec.light.colors.destructive（不硬编码字面量，
          // design_scan 要求颜色引用主题单源；此处 Theme 不可用故直接
          // 取 light 规格常量）。
          destructive = AppThemeSpec.light.colors.destructive;
        }
        return Center(
          child: Text(
            '渲染异常：${details.exception}',
            style: TextStyle(color: destructive, fontSize: 13),
          ),
        );
      },
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[app] [zone-error] $error\n'
        '${stack.toString().split('\n').take(12).join('\n')}');
    return true;
  };
}

/// 帧看门狗（见 main 内注释详述）。返回探针句柄仅供测试引用。
void _installFrameWatchdog() {
  DateTime lastFrameAt = DateTime.now();
  bool probeArmed = false;
  int staleTicks = 0;
  int recoveries = 0;
  const surface = MethodChannel('companion/surface');
  void armProbe() {
    if (probeArmed) return;
    probeArmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      probeArmed = false;
      lastFrameAt = DateTime.now();
      staleTicks = 0;
      armProbe();
    });
  }

  armProbe();
  Timer.periodic(const Duration(seconds: 8), (_) {
    final appState = WidgetsBinding.instance.lifecycleState;
    if (appState != AppLifecycleState.resumed) {
      staleTicks = 0;
      return;
    }
    // 主动要一帧：健康引擎会经 vsync 完成该帧并续探针；楔死引擎这里
    // 石沉大海。
    WidgetsBinding.instance.scheduleFrame();
    final idleFor = DateTime.now().difference(lastFrameAt).inSeconds;
    if (idleFor < 16) return;
    staleTicks++;
    if (staleTicks < 2) return;
    recoveries++;
    staleTicks = 0;
    debugPrint('[frame-watchdog] 引擎停帧 ${idleFor}s，重建表面'
        '（第 $recoveries 次）');
    // recreate 恢复的是引擎表面而非根因（cameraX↔合成器楔死在 Flutter/
    // 厂商侧未根治）——原生侧有 10 分钟滑窗上限防无限重启
    // 循环；被拒时在此留痕，交给用户大退/切页。
    surface.invokeMethod('recreate').then((ok) {
      if (ok != true) {
        debugPrint('[frame-watchdog] 原生侧拒绝重建（滑窗超额，防无限'
            '重启循环）——请大退应用或离开触发页');
      }
    }).catchError((_) {});
  });
}

/// 构建产物探针（验收#3）：`String.fromEnvironment` 在 AOT 编译期
/// 求值，拼接串进 snapshot 字符串池——tools/build-release.sh 在成品
/// APK 的 libapp.so 里 grep 此串，验证 VOICE_HMS dart-define 真正到达
/// Dart 编译（防线背景：历史上两次构建开关与原生注入错配——产物
/// 断言在而 Dart 常量为 false，成对注入半边失效）。
const String kVoiceHmsBuildProbe =
    'zp-voice-hms:' + String.fromEnvironment('VOICE_HMS');

void main() {
  // 系统语音识别可用性预热（2026-10-28 泛用批）：本地 Intent 查询零
  // 网络，毫秒级；填充 SystemAsr.available 供语音入口三级判定读取。
  // 通道调用须在绑定初始化之后（冒烟实证：runApp 前裸调 invokeMethod
  // 抛 Binding has not yet been initialized，探测失效）。
  WidgetsFlutterBinding.ensureInitialized();
  _installForensicProbes();
  debugPrint('[perf] main_start');
  // 帧看门狗（扫码黑屏根治层 3）：相机纹理销毁后
  // 引擎偶发停止产帧（Dart 定时器活着=业务日志正常，但零帧输出、语义
  // 树空、窗口黑——agent 实证帧计数冻结）。检测=前台期间主动 schedule
  // -Frame 后连续两个探测周期（16s）无任何帧完成 → 判楔死 → 经
  // companion/surface 通道 recreate() 重建 Flutter 表面（同进程，秒级
  // 恢复，替代用户大退）。健康应用：静止页也会因主动调帧而完成一帧，
  // 探针续挂；后台（paused）不探测不误杀。
  _installFrameWatchdog();
  // 黑屏取证：帧时序哨兵——任何总耗时>250ms 的
  // 帧打一行（build/raster 分解），用于实测"配对成功瞬间 UI 线程停顿"
  // 是否超厂商应用自愈阈值（理论待验）。零常驻开销（回调仅读时序）。
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final total = t.totalSpan.inMilliseconds;
      if (total > 250) {
        debugPrint(
          '[perf-frame] total=${total}ms '
          'vsync=${t.vsyncOverhead.inMilliseconds}ms '
          'build=${t.buildDuration.inMilliseconds}ms '
          'raster=${t.rasterDuration.inMilliseconds}ms',
        );
      }
    }
  });
  // 探针引用点（保 tree-shake 存活）+ 顺带给 logcat 留构建期语音通道
  // 指纹（验收#3 取证当时正缺这一行）。
  debugPrint('[voice] build probe $kVoiceHmsBuildProbe');
  SystemAsr.probe();
  // 演示模式（--dart-define=ZP_DEMO=1）：注入 DemoAppState——纯虚拟
  // 数据驱动真实 UI（截图/演示视频采集用），跳过登录/配对/网络。
  // 注入路径同时跳过 testLaunchArgsReader 与 load()（见 app.dart）。
  runApp(
    demoModeEnabled
        ? ZcodeCompanionApp(app: DemoAppState())
        : const ZcodeCompanionApp(),
  );
}
