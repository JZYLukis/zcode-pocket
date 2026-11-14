// WebView 主框架错误过滤（ios-adaptation-3，C 批第一段）。
//
// OAuth 跨域重定向期间，两侧平台的 WebView 都会报「取消导航」类错误：
// Android=ERR_ABORTED(-1)（2026-10-21 真机实证）、iOS=NSURLErrorCancelled
// (-999)（WKWebView 常态）。不过滤会把进行中的授权流程整页换成错误
// 视图。子资源（非主框架）错误一律不拦页面——iOS 上 WKWebView 对子
// 帧/资源错误的上报更频繁，拦了会误伤正常加载。
//
// login_page（OAuth 登录）与 web_fallback_page（网页版远控）共用。

/// 是否把该 WebView 资源错误升级为页面错误态。
///
/// 仅主框架 + 非取消类错误返回 true；[isForMainFrame] 三态里 null 按
/// 非主框架保守处理（不拦）。
bool isFatalWebViewMainFrameError(int errorCode, bool? isForMainFrame) {
  if (isForMainFrame != true) return false;
  const canceledNavigationCodes = <int>{
    -1, // Android ERR_ABORTED：新导航取代旧导航。
    -999, // iOS NSURLErrorCancelled：WKWebView 取消加载。
  };
  return !canceledNavigationCodes.contains(errorCode);
}
