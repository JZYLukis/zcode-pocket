import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:webview_flutter/webview_flutter.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';

/// 官方网页版远控备用入口（阶段 4.2 最小版 / H08-8B，2026-10-29 批次）：
/// 零协议依赖的逃生舱——原生协议漂移/握手失败时仍可用官方 Web 远控。
///
/// - 目标=`https://zcode.z.ai/remote/v4/`（官方唯一正式手机远控入口，
///   refs web-remote-login 契约：`/remote/v4`（含尾斜杠）；不做深链直达
///   会话）。
/// - 导航白名单=[isWebFallbackNavAllowed]（zcode.z.ai 同源；其余阻止）。
/// - 登录态与 OAuth 登录 WebView 共享 Cookie/localStorage——本页**不做**
///   登录卫生清理（与登录页相反；已登录即直接可用，未登录走页面内
///   官方登录）。
/// - 关闭即返回原生：原生连接不拆不停（并行窗口语义，无恢复时序）。
class WebFallbackPage extends StatefulWidget {
  const WebFallbackPage({super.key});

  /// 测试缝：无 WebView 平台通道的环境（widget 测试）禁用控制器创建。
  @visibleForTesting
  static bool debugDisableWebView = false;

  @override
  State<WebFallbackPage> createState() => _WebFallbackPageState();
}

/// 白名单判定（纯函数供测试）：官方域（含子域）与 WebView 内部协议放行。
bool isWebFallbackNavAllowed(Uri? uri) {
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'about' || scheme == 'data' || scheme == 'blob') return true;
  // review-fix-1（安全组）：官方域强制 https——http 明文承载钓鱼面且
  // cookie 可被 MITM 注入。
  if (scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  return host == 'zcode.z.ai' || host.endsWith('.zcode.z.ai');
}

class _WebFallbackPageState extends State<WebFallbackPage> {
  static const _target = 'https://zcode.z.ai/remote/v4/';
  WebViewController? _controller;
  String? _loadError;
  bool _controllerReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllerReady) return;
    _controllerReady = true;
    if (WebFallbackPage.debugDisableWebView) {
      _loadError = 'WebView unavailable in this environment';
      return;
    }
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(context.colors.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final allowed = isWebFallbackNavAllowed(Uri.tryParse(req.url));
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == true && mounted) {
              setState(() => _loadError = '${e.errorCode}: ${e.description}');
            }
          },
        ),
      );
    _controller = controller;
    unawaited(
      controller.loadRequest(Uri.parse(_target)).catchError((Object e) {
        if (mounted) setState(() => _loadError = '$e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('网页版远控（备用通道）'),
        actions: [
          if (controller != null)
            IconButton(
              key: const ValueKey('web-fallback-refresh'),
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  unawaited(controller.loadRequest(Uri.parse(_target))),
            ),
        ],
      ),
      body: controller == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('网页组件不可用：$_loadError'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.colors.foregroundSubtle),
                ),
              ),
            )
          : Stack(
              children: [
                WebViewWidget(controller: controller),
                if (_loadError != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: context.colors.card,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: context.colors.border),
                      ),
                      child: Text(
                        tr('加载异常：') + _loadError!,
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.warning,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
