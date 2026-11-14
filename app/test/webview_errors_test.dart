// WebView 取消导航过滤（ios-adaptation-3，C 批）：跨平台错误码矩阵钉死
// ——Android ERR_ABORTED(-1) 与 iOS NSURLErrorCancelled(-999) 都是 OAuth
// 跨域重定向常态，不得升级为页面错误态；子资源错误一律不拦。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/webview_errors.dart';

void main() {
  test('Android ERR_ABORTED(-1) 主框架：不拦（重定向常态）', () {
    expect(isFatalWebViewMainFrameError(-1, true), isFalse);
  });

  test('iOS NSURLErrorCancelled(-999) 主框架：不拦（WKWebView 重定向常态）', () {
    expect(isFatalWebViewMainFrameError(-999, true), isFalse);
  });

  test('子资源错误一律不拦（isForMainFrame=false/null）', () {
    expect(isFatalWebViewMainFrameError(-1200, false), isFalse);
    expect(isFatalWebViewMainFrameError(-1200, null), isFalse,
        reason: 'null 三态保守按非主框架处理');
    // 即便是取消码，子框架也不拦（幂等）。
    expect(isFatalWebViewMainFrameError(-999, false), isFalse);
  });

  test('主框架真实失败仍拦（DNS/TLS 等）', () {
    expect(isFatalWebViewMainFrameError(-1053, true), isTrue); // iOS 服务器未找到
    expect(isFatalWebViewMainFrameError(-1200, true), isTrue); // iOS TLS
    expect(isFatalWebViewMainFrameError(-6, true), isTrue); // Android DNS
    expect(isFatalWebViewMainFrameError(0, true), isTrue);
  });
}
