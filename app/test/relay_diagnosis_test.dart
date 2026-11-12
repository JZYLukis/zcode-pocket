// 2026-10-23 用户拍板第一档（回填律）：连接失败翻译成人话+可操作提示。
// 背景：用户手机挂 VPN 间歇性 DNS 故障（zcode.z.ai unknown host）——App
// 此前静默重试零信息，用户无法判断该关什么。本文件锁：分类器判定+
// 任务中心离线位的诊断文案渲染。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/relay_v2.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _OfflineApp extends AppState {
  _OfflineApp(String? failReason, String? failMessage) {
    if (failReason != null) updateRelayFailure(failReason, failMessage);
  }

  @override
  LinkPhase get phase => LinkPhase.reconnecting;
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: const TaskCenterPage()),
    );

void main() {
  test('分类器：DNS 解析失败（VPN 场景实测文案）', () {
    const e1 = 'HTTP /api/v1/remote/token 网络错误：SocketException: '
        'Failed host lookup: zcode.z.ai';
    final f = classifyRelayNetworkFailure(
      RelayV2Unavailable(e1, retryable: true),
    );
    expect(f.reason, 'network-dns');
    expect(f.message, contains('域名解析失败'));
  });

  test('分类器：超时/拒绝/401/未知', () {
    expect(
      classifyRelayNetworkFailure(
        const RelayV2Unavailable(
          'HTTP connection timed out after 0:00:15, host: zcode.z.ai',
          retryable: true,
        ),
      ).reason,
      'network-timeout',
    );
    // （2026-10-24）：生产端响应超时实际抛的是中文串
    // （relay_v2.dart res.close().timeout 分支）——此前测试喂的英文串
    // 在生产 throw 点不存在，漏判使超时专属文案在最典型的 VPN 黑洞
    // 路径上不可达。
    expect(
      classifyRelayNetworkFailure(
        const RelayV2Unavailable(
          'HTTP /api/v1/remote/token 超时',
          retryable: true,
        ),
      ).reason,
      'network-timeout',
    );
    expect(
      classifyRelayNetworkFailure(
        'SocketException: Connection refused (address=127.0.0.1)',
      ).reason,
      'network-refused',
    );
    expect(
      classifyRelayNetworkFailure(
        const RelayV2Unavailable('HTTP 401 unauthorized'),
      ).reason,
      'network-auth',
    );
    expect(
      classifyRelayNetworkFailure('weird stuff').reason,
      'network-unknown',
    );
  });

  testWidgets('重连中 DNS 失败：任务中心出人话诊断+VPN 提示', (tester) async {
    await tester.pumpWidget(
        _host(_OfflineApp('network-dns', '域名解析失败（zcode.z.ai 无法解析出服务器地址）')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('域名解析失败，正在重试'), findsOneWidget);
    expect(find.textContaining('把 z.ai 设为直连'), findsOneWidget,
        reason: '可操作提示必须出现（此前用户零信息只能猜）');
    // 页面另有「连接中断，自动重连中…」状态行——用 findsWidgets。
    expect(find.textContaining('自动重连'), findsWidgets);
  });

  testWidgets('无失败记录：保持原「连接中…」不渲染诊断', (tester) async {
    await tester.pumpWidget(_host(_OfflineApp(null, null)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('连接中…'), findsOneWidget);
    expect(find.textContaining('VPN'), findsNothing);
  });
}
