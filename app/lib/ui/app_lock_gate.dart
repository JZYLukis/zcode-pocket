// 应用锁遮罩（app-lock-1）：挂在 MaterialApp.builder（Navigator 之上）
// ——不替换 child（保路由状态），Stack 覆盖 + AbsorbPointer + 停动画。
// 返回键不拦（builder 层无法 PopScope）：返回=退出 app，锁层仍在，
// 不泄露内容，可接受（注释留痕；如需严格拦截改 navigatorKey+路由方案）。
import 'dart:async';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import '../core/app_lock.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../state/ui_prefs.dart';

/// 根包装：锁定时全屏遮罩；同时负责首帧从 UiPrefs 装载锁配置
/// （冷启动 locked=mode!=none——UiPrefs 先于 AppState.loaded 读完，
/// 首帧即锁无闪屏）。
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  AppLockController? _controller;
  bool _armed = false;
  UiPrefs? _watchedPrefs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    final app = AppStateScope.of(context);
    _controller = app.appLock;
    // 对抗审查 ① 冷启动 fail-open：gate 首帧早于 uiPrefs.load 完成
    // （29 个异步安全存储读）——此前一次性闩锁把内存默认值 none 当配置
    // 消费，配了锁的用户杀进程重开=完全没锁。现在：未 loaded 前不闩锁
    // 不装载不渲染 child（只见加载占位），loaded 变真后才一次性装载。
    if (!app.uiPrefs.isLoaded) {
      _watchedPrefs = app.uiPrefs;
      app.uiPrefs.addListener(_onPrefsLoaded);
      // 幂等兜底：任何路径未触发 load 时由 gate 自行拉起，避免占位
      // 永久悬挂（load 防重入）。测试环境（asserts 态）secure storage
      // read 挂起（widget_test 注释实证）——不拉起，等测试自行注入
      // 就绪状态（asserts 检测先例=悬浮球引导抑制，活事项 65-③）。
      var testEnv = false;
      assert(() {
        testEnv = true;
        return true;
      }());
      if (!testEnv) unawaited(app.uiPrefs.load());
      return;
    }
    _onPrefsLoaded();
  }

  void _onPrefsLoaded() {
    final app = AppStateScope.of(context);
    if (!app.uiPrefs.isLoaded) return;
    app.uiPrefs.removeListener(_onPrefsLoaded);
    if (_armed) return;
    _armed = true;
    final ui = app.uiPrefs;
    app.appLock.loadFromPrefs(
      mode: appLockModeFromString(ui.appLockModeRaw),
      autoLockSeconds: ui.appLockAutoLockSeconds,
      secureFlagPref: ui.appLockSecureFlag,
      initialLock: true,
      pinSalt: ui.appLockPinSalt,
      pinHash: ui.appLockPinHash,
    );
    // 对抗审查 ①：软锁死降级提示（一次性）。
    if (app.appLock.pinMaterialMissing.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('应用锁数据缺失，已停用；请到设置中重新开启'))),
        );
      });
    }
  }

  @override
  void dispose() {
    _watchedPrefs?.removeListener(_onPrefsLoaded);
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_armed) {
      // 偏好未就绪：不透明占位（绝不渲染 child——被锁内容不可见）。
      // 主题 token 单源（design_scan）。
      return ColoredBox(color: Theme.of(context).colorScheme.surface);
    }
    final controller = _controller!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final locked = controller.locked && controller.mode != AppLockMode.none;
        if (locked) {
          // 对抗审查 ①：只挡指针不够——TalkBack 可朗读遮罩下的语义树、
          // 硬件键盘焦点可移入并回车触发（IME 连接残留还能往被锁的会话
          // 输入）。锁定瞬间抢焦点断输入连接，并用语义/焦点双向排除。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FocusManager.instance.primaryFocus?.unfocus();
          });
        }
        return Stack(
          children: [
            ExcludeSemantics(
              excluding: locked,
              child: ExcludeFocus(
                excluding: locked,
                child: TickerMode(
                  enabled: !locked,
                  child: AbsorbPointer(absorbing: locked, child: widget.child),
                ),
              ),
            ),
            if (locked)
              Positioned.fill(
                // 局部 Overlay：builder 层在 Navigator/Overlay 之外，PIN
                // 输入框（EditableText/IME）必须有 Overlay 祖先——真机
                // 同样需要（测试首跑即抓出）。
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => _LockScreen(controller: controller),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({required this.controller});

  final AppLockController controller;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final _pinCtrl = TextEditingController();
  String? _error;
  bool _verifying = false;

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _tryPin(AppState app) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    Object r = false;
    try {
      r = await widget.controller.unlockWithPin(
        _pinCtrl.text,
        saltHex: app.uiPrefs.appLockPinSalt,
        hashHex: app.uiPrefs.appLockPinHash,
      );
    } on Object {
      // 对抗审查 ① 变体：salt 非法等异常不得让按钮永久"验证中"。
      r = false;
    } finally {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        if (r == true) {
          _pinCtrl.clear();
        } else if (r is int && r > 0) {
          _pinCtrl.clear();
          _error = tr('尝试次数过多，请稍后再试');
        } else {
          _pinCtrl.clear();
          _error = tr('PIN 码不正确');
        }
      });
    }
  }

  Future<void> _openSecuritySettings() async {
    try {
      await const MethodChannel('companion/app_lock')
          .invokeMethod<void>('openSecuritySettings');
    } catch (_) {}
  }

  Future<void> _trySystem() async {
    if (_verifying) return;
    setState(() => _verifying = true);
    await widget.controller.unlockWithSystem();
    if (!mounted) return;
    // 失败/取消：停留锁屏（可重点），按钮恢复可按。
    setState(() => _verifying = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final pinMode = widget.controller.mode == AppLockMode.pin;
    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.colors.accent,
                      shape: BoxShape.circle,
                    ),
                    // 字阶守卫：字号走 uiXl+FittedBox 视觉放大
                    //（about_page Z 标记同款先例）。
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: Text(
                        'Z',
                        style: TextStyle(
                          fontSize: AppType.uiXl,
                          fontWeight: FontWeight.w700,
                          color: context.colors.foreground,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '应用已锁定',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: AppType.uiLg, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 24),
                  if (pinMode) ...[
                    TextField(
                      key: const ValueKey('app-lock-pin-input'),
                      controller: _pinCtrl,
                      autofocus: true,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      // 对抗审查 ①低2：防输入法侧信道（预测/自动填充/
                      // 个性化学习不得记忆 PIN）。
                      enableSuggestions: false,
                      autocorrect: false,
                      autofillHints: const [],
                      onSubmitted: (_) => _tryPin(app),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: tr('输入 PIN 码'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.destructive,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const ValueKey('app-lock-pin-submit'),
                      onPressed: _verifying ? null : () => _tryPin(app),
                      child: Text(_verifying ? tr('验证中…') : tr('解锁')),
                    ),
                  ] else
                    FilledButton.icon(
                      key: const ValueKey('app-lock-system-unlock'),
                      onPressed: _verifying ? null : _trySystem,
                      icon: const Icon(Icons.lock_open),
                      label: Text(_verifying ? tr('验证中…') : tr('解锁')),
                    ),
                    // ①：设备锁被移除——人话+跳系统安全设置出口（防
                    // 无提示死锁；设置页在遮罩后不可达）。
                    ValueListenableBuilder<bool>(
                      valueListenable: widget.controller.systemUnlockUnavailable,
                      builder: (context, unavailable, _) {
                        if (!unavailable) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 12),
                            Text(
                              tr('设备未设置系统屏幕锁，无法验证；请先在系统设置中配置锁屏'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: AppType.uiCaption,
                                color: context.colors.destructive,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.tonalIcon(
                              key: const ValueKey('app-lock-open-security-settings'),
                              onPressed: _openSecuritySettings,
                              icon: const Icon(Icons.settings_outlined, size: 18),
                              label: Text(tr('打开系统安全设置')),
                            ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
