import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme.dart';
import 'core/l10n.dart';
import 'state/app_state.dart';
import 'state/app_state_scope.dart';
import 'ui/app_lock_gate.dart';
import 'dart:async';
import 'ui/update_flow.dart';
import 'ui/home_shell.dart';

/// companion/test 通道：名字沿用历史测试缝，现承载生产功能——长按图标
/// 快捷入口（冷启动 getLaunchArgs/热启动 shortcut 推送）与
/// 自动化配对缝；原生侧对位注释见 MainActivity.configureFlutterEngine。
const _testChannel = MethodChannel('companion/test');

class ZcodeCompanionApp extends StatefulWidget {
  const ZcodeCompanionApp({super.key, AppState? app}) : _injectedApp = app;

  /// 测试缝：注入预置状态的 AppState（测试环境 secure storage 不可用）。
  final AppState? _injectedApp;

  @override
  State<ZcodeCompanionApp> createState() => _ZcodeCompanionAppState();
}

class _ZcodeCompanionAppState extends State<ZcodeCompanionApp>
    with WidgetsBindingObserver {
  late final AppState _app = widget._injectedApp ?? AppState();
  AppLifecycleListener? _lifecycleListener;
  Timer? _updateCheckTimer;

  @override
  void initState() {
    super.initState();
    // 冷启动埋点（阶段 3 基线测量：am start -W 与 logcat 时间戳对照）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[perf] first_frame');
    });
    // 阶段 3 第二段：退后台默认 90s 断连、回前台秒连（≤5s 验收线）；
    // "审批提醒"开（前台服务）则后台常连。生产根与进程同生命周期，
    // 但持有引用并在 dispose 释放——测试
    // 反复 pumpWidget 不再累积 observer/滞留已 dispose 的 AppState。
    _app.appLock.attach();
  // 应用内更新：启动 30s 后静默检查一次（24h 节流
  // 在 UiPrefs；失败无感；弹窗走 navigatorKey）。Timer 挂 State——widget
  // 测试树销毁时必须取消（pending timer 断言）。
  _updateCheckTimer = Timer(const Duration(seconds: 30), () {
    final ctx = updateNavigatorKey.currentContext;
    if (ctx == null || !mounted) return;
    unawaited(checkAndPrompt(ctx, manual: false));
  });
  _lifecycleListener = AppLifecycleListener(
      onPause: _app.onAppPaused,
      onResume: _app.onAppResumed,
    );
    // 「跟随系统」档语言即时生效：Manifest
    // configChanges 含 locale（Activity 不重建，Flutter 引擎只更新
    // PlatformDispatcher.locale 并通知 WidgetsBindingObserver）——根层
    // 订阅 didChangeLocales 触发 L10n.refresh，配合下方根 builder 合并
    // L10n.changes 依赖，MaterialApp.locale 与 tr() 同帧跟随系统语言。
    WidgetsBinding.instance.addObserver(this);
    L10n.attach(
      listenable: _app.uiPrefs,
      preference: () => _app.uiPrefs.localePreference,
      // 经 WidgetsBinding 取 dispatcher（生产=同一个 PlatformDispatcher；
      // 测试=TestPlatformDispatcher，localeTestValue 可覆写——
      // 跟随系统语言路径因此可被测试真实验证）。
      systemLocale: () => widget._injectedApp == null
          ? WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag()
          : 'zh-CN',
    );
    // 模拟器自动化：am start --es pairing_url ... 直接配对（模拟器自动化约定）
    if (widget._injectedApp == null) {
      _app.testLaunchArgsReader = () async {
        try {
          final res = await _testChannel.invokeMethod<Map<dynamic, dynamic>>(
            'getLaunchArgs',
          );
          if (res == null) return null;
          return {
            'url': res['pairingUrl'] as String?,
            'name': res['pairingName'] as String?,
            // V2 测试缝：origin 覆盖+账号凭据注入。
            'relay_v2_origin': res['relayV2Origin'] as String?,
            'account_jwt': res['accountJwt'] as String?,
            // 长按图标快捷入口（6.6①）冷启动动作。
            'shortcut_action': res['shortcutAction'] as String?,
          };
        } on Object {
          return null; // 平台不支持/无参数
        }
      };
      // 快捷入口热路径（6.6①）：singleTop onNewIntent 原生→Dart 推送。
      // 回 true 作为"已消费"回执——原生 onNewIntent 据此清空留存值
      // （handler 不在位时回执为 null，原生侧保留动作待冷启动兜底，
      // / 的留存语义兑现）。
      _testChannel.setMethodCallHandler((call) async {
        if (call.method == 'shortcut') {
          _app.handleShortcutAction('${call.arguments ?? ''}');
          return true;
        }
        return null;
      });
      _app.load();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    // 见 initState 注释：系统语言翻转 → 重算 L10n._resolved（preference
    // 为 system 档时生效），_changes 通知根层重建刷新 MaterialApp.locale。
    L10n.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    // 测试通道 handler 同步摘除：pumpWidget 多实例
    // 场景不再滞留旧 State 的闭包。
    if (widget._injectedApp == null) {
      _testChannel.setMethodCallHandler(null);
    }
    L10n.detach();
    if (widget._injectedApp == null) {
      _app.dispose();
    }
    _updateCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      app: _app,
      // 批2-1：偏好驱动 themeMode（三档开关即时生效；重启经 secure
      // storage 保持）。批2-2：状态栏图标亮度随有效主题——AppBar 页由
      // AppBar 自带注解管理（优先），此处兜无 AppBar 表面（HomeShell 加载
      // 态/全屏底板等）。
      child: ListenableBuilder(
        // L10n.changes 入列：系统语言翻转经
        // didChangeLocales → refresh → _changes 通知，根层随之重建——
        // MaterialApp.locale 参数与 tr() 不再停在旧语言半套滞后。
        listenable: Listenable.merge([_app.uiPrefs, L10n.changes]),
        builder: (context, _) {
          L10n.refresh();
          final mode = switch (_app.uiPrefs.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          };
          // 批2 审查 （2026-10-23）：原直读 View.of(...).platformDispatcher
          // 不注册依赖——system 档下系统亮度翻转根层不重建，状态栏注解
          // 陈旧。改 MediaQuery.platformBrightnessOf（与 MaterialApp 同源，
          // 注册 aspect 依赖，翻转即重建）。
          final platformDark =
              MediaQuery.platformBrightnessOf(context) == Brightness.dark;
          final effectiveDark =
              mode == ThemeMode.dark ||
              (mode == ThemeMode.system && platformDark);
          return AnnotatedRegion<SystemUiOverlayStyle>(
            // 批2 审查 ：不用 .light/.dark 常量（两者把安卓导航栏钉成
            // 主题无关纯黑）——只设状态栏字段（AppBar backward-compat 同款
            // 形态），导航栏交还系统。
            value: effectiveDark
                ? const SystemUiOverlayStyle(
                    statusBarBrightness: Brightness.dark,
                    statusBarIconBrightness: Brightness.light,
                  )
                : const SystemUiOverlayStyle(
                    statusBarBrightness: Brightness.light,
                    statusBarIconBrightness: Brightness.dark,
                  ),
            child: MaterialApp(
              navigatorKey: updateNavigatorKey, // 应用内更新弹窗
              title: 'ZCode Pocket', // 批次5：旧名清理（改名遗漏，显示名统一）
              debugShowCheckedModeBanner: false,
              locale: L10n.flutterLocale,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
              // 多机型批（阶段 6.1）：系统字号全局钳制上限 1.3
              // （用户拍板）——厂商大字体档放最大时文字撑爆紧凑行（模式
              // 药丸/顶栏副行/任务卡状态行）；缩字号不拦（尊重用户调小）。
              // 钳制在 builder 层=对所有路由/弹层统一生效。
              builder: (context, child) => MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                // 应用锁遮罩：builder 层=Navigator 之上，
                // 覆盖所有路由/弹层；Stack 保 child 树不被卸载。
                child: AppLockGate(child: child ?? const SizedBox.shrink()),
              ),
              // 深色模式批1（ 拍板③）：浅色仍是设计基准与回归
              // 红线（冻结单测把守）。
              theme: buildAppTheme(),
              darkTheme: buildAppTheme(Brightness.dark),
              themeMode: mode,
              home: const HomeShell(),
            ),
          );
        },
      ),
    );
  }
}
