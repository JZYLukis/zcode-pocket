// 系统底部安全区直推通道。
//
// 背景：部分厂商 ROM（如 vivo OriginOS 折叠屏展开态）的系统任务栏
// 在原生 rootWindowInsets 里正常上报，但 Flutter 的
// MediaQuery.viewPadding 拿到 0（透传断裂）。因此不依赖框架透传：
// 原生侧监听 decorView 的 insets 变化，把底部值（systemBars∪
// navigationBars∪displayCutout 取最大，逻辑 dp）实时推给本模块；
// 消费方取 max(MediaQuery.viewPadding.bottom, 本值)。
//
// 任务栏开/关、折叠/展开都会触发 insets 变化→实时跟随；键盘（ime
// 类型）不掺入（键盘弹出时多留的部分在键盘后面不可见，无可感知副作用）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生推送的底部安全区（逻辑 dp；0=未推送/无系统栏）。
final ValueNotifier<double> systemInsetBottomDp = ValueNotifier(0);

bool _initialized = false;

/// 注册原生反向推送（幂等；main 启动早期调用一次即可，未初始化的
/// 消费场景回落 MediaQuery——不比现状差）。
void initSystemInsetBridge() {
  if (_initialized) return;
  _initialized = true;
  const MethodChannel('companion/notify').setMethodCallHandler((call) async {
    if (call.method == 'systemInsetChanged') {
      final v = call.arguments;
      if (v is num) {
        systemInsetBottomDp.value = v.toDouble().clamp(0, 200);
      }
    }
    return null;
  });
  refreshSystemInset();
}

/// 主动拉一次当前底部安全区——listener 首次推送可能落在 Dart 就绪前
/// （变化驱动+任务栏常驻无变化时首推即丢失）。init 调一次；失败静默
/// （回落 MediaQuery 路径）。
Future<void> refreshSystemInset() {
  return const MethodChannel('companion/notify')
      .invokeMethod<num>('currentSystemInset')
      .then((v) {
    if (v != null) systemInsetBottomDp.value = v.toDouble().clamp(0, 200);
  }).catchError((_) {});
}
