import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import 'package:webview_flutter/webview_flutter.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';

/// V2 账号登录页：内嵌官方远控页 https://zcode.z.ai/remote/v4
/// 完成双平台 OAuth（Z.AI/BigModel）——官方页回调后把 zcode JWT 写进
/// **同源 localStorage `zcodejwttoken`**（官方 browserOAuthCredentialRepo
/// :82-93），我们在 WebView 上下文里轮询该键取凭据。
///
/// 为什么不自己发 OAuth：授权 redirect_uri 白名单限定官方回调路径
/// （oauthStateCodec.ts:4），原生自定义 scheme 服务端不认（本仓源码
/// 实证， 调查）；走官方页 = 与官方 web 端零漂移。
///
/// [qrParams]：扫码进入时透传 sid/mid/name/app_version——官方页会把
/// 白名单参数带进授权回调（web-remote-login.md:8-9），登录完成即自动
/// 连上扫码目标；我们取到 token 后也用它直接建 V2 档案（免设备列表）。
class LoginPage extends StatefulWidget {
  /// 测试缝：无 WebView 平台实现时走错误降级，不构造平台控制器。
  @visibleForTesting
  static bool debugDisableWebView = false;

  final Map<String, String> qrParams;
  const LoginPage({super.key, this.qrParams = const {}});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 会话卫生状态机（2026-10-26 真机验收③抽出；2026-11-03 对抗审查 M2
/// 重构两段式）：登录页必须先经历"清场→导航→二次清场"全部完成才允许
/// 取 token。旧一阶段版（consume 即置 ready）在置位与 wipe JS 求值之
/// 间留有几个事件循环——700ms 轮询可抢在清除前读到上一次的 token
/// （"删号秒回旧账号"的原始形态）。ready 只由 [markWipeComplete] 开。
class LoginSessionHygiene {
  bool _started = false;
  bool _complete = false;

  /// 卫生完成前取 token 一律拒绝（陈旧 token 秒退的根因闸门）。
  bool get readyToExtract => _complete;

  /// 页面首次（zcode.z.ai 域）finish 时消费清场窗口：返回 true=本次
  /// finish 应执行清场+导航；后续 finish 返回 false。只置"进行中"，
  /// 不开提取闸门。
  bool consumeWipeWindow() {
    if (_started) return false;
    _started = true;
    return true;
  }

  /// 清场全部落定（首清+导航+二次清）后开提取闸门。
  void markWipeComplete() => _complete = true;

  /// 错误重试等需要重走清场时复位。
  void reset() {
    _started = false;
    _complete = false;
  }
}

/// 清场 wipe 命令（18079 反馈①，2026-11-03 对抗审查 M1 修正机制叙述）：
/// 官方 web 端会话**全部存在 localStorage**（zcodejwttoken/
/// oauth:active_provider/oauth:&lt;provider&gt;:*/zcode-web-remote-last-device-sid/
/// mid/known-devices——官方源码全树零 indexedDB/sessionStorage 会话用途）。
/// 其中 last-device 两键官方 clearAll() 不清——这正是"页面自动恢复旧
/// 登录并带过期 SID 连中继吃 WRONG_PARAM=「手机连接已失效」失败卡"
/// 的根源。localStorage.clear() 全量清即根治；两键显式 removeItem +
/// sessionStorage.clear 为防御性加固。纯同步命令（无 Promise）——
/// Android evaluateJavascript 不等 Promise，任何异步段都会被紧随的
/// 导航打断，索性不做。仍整体容错（跨域文档执行会抛）。
const String kLoginWipeJs =
    "try{localStorage.removeItem('zcodejwttoken');"
    "localStorage.removeItem('oauth:active_provider');}catch(e){}"
    "try{localStorage.clear();}catch(e){}"
    "try{sessionStorage.clear();}catch(e){}"
    "'ok'";

/// 登录页目标 URL（纯函数供单测）：官方页部署版对 /remote/v4 做**参数
/// 格式校验**——无参或格式非法（sid 非规整字符集/长串、mid 非 UUID）
/// 直接渲染失败卡「手机连接已失效（Missing or invalid Web remote
/// control relay parameters）」，2026-11-03 干净浏览器双盲实证（无参/
/// 占位劣质值=失败卡；格式合法假值=登录视图；真实扫码参数=登录后直连）。
/// 故登录-only 进入（添加账号/引导登录，无真实扫码参数）合成格式合法
/// 的占位参数：OAuth 回调后页面会尝试连占位 sid 必然失败——无害，我们
/// 只为收割 token（token 写入先于页面发起连接，实测 ~500ms 内轮询即取
/// 到）。占位而非真实活跃 sid：避免页面短暂连上真实设备把本体连接踢成
/// session-conflict。
//登录-only 入口合成的 app_version（/ 常量化）：
/// 必须是官方已发布版本号（18084 实证：'app'=失败卡、'0.0.0'/'1.0.0'=
/// Not Found——部署版按已发布版本白名单校验）。官方清理旧版本白名单时
/// 此处会静默退化为失败卡——升级桌面端时须同步更新（登记
/// 台账联动项）。
const String kLoginPlaceholderAppVersion = '3.17.1';

Uri loginTargetUri(Map<String, String> qrParams) {
  final base = Uri.parse('https://zcode.z.ai/remote/v4');
  const whitelist = {'sid', 'mid', 'name', 'app_version'};
  // 长度上限（恶意/损坏二维码能塞超长串；Uri.encode 不会逃逸，但没必要
  // 把任意长度带进请求）。只做宽度限制、不做格式白名单——官方格式会漂移。
  const maxLength = {'sid': 64, 'mid': 64, 'name': 128, 'app_version': 32};
  final q = <String, String>{};
  for (final entry in qrParams.entries) {
    if (!whitelist.contains(entry.key)) continue;
    final value = entry.value.trim();
    if (value.isEmpty || value.length > (maxLength[entry.key] ?? 64)) {
      continue;
    }
    q[entry.key] = value;
  }
  // 目标设备三要素缺一不可：缺 sid/mid 的半套参数会被官方页判成失败卡，
  // 不如整体回落占位（登录-only 路径）。
  if (q['sid'] == null || q['mid'] == null) {
    q.clear();
    // 25 位字母数字（applogin+17×0； 注释对齐实测——
    // 实证 22 位纯字母亦过验，部署版只查字符集/长度形态）。
    q['sid'] = 'applogin00000000000000000';
    q['mid'] = '00000000-0000-4000-8000-000000000000'; // 标准 UUID
    q['name'] = 'ZCode Pocket';
    q['app_version'] = kLoginPlaceholderAppVersion;
  }
  return base.replace(queryParameters: q);
}

/// 官方页 localStorage 里的 provider 不是本应用写入的（同源页面可写），
/// 只接受官方 provider id 形态的字符。它会进入 JS 键名、账号展示与存储，
/// 任何引号/反斜杠/控制字符一律拒绝（返回空串）。
String sanitizeOauthProvider(String raw) {
  final value = raw.trim();
  if (value.length > 64) return '';
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) return '';
  return value;
}

/// 读 localStorage 的 JS 表达式：键用 [jsonEncode] 编码后嵌入双引号字符串，
/// 消除引号/反斜杠逃逸（旧实现单引号直插，provider 里的 `'` 可跳出字符串）。
String localStorageGetJs(String key) =>
    'localStorage.getItem(${jsonEncode(key)})';

/// 解码 [WebViewController.runJavaScriptReturningResult] 的字符串结果
///（纯函数供单测）：Android evaluateJavascript 对字符串返回 **JSON 编码
/// 形态**——外层引号+内层引号 `\"` 转义（webview_flutter_android 4.14.1
/// android_webview_controller.dart:522-534 原样透传，Dart 侧无二次解码）。
/// 剥壳必须走 jsonDecode 整体解码：手工剥首尾引号会给含引号的值（如官方
/// `oauth:<provider>:user_info` 的 JSON 文本）留下非法 `\"` 转义，下游
/// jsonDecode 必败 → identity 恒 null → bigmodel 每次重登生成新账号
///（P1-1）。'null'（JS null/键不存在）返回 null；非 JSON
/// 编码形态回落旧剥壳逻辑（个别通道原样返回的兜底）。
String? decodeWebViewJsStringResult(Object raw) {
  final s = raw.toString();
  if (s == 'null') return null;
  try {
    final decoded = jsonDecode(s);
    if (decoded is String) return decoded;
  } on FormatException {
    // 非 JSON 编码形态——回落旧剥壳逻辑。
  }
  var t = s;
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    t = t.substring(1, t.length - 1);
  }
  return t == 'null' ? null : t;
}

class _LoginPageState extends State<LoginPage> {
  /// 诊断日志（18082 真机仍失败，2026-11-03 仪器化）：登录页全程打点
  /// 到 logcat（[login] 前缀，与 [app] 同通道）——清场三步、每次 finish
  /// 的真实 URL、闸门转换、导航、提取结果。排查 ①添加账号失败的
  /// 决定性证据（此前 WebView 内部对 logcat 完全静默，只能盲猜）。
  // 诊断打点（18083-18096 排查期）：排查已收口，置为
  // 静默保留调用点——未来排查一键恢复函数体即可。
  void _diag(String line) {}
  WebViewController? _controller;
  Timer? _poll;
  bool _extracting = false;
  String? _loadError;

  /// 登录成功回调处理中（防重复 pop）。
  bool _done = false;

  /// 账号落库连续失败计数（达 5 次停止重试，页面留用户手动处置）。
  int _saveRetries = 0;

  /// 落库重试耗尽后的显式失败态（：此前 5 次失败后页面
  /// 静默死端——OAuth 已成功、轮询已停、零反馈，返回还被当“用户取消”）。
  bool _saveFailed = false;

  /// 会话卫生（2026-10-26 真机验收③立；2026-11-03 两轮对抗审查重构，
  /// 机制叙述修正）：WebView 的 zcode.z.ai localStorage/Cookie 跨会话
  /// 留存——再次进入登录页（添加账号/扫码配对）首个轮询就可能取到
  /// **陈旧 token** 秒退，且官方页的 zcode-web-remote-last-device-sid/
  /// mid 键（官方 clearAll 不清）会让页面自动恢复旧设备会话、带过期
  /// SID 连中继吃 WRONG_PARAM=「手机连接已失效」失败卡死循环。
  /// 流程：进页平台级三清（Cookie/localStorage/Cache）→ 首个官方域
  /// finish in-page 兜底清+导航回规范地址（丢弃官方 replaceState 注入
  /// 的过期 sid URL）→ 二次 finish 再清后开提取闸门。闸门未开前一切
  /// 取 token 路径拒绝——每次进入都是干净会话（须真实走一遍 OAuth）。
  final LoginSessionHygiene _hygiene = LoginSessionHygiene();

  Uri get _target => loginTargetUri(widget.qrParams);

  /// 批2-4：控制器移入 didChangeDependencies（一次性）——原在 initState
  /// 里读 context.colors（继承组件查询在 initState 非法，登录页一开即
  /// 崩的潜伏 bug，批1 迁移引入）；且此处取色随主题重建（深浅切换后
  /// 重进页面即跟随）。
  bool _controllerReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllerReady) return;
    _controllerReady = true;
    if (LoginPage.debugDisableWebView) {
      _loadError = 'WebView unavailable in this environment';
      return;
    }
    _diag('page open: qrParams=${widget.qrParams.keys.toList()}');
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 真机 2026-10-21 实测：OAuth 回调后官方页多次跳转，WebView 默认
      // 黑底在加载窗口呈全黑观感——设为页面底色消除（深色下=深底，
      // 与容器一致消除跳变）。
      ..setBackgroundColor(context.colors.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: _onPageFinished,
          onWebResourceError: (e) {
            _diag(
              'resource-error: ${e.errorCode} ${e.description} '
              'main=${e.isForMainFrame} url=${e.url}',
            );
            // OAuth 流程多次跨域重定向期间，Android
            // WebView 对主框架报 ERR_ABORTED(-1)（被新导航取代）是已知
            // 常态——不过滤会把进行中的授权流程整页换成错误视图。真实
            // 失败（DNS/TLS 等）仍走错误态。
            const errAborted = -1;
            if (e.isForMainFrame == true &&
                e.errorCode != errAborted &&
                mounted) {
              setState(() => _loadError = '${e.errorCode}: ${e.description}');
            }
          },
        ),
      );
    _controller = controller;
    // 卫生第一步（对抗审查 M1/B 采纳，2026-11-03）：平台级三清后再加载
    // ——clearLocalStorage 直接走 Android WebStorage.deleteAllData()，比
    // in-page JS 清得更早（页面 bootstrap 前凭据已不存在，官方页无从
    // "自动恢复旧登录"）；clearCache 防哈希化 JS 资产陈旧（用户失败卡
    // "点刷新还在"的另一半可能）；Cookie 清理防官方页静默续登旧身份。
    // in-page wipe 保留为二次 finish 的兜底（见 _onPageFinished）。
    unawaited(() async {
      try {
        await WebViewCookieManager().clearCookies();
        _diag('entry clear: cookies ok');
      } catch (e) {
        _diag('entry clear: cookies FAILED $e');
      }
      try {
        await controller.clearLocalStorage();
        _diag('entry clear: localStorage ok');
      } catch (e) {
        _diag('entry clear: localStorage FAILED $e');
      }
      try {
        await controller.clearCache();
        _diag('entry clear: cache ok');
      } catch (e) {
        _diag('entry clear: cache FAILED $e');
      }
      if (!mounted) return;
      _diag('entry load: $_target');
      // 导航起航失败（区别于加载失败）不再裸奔成
      // 未处理异步异常——错误态复用 _loadError 通道（重试按钮可恢复）。
      try {
        await controller.loadRequest(_target);
      } catch (e) {
        _diag('entry load FAILED: $e');
        if (mounted) setState(() => _loadError = '$e');
      }
    }());
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) {
      // WebView 不可用/错误视图态不空转轮询。
      if (_loadError != null || _controller == null) return;
      if (!_extracting) _tryExtract();
    });
  }

  /// 卫生流程（2026-11-03 对抗审查重构，两段式）：
  /// ①首个 zcode.z.ai 域 finish：in-page 兜底清一次，**立即导航回
  ///   规范地址 _target**（不是 reload()——官方页已用 replaceState 把
  ///   过期 sid/mid 写进当前 URL，reload 会原样重放=失败卡死循环；
  ///   导航同时销毁残留 JS 上下文与其在途连接，也不留 600ms 落定窗
  ///   让官方页把清掉的键写回）。
  /// ②导航后的首个 finish：再清一次（兜住上段窗口内的写回），然后
  ///   才开提取闸门（markWipeComplete）——此前一切取 token 路径拒绝。
  /// 非官方域的 finish（OAuth 提供方跳转等）不消费清场窗口。
  Future<void> _onPageFinished(String url) async {
    _diag('finish: $url');
    final host = Uri.tryParse(url)?.host ?? '';
    final isOfficial = host == 'zcode.z.ai' || host.endsWith('.zcode.z.ai');
    final controller = _controller;
    if (controller == null) return;
    if (!isOfficial) {
      // 清场未完成期间跳到第三方页：不消费窗口、不放行提取。
      if (!_hygiene.readyToExtract) {
        _diag('finish: non-official before gate -> wait');
        return;
      }
      _tryExtract();
      return;
    }
    if (_hygiene.consumeWipeWindow()) {
      _diag('hygiene: consume wipe window (first official finish)');
      try {
        await controller.runJavaScriptReturningResult(kLoginWipeJs);
        _diag('hygiene: wipe#1 dispatched');
      } catch (e) {
        _diag('hygiene: wipe#1 FAILED $e');
      }
      if (!mounted) return;
      // 立即回规范地址：丢弃官方页注入的过期 sid/mid URL（H2），
      // 并以导航终止残留页（H3：不留写回窗口）。
      _diag('hygiene: navigate canonical $_target');
      // 起航失败兜底——下轮 finish/轮询不可达时用户
      // 仍有错误视图重试出口，异常不裸奔。
      await controller.loadRequest(_target).catchError((Object e) {
        _diag('hygiene navigate FAILED: $e');
        if (mounted) setState(() => _loadError = '$e');
      });
      return;
    }
    if (!_hygiene.readyToExtract) {
      // 导航后的首个官方域 finish：二次清场兜底后开闸。
      _diag('hygiene: second-pass wipe then open gate');
      try {
        await controller.runJavaScriptReturningResult(kLoginWipeJs);
      } catch (e) {
        _diag('hygiene: wipe#2 FAILED $e');
      }
      _hygiene.markWipeComplete();
      _diag('hygiene: gate OPEN');
      if (!mounted) return;
    }
    _tryExtract();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _tryExtract() async {
    if (_done || _extracting || !_hygiene.readyToExtract || !mounted) return;
    final controller = _controller;
    if (controller == null) return;
    _extracting = true;
    try {
      // 收割面收口——只读官方 origin 的 localStorage
      //（轮询期间 WebView 可能被外链带到第三方页，该页可在自己 origin 预置
      // zcodejwttoken 让我们把任意串存为账号凭据）+ JWT 三段形态校验。
      final url = await controller.currentUrl();
      final host = Uri.tryParse(url ?? '')?.host ?? '';
      if (host != 'zcode.z.ai' && !host.endsWith('.zcode.z.ai')) {
        _diag('extract: skip non-official host=$host');
        return;
      }
      final jwt = await _readLocalStorage(controller, 'zcodejwttoken');
      if (jwt == null || jwt.isEmpty || jwt == 'null') {
        _diag('extract: no token yet (url=$url)');
        return;
      }
      if (jwt.split('.').length != 3) {
        _diag('extract: token malformed (len=${jwt.length})');
        return;
      }
      // provider 由官方页 localStorage 提供，不是可信输入：先按字符集/
      // 长度清洗再进入存储、展示与 `oauth:<provider>:user_info` 键。
      final provider = sanitizeOauthProvider(
        await _readLocalStorage(controller, 'oauth:active_provider') ?? '',
      );
      // 官方身份收割（18086 事故根因修复）：bigmodel 的 zcode JWT 零标准
      // claim，账号区分全靠官方页与 token 同步写入的
      // `oauth:<provider>:user_info`（UserInfo{id,username,displayName}，
      // refs shared/oauth.ts:140）——没有它，保存第二账号会落入内容哈希
      // 兜底并触发旧版"同 provider 覆盖"启发式=删原账号换新账号。缺失时
      // 尽力重试一拍（官方写入与 token 同步完成，正常都在）。
      var identity = await _readUserIdentity(controller, provider);
      if (identity == null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        identity = await _readUserIdentity(controller, provider);
      }
      _diag('extract: identity=${identity == null ? "absent" : "ok"}');
      if (!mounted || _done) return;
      final app = AppStateScope.of(context);
      // 先落库再置 _done（对抗审查 L7）：save 抛出时 _done 保持 false，
      // 轮询下一拍重试（token 仍在 localStorage）——否则会停在"已取消
      // 轮询+不 pop"的哑死态。连续失败 5 次放弃（保留页面让用户手动退）。
      String? savedAccountId;
      try {
        // multi-account-ux-1 批2（2026-11-04 拍板）：登录只入库不改当前
        // 账号。用 store 默认智能语义（setActive=null：仅当 lastUsed 尚
        // 空=首账号时自动设当前）—— P1-1 修正：显式 false 会把
        // 「首账号自动设当前」一并短路，全新安装后 lastUsed 永不存在，
        // 添加第二账号时"当前账号"静默翻转且 toast 撒谎。
        savedAccountId = await app.accountStore.save(
          jwt: jwt,
          provider: provider,
          identity: identity,
        );
        _diag('extract: saved account (provider=$provider)');
      } catch (e) {
        _saveRetries++;
        _diag('extract: save FAILED retries=$_saveRetries $e');
        debugPrint('[login] account save failed (retries=$_saveRetries): $e');
        if (_saveRetries >= 5) {
          // 不再静默死端——显式失败态给重试出口
          //（OAuth 已成功、token 仍在 localStorage，重试只需复位计数）。
          _done = true;
          _poll?.cancel();
          if (mounted) setState(() => _saveFailed = true);
        }
        return;
      }
      _done = true;
      _poll?.cancel();
      _diag('extract: done, halting webview then pop');
      if (!mounted) return;
      // ⑤黑屏根因链（18083/18084 两轮真机日志收口）：pop 时 WebView
      // PlatformView 的销毁若发生在"空白页尚未合成上屏"的渲染过渡态，
      // 部分设备整屏发黑（app 后端日志一切正常——纯渲染层）。修=双保障：
      // ①about:blank 停页（WebView 静止）+250ms（导航提交）；②
      // **endOfFrame 主动调度并等待下一帧完成**（不同于 addPostFrameCallback
      // 依赖外部帧活动——静止页面永无下一帧，18083 的"无反应"即此），
      // 确保空白页已真实合成上屏后才 pop，销毁发生在稳定渲染态。
      unawaited(
        controller.loadRequest(Uri.parse('about:blank')).catchError((_) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _diag('extract: frame settled, pop');
      Navigator.of(context).pop(<String, String>{
        'jwt': jwt,
        'provider': provider,
        // 刚入库的账号 id（2026-11-08 配对链）：调用方（配对页）用它
        // 作为本次配对目标——lastUsed 在「添加第二账号」时仍是旧账号，
        // 不能用来识别刚登录的账号。
        // analyze 实证此处已类型提升非空（save 返回非空 String）。
        'accountId': savedAccountId,
      });
    } catch (e) {
      // runJavaScript 在页面跳转窗口会抛——下轮轮询重试。其余异常（编程
      // 错误/状态机缺陷）至少 debugPrint 留痕（：原
      // catch(_) 全静默，排查期零线索）。
      debugPrint('[login] extract error (nav window expected): $e');
    } finally {
      _extracting = false;
    }
  }

  Future<String?> _readLocalStorage(
    WebViewController controller,
    String key,
  ) async {
    final raw = await controller.runJavaScriptReturningResult(
      localStorageGetJs(key),
    );
    // 返回形如 '"eyJ..."' 或 'null'——Android JSON 编码形态，含引号值的
    // 正确解码见 [decodeWebViewJsStringResult]（P1-1 修复）。
    return decodeWebViewJsStringResult(raw);
  }

  /// 读官方 `oauth:<provider>:user_info`（JSON 字符串）取稳定账号身份
  /// `id`（官方 UserInfo 形态，refs shared/oauth.ts:140）。读不到返回
  /// null（尽力而为：token 在而 user_info 缺失属异常窗口，调用方重试）。
  Future<String?> _readUserIdentity(
    WebViewController controller,
    String provider,
  ) async {
    final safeProvider = sanitizeOauthProvider(provider);
    if (safeProvider.isEmpty) return null;
    final raw = await _readLocalStorage(
      controller,
      'oauth:$safeProvider:user_info',
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final id = '${decoded['id'] ?? ''}'.trim();
        return id.isEmpty ? null : id;
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('账号登录'),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            color: context.colors.card,
            child: Text(
              '请选择与电脑端相同的登录平台，并使用同一账号',
              style: TextStyle(
                fontSize: AppType.uiBase,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
          if (_saveFailed) _saveFailedBanner(context),
          Expanded(
            // 错误态必须叠在 WebView 之上而不是替换它：WebViewWidget 一旦
            // 被移出树，平台视图随之销毁，重试只 loadRequest 已无宿主
            // 可显示（重试后仍停在错误页）。保持挂载+浮层覆盖。
            child: Stack(
              children: [
                if (_controller != null)
                  Positioned.fill(
                    child: WebViewWidget(controller: _controller!),
                  ),
                if (_loadError != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: context.colors.background,
                      child: _errorView(context),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 落库重试耗尽的失败横幅：人话说明+重试出口。
  Widget _saveFailedBanner(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: context.colors.destructive.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: context.colors.destructive,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已获取凭据，但保存到本机连续失败。请重试；反复失败请反馈问题。',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.destructive,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('login-save-retry'),
            onPressed: () {
              setState(() {
                _saveFailed = false;
                _saveRetries = 0;
                _done = false;
              });
              _poll?.cancel();
              _poll = Timer.periodic(const Duration(milliseconds: 700), (_) {
                if (_loadError != null || _controller == null) return;
                if (!_extracting) _tryExtract();
              });
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _errorView(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('页面加载失败（$_loadError）'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              // 重试走完整清场（对抗审查 M3）：错误页可能是中途文档，
              // reload() 会原样重放其 URL（或带过期 sid）——重置卫生
              // 状态机后回规范地址重来。
              setState(() => _loadError = null);
              _hygiene.reset();
              // 起航失败不裸奔为未处理异步异常。
              unawaited(
                _controller?.loadRequest(_target).catchError((Object e) {
                  debugPrint('[login] retry loadRequest failed: $e');
                }),
              );
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
