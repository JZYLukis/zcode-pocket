import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/device_list_page.dart';
import 'package:zcode_pocket/ui/web_fallback_page.dart';

/// 网页备用入口（阶段 4.2 最小版 / H08-8B，2026-10-29 批次）：入口
/// 可达性 + 导航白名单纯函数矩阵 + 页面结构（WebView 平台通道缺席时
/// 的降级呈现）。真实 WebView 加载/登录态复用/关闭恢复留真机实测。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('导航白名单（纯函数）', () {
    test('官方域与子域放行；内部协议放行', () {
      expect(isWebFallbackNavAllowed(Uri.parse('https://zcode.z.ai/remote/v4/')), isTrue);
      expect(
        isWebFallbackNavAllowed(Uri.parse('https://static.zcode.z.ai/app.js')),
        isTrue,
        reason: '官方子域资源放行',
      );
      expect(isWebFallbackNavAllowed(Uri.parse('about:blank')), isTrue);
      expect(isWebFallbackNavAllowed(Uri.parse('data:text/html,hi')), isTrue);
    });

    test('官方 OAuth 提供方跳转放行（Z.AI=chat.z.ai / BigModel=bigmodel.cn）', () {
      expect(
        isWebFallbackNavAllowed(
          Uri.parse('https://chat.z.ai/api/oauth/authorize?client_id=zcode'),
        ),
        isTrue,
        reason: '官方登录整页跳 Z.AI OAuth（refs webZaiOAuthConfig）',
      );
      expect(
        isWebFallbackNavAllowed(Uri.parse('https://bigmodel.cn/oauth/login')),
        isTrue,
        reason: 'BigModel 登录页',
      );
      expect(
        isWebFallbackNavAllowed(
          Uri.parse('http://chat.z.ai/api/oauth/authorize'),
        ),
        isFalse,
        reason: 'OAuth 提供方同样只许 https',
      );
      expect(
        isWebFallbackNavAllowed(Uri.parse('https://chat.z.ai.evil.com/')),
        isFalse,
        reason: '后缀伪装域名仍须阻止',
      );
      expect(
        isWebFallbackNavAllowed(Uri.parse('https://bigmodel.cn.evil.com/')),
        isFalse,
        reason: '后缀伪装域名仍须阻止',
      );
    });

    test('非官方域与危险协议阻止', () {
      expect(isWebFallbackNavAllowed(Uri.parse('https://evil.example.com/')), isFalse);
      expect(
        isWebFallbackNavAllowed(Uri.parse('https://zcode.z.ai.evil.com/')),
        isFalse,
        reason: '后缀伪装域名必须阻止',
      );
      expect(isWebFallbackNavAllowed(Uri.parse('javascript:alert(1)')), isFalse);
      expect(isWebFallbackNavAllowed(Uri.parse('file:///etc/passwd')), isFalse);
      expect(isWebFallbackNavAllowed(null), isFalse);
    });
  });

  group('入口与页面（WebView 禁用降级）', () {
    setUp(() => WebFallbackPage.debugDisableWebView = true);
    tearDown(() => WebFallbackPage.debugDisableWebView = false);

    testWidgets('设备列表 AppBar 入口可打开备用页', (tester) async {
      final app = AppState()..loaded = true;
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: DeviceListPage(accountId: 'acc-1'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('web-fallback-entry')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('web-fallback-entry')));
      // 列表页加载转圈永真（真实网络在测试假区挂起）——不用
      // pumpAndSettle，固定帧推入路由动画。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(WebFallbackPage), findsOneWidget);
      expect(find.text('网页版远控（备用通道）'), findsOneWidget);
      // WebView 通道缺席的降级呈现（测试环境）。
      expect(find.textContaining('网页组件不可用'), findsOneWidget);

      // 关闭即返回原生列表（原生状态未拆动——并行窗口语义）。
      await tester.pageBack();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(WebFallbackPage), findsNothing);
      expect(find.byKey(const ValueKey('web-fallback-entry')), findsOneWidget);
    });

    // 错误视图入口（web-fallback-entry-error）与 AppBar 入口同款推入
    // 代码；错误态需真实网络失败才能驱动（测试假区 HTTP 永不返回），
    // 视觉确认留真机实测（evidence uncovered 留账）。
  });

  test('http 明文官方域也拒绝（review-fix-1 安全组）', () {
    expect(
      isWebFallbackNavAllowed(Uri.parse('http://zcode.z.ai/remote/v4')),
      isFalse,
      reason: '官方域只允许 https，明文页面不进入登录共享 WebView',
    );
    expect(
      isWebFallbackNavAllowed(Uri.parse('https://zcode.z.ai/remote/v4')),
      isTrue,
    );
  });
}
