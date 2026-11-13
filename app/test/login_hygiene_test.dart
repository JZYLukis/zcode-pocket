import 'dart:convert' show jsonDecode;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/login_page.dart';

/// 登录页会话卫生（2026-10-26 真机验收③立红绿；2026-11-03 两轮对抗
/// 审查重构两段式状态机并修正机制叙述）：官方远控页把会话与"记住的
/// 设备"（zcode-web-remote-last-device-sid/mid，官方 clearAll 不清）
/// 全存在 localStorage，还会用 replaceState 把过期 sid 写进当前 URL。
/// 残留会让页面自动恢复旧登录、带过期 SID 连中继吃 WRONG_PARAM=
/// 「手机连接已失效」失败卡死循环（真机反馈①实证）。
/// 状态机两段式：首个官方域 finish 只消费清场窗口（不置 ready——
/// 旧一阶段版在置位与 wipe 求值间留窗口，700ms 轮询可抢读旧 token）；
/// 清场+导航回规范地址+二次清全部落定后 markWipeComplete 才放行取
/// token。WebView 真实时序（官方 origin+OAuth）沙箱不可复现——判定
/// 抽纯类钉行为，真机旅程留真机复验（批次证据 uncovered）。
void main() {
  test('consume 只置"进行中"不置 ready——窗口消费后、完成前取 token 仍拒绝', () {
    final h = LoginSessionHygiene();
    expect(h.readyToExtract, isFalse,
        reason: '红：修复前无此闸门——首个轮询即取陈旧 token 秒退');
    expect(h.consumeWipeWindow(), isTrue, reason: '首个官方域 finish=清场窗口');
    expect(h.readyToExtract, isFalse,
        reason: '红（审查 M2）：旧版 consume 即置 ready——置位与 wipe JS '
            '求值之间留窗口，轮询可抢在清除前读到旧 token');
  });

  test('清场窗口只消费一次；markWipeComplete 后才放行', () {
    final h = LoginSessionHygiene();
    expect(h.consumeWipeWindow(), isTrue);
    expect(h.consumeWipeWindow(), isFalse, reason: '第二次 finish 不再清场导航');
    expect(h.readyToExtract, isFalse);
    h.markWipeComplete();
    expect(h.readyToExtract, isTrue, reason: '清场+导航+二次清全部落定才放行');
  });

  test('reset 后可重走完整清场（错误重试用）', () {
    final h = LoginSessionHygiene();
    expect(h.consumeWipeWindow(), isTrue);
    h.markWipeComplete();
    h.reset();
    expect(h.readyToExtract, isFalse);
    expect(h.consumeWipeWindow(), isTrue, reason: '重试=从头再清场');
  });

  test('wipe 为纯同步命令：清两凭据键+localStorage 全量+sessionStorage 兜底', () {
    expect(kLoginWipeJs, contains("localStorage.removeItem('zcodejwttoken')"));
    expect(
      kLoginWipeJs,
      contains("localStorage.removeItem('oauth:active_provider')"),
    );
    // 机制修正（审查）：官方 web 端零 indexedDB 会话用途——有效
    // 成分是 localStorage.clear()（根治点：官方页自己不清的 last-device
    // 两键也在其中，页面无从自动恢复旧设备会话）。纯同步、无 Promise
    //（Android evaluateJavascript 不等 Promise，异步段会被紧随的导航
    // 打断——旧版 async IIFE 的 IDB 段是死代码且拖慢导航）。
    expect(kLoginWipeJs, contains('localStorage.clear()'));
    expect(kLoginWipeJs, contains('sessionStorage.clear()'));
    expect(kLoginWipeJs.contains('indexedDB'), isFalse,
        reason: '官方页不用 IndexedDB——异步删除段已裁');
    expect(kLoginWipeJs.contains('async'), isFalse,
        reason: '纯同步命令：不得含会被导航打断的异步段');
    // 每段仍各自容错（跨域文档执行会抛）。
    expect(kLoginWipeJs.split('catch(e){').length, greaterThan(2),
        reason: '各清理段独立 catch');
  });

  test('登录-only 进入合成格式合法占位参数（①根因：部署版无参=恒失败卡）', () {
    final uri = loginTargetUri(const {});
    expect(uri.host, 'zcode.z.ai');
    expect(uri.path, '/remote/v4');
    final q = uri.queryParameters;
    // 实证格式要求：sid 规整字符集长串（22 位纯字母实测过验）、mid 标准
    // UUID——劣质占位值（含连字符短串）实测被拒「Missing or invalid
    // Web remote control relay parameters」。
    expect(q['sid'], isNotNull);
    expect(q['sid']!.length, greaterThanOrEqualTo(22),
        reason: '短占位值实测被官方参数校验拒绝');
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(q['mid'] ?? ''),
      isTrue,
      reason: 'mid 须为标准 UUID 格式',
    );
    // 实证：app_version 按官方已发布版本白名单校验——'app'=失败卡、
    // '0.0.0'/'1.0.0'=Not Found，必须是真实发布版本号形态（如 3.17.1）。
    expect(
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(q['app_version'] ?? ''),
      isTrue,
      reason: 'app_version 须为 x.y.z 发布版本号（白名单校验）',
    );
    expect(q.containsKey('hash'), isFalse,
        reason: 'hash/t 是官方显式拒绝的参数，永不得出现');
    expect(q.containsKey('t'), isFalse);
  });

  test('扫码参数原样透传且白名单过滤（真实 sid 优先于占位）', () {
    final uri = loginTargetUri(const {
      'sid': 'd_RealSid_0000000000000',
      'mid': '11111111-2222-4333-8444-555555555555',
      'name': '我的电脑',
      'app_version': '3.17.1',
      'hash': 'evil',
      't': '123',
    });
    final q = uri.queryParameters;
    expect(q['sid'], 'd_RealSid_0000000000000');
    expect(q['mid'], '11111111-2222-4333-8444-555555555555');
    expect(q['name'], '我的电脑');
    expect(q['app_version'], '3.17.1');
    expect(q.containsKey('hash'), isFalse, reason: '白名单外参数剔除');
    expect(q.containsKey('t'), isFalse);
  });

  // 恶意/损坏二维码：Uri 编码不会造成 URL 逃逸，但超长串与半套参数
  // 会把官方页拖进失败卡。超长键整键丢弃；缺 sid/mid 整体回落占位。
  test('超长扫码参数与半套参数不生成畸形目标 URL', () {
    const mid = '11111111-2222-4333-8444-555555555555';
    final bogusSid = 'a' * 65;
    final bogusName = '名' * 129;

    final broken = loginTargetUri({
      'sid': bogusSid,
      'mid': mid,
      'name': bogusName,
    });
    expect(broken.queryParameters['sid'], 'applogin00000000000000000',
        reason: '缺有效 sid/mid 时整体回落占位（登录-only 路径）');
    expect(broken.queryParameters['name'], 'ZCode Pocket');

    final partial = loginTargetUri({
      'sid': 'd_RealSid_0000000000000',
      'mid': mid,
      'name': bogusName,
    });
    expect(partial.queryParameters['sid'], 'd_RealSid_0000000000000');
    expect(partial.queryParameters['mid'], mid);
    expect(partial.queryParameters['name'], isNull,
        reason: '仅超长 name 被剔除，其余有效参数保留');
  });

  // provider 来自官方页 localStorage（同源页面可写），不是可信输入：
  // 它会进入 `oauth:<provider>:user_info` 键名与账号展示。字符集白名单
  // 是纵深防御（即使官方页被注入，也不能借 provider 跳出 JS 字符串）。
  test('provider 白名单：官方 id 放行，引号/反斜杠/超长拒绝', () {
    expect(sanitizeOauthProvider('bigmodel'), 'bigmodel');
    expect(sanitizeOauthProvider(' z.ai-1_2 '), 'z.ai-1_2',
        reason: '去首尾空白，官方 id 允许字母数字点下划线连字符');
    expect(sanitizeOauthProvider("x');localStorage.clear();//"), '');
    expect(sanitizeOauthProvider(r"x\');alert(1)//"), '');
    expect(sanitizeOauthProvider('a"b'), '');
    expect(sanitizeOauthProvider('a' * 65), '');
    expect(sanitizeOauthProvider(''), '');
  });

  // 旧实现把键单引号直插 JS：provider 含 ' 就能跳出字符串。改成
  // jsonEncode 后双引号包裹，双引号/反斜杠都被转义，键只可能是字面量。
  test('localStorage 键以 JSON 字面量嵌入 JS（引号注入被转义）', () {
    expect(
      localStorageGetJs('zcodejwttoken'),
      'localStorage.getItem("zcodejwttoken")',
    );
    expect(
      localStorageGetJs('a");localStorage.clear();//'),
      r'localStorage.getItem("a\");localStorage.clear();//")',
    );
  });

  // Android WebView evaluateJavascript 对字符串结果返回
  // JSON 编码形态（外层引号+内层引号 \" 转义，webview_flutter_android
  // 4.14.1 实证）——只剥外层引号不反转义，oauth:<provider>:user_info 的
  // jsonDecode 必败 → identity 恒 null → bigmodel 每次重登生成新账号。
  test('WebView 返回值解码：含引号值（user_info JSON 文本）整串读回', () {
    // Android 原样返回的编码形态：{"id":"u-1"} 存进 localStorage 后经
    // getItem 读回，内层引号全部带 \" 转义。
    const encoded = '"{\\"id\\":\\"早前批次\\",\\"username\\":\\"zhang\\"}"';
    expect(
      decodeWebViewJsStringResult(encoded),
      '{"id":"早前批次","username":"zhang"}',
      reason: '修复前（手工剥首尾引号）得到 {\\\"id\\\":...}——反斜杠在 JSON '
          '串外非法，下游 jsonDecode 必败',
    );
    // 读回值可直接被身份收割解析。
    final identity = jsonDecode(decodeWebViewJsStringResult(encoded) ?? '');
    expect((identity as Map)['id'], '早前批次');
  });

  test('WebView 返回值解码：JWT/无引号兜底/null 边界', () {
    expect(decodeWebViewJsStringResult('"eyJhbGciOi.payload.sig"'),
        'eyJhbGciOi.payload.sig',
        reason: 'JWT 形态（原修复目标路径）不受影响');
    expect(decodeWebViewJsStringResult('null'), isNull,
        reason: 'JS null（键不存在）');
    expect(decodeWebViewJsStringResult('"say \\"hi\\" ok"'), 'say "hi" ok',
        reason: '值内引号转义正确还原');
    expect(decodeWebViewJsStringResult('plain-no-quotes'), 'plain-no-quotes',
        reason: '非 JSON 编码形态回落旧剥壳逻辑（个别通道原样返回兜底）');
  });
}
