import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show MethodChannel;

import '../core/localized_text.dart';
import '../core/l10n.dart';

import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../state/device_stack_registry.dart' show AccountRebindRequired;
import '../transport/connection_params.dart';
import 'device_list_page.dart';
import 'login_page.dart';
import 'qr_scan_page.dart';

/// 添加电脑（配对）：扫码 或 粘贴桌面端生成的远控链接 → 命名 → 连接。
/// 凭据撤销路径：旧档案失效后重新扫码，同 sid 档案自动复活（ProfileStore.upsert）。
class PairingPage extends StatefulWidget {
  const PairingPage({super.key, this.prefillUrl});

  /// 重扫场景预填旧链接（通常应清空重扫）。
  final String? prefillUrl;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  /// 本会话是否用过相机扫码（18093 扫码黑屏终局：相机会话开合会在
  /// 部分华为机型楔死渲染管线——无预览纹理也复现；用过扫码则在配对
  /// 成功后主动重建 Activity 换新表面，确定性消除黑屏）。
  static const _surface = MethodChannel('companion/surface');
  bool _usedScanner = false;

  late final TextEditingController _url;
  late final TextEditingController _name;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.prefillUrl ?? '');
    _name = TextEditingController();
    _url.addListener(_syncName);
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  /// 设备命名默认取 URL 的 name 参数（桌面主机名；V1/V2 参数都认）。
  void _syncName() {
    final params = CompanionConnectionParams.parse(_url.text);
    final v2 = params == null ? parseCompanionV2Params(_url.text) : null;
    final name = params?.deviceName ?? v2?.deviceName;
    if (name != null && (_name.text.isEmpty || _name.text == _lastAutoName)) {
      _lastAutoName = name;
      _name.text = name;
    }
  }

  String? _lastAutoName;

  Future<void> _scan() async {
    _usedScanner = true;
    final raw = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (raw != null && mounted) {
      _url.text = raw;
      _syncName();
    }
  }

  Future<void> _connect(AppState app) async {
    if (_connecting) return;
    final params = CompanionConnectionParams.parse(_url.text);
    if (params == null) {
      // V2 链接路由（ADR 0032）：官方 origin 且带 V2 参数的链接 → 账号
      // 流程（isV2PairingUrl 谓词见 connection_params.dart）。
      if (isV2PairingUrl(_url.text)) {
        await _connectV2(app, parseCompanionV2Params(_url.text)!);
        return;
      }
      debugPrint(
        '[app] pairing url parse failed '
        '(len=${_url.text.length})',
      );
      // 开源审查 M2 P3-10：V2 形态（含 sid 参数）但 host 非官方的链接，
      // 报“缺 sid/hash/t 参数”指错方向——分叉提示真实缺失项（官方 origin）。
      final uri = Uri.tryParse(_url.text.trim());
      final hasV2Shape =
          uri != null &&
          uri.queryParameters.keys.any(
            (k) => const {'sid', 'hash', 't'}.contains(k),
          );
      setState(
        () => _error = hasV2Shape
            ? '链接无效：需官方 zcode.z.ai 生成的远控链接（当前链接的域名不受支持）'
            : '链接无效：需要桌面端生成的完整远控链接（含 sid/hash/t 参数）',
      );
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    debugPrint('[app] pairing connect: len=${_url.text.length}');
    try {
      await app.addComputer(_url.text.trim(), label: _name.text);
      if (!mounted) return;
      // 开源审查 M2 P2-2：V1 路径同接“扫码后重建 Activity”防线（相机
      // 会话开合即触发面，与协议版本无关）；纯粘贴路径零打扰。
      if (_usedScanner) {
        debugPrint('[pairing-perf] scanner used (v1), recreating activity');
        await _surface
            .invokeMethod('recreate', {'reason': 'paired'})
            .catchError((_) {});
        return;
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '连接失败：$e\n（桌面端 ZCode 需处于运行状态）';
        });
      }
    }
  }

  /// V2 连接流程（新版桌面 3.16+）：未登录先走官方 OAuth（WebView）；
  /// 带 sid → 直接建档案连该桌面（扫码场景）；无 sid → 设备列表选电脑。
  Future<void> _connectV2(AppState app, CompanionV2Params params) async {
    // 开源审查 M3 P2-1：入口即置闸门——hasAccount 读取（secure storage
    // 异步窗口）+ LoginPage 路由 barrier 挂载前的一帧可被双击，双推
    // 登录页、成功后双 pop 弹穿底层页。V1 路径同款闸门早已有之。
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final loggedIn = await app.hasAccount;
      if (!mounted) return;
      if (!loggedIn) {
        final qr = {
          if (params.deviceSid != null) 'sid': params.deviceSid!,
          if (params.deviceMid != null) 'mid': params.deviceMid!,
          if (params.deviceName != null) 'name': params.deviceName!,
          if (params.appVersion != null) 'app_version': params.appVersion!,
        };
        final result = await Navigator.of(context).push<Map<String, String>>(
          MaterialPageRoute(builder: (_) => LoginPage(qrParams: qr)),
        );
        if (result == null) return; // 用户取消登录
        if (!mounted) return;
      }
      if (params.deviceSid == null) {
        await Navigator.of(context).push(
          // accountId=null=lastUsed：登录页 save() 落库即切 lastUsed，
          // 此刻 null 恰为刚登录账号（开源审查 M1 P3-11 显式化——
          // multi-account-ux-1 实施后须改为显式传登录返回的账号 id）。
          MaterialPageRoute(
            builder: (_) => const DeviceListPage(accountId: null),
          ),
        );
        return;
      }
      debugPrint('[pairing-perf] v2 connect begin sid=${params.deviceSid}');
      await _addProfileResolvingRebind(app, params);
      debugPrint('[pairing-perf] addV2Profile done');
      if (!mounted) return;
      // 18093 扫码黑屏终局（ADR 0080 §9）：相机会话开合（cameraX，与
      // 预览纹理无关）在部分华为机型把渲染管线楔死（agent 实证 2/4，
      // 三层防御+去纹理均不治）。用过扫码→配对成功后重建 Activity
      // 换新表面，确定性消除；纯粘贴路径零打扰。
      if (_usedScanner) {
        debugPrint('[pairing-perf] scanner used, recreating activity');
        await _surface
            .invokeMethod('recreate', {'reason': 'paired'})
            .catchError((_) {});
        return;
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '连接失败：$e\n（桌面端需 3.16+ 且与手机同账号在线）';
        });
      }
    } finally {
      // 成功路径页面即将销毁（pop/recreate），失败/取消复位闸门。
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('添加电脑'),
        automaticallyImplyLeading: app.profiles.isNotEmpty, // 首次使用不可返回（无别处可去）
      ),
      body: SafeArea(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.colors.accent,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.desktop_windows_outlined, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '在电脑上打开 ZCode → 设置 → 远程控制，点击「手机连接」显示二维码；'
                      '用本机扫码，或复制链接粘贴到下方。链接即凭据，请勿转发他人。',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foreground,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _connecting ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码添加'),
            ),
            const SizedBox(height: 8),
            // V2 账号登录（ADR 0032）：新版桌面（3.16+）凭据核心=同账号
            // 登录，扫码只是快捷方式——登录后可直接从设备列表选电脑。
            if (L10n.resolvedLocale == 'en-US')
              OutlinedButton(
                key: const ValueKey('account-login-entry'),
                onPressed: _connecting
                    ? null
                    : () => _connectV2(
                        app,
                        CompanionV2Params(
                          source: Uri.parse('https://zcode.z.ai/remote/v4'),
                        ),
                      ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text(
                  '账号登录（新版桌面 3.16+）',
                  maxLines: 2,
                  textAlign: TextAlign.center,
                ),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('account-login-entry'),
                onPressed: _connecting
                    ? null
                    : () => _connectV2(
                        app,
                        CompanionV2Params(
                          source: Uri.parse('https://zcode.z.ai/remote/v4'),
                        ),
                      ),
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('账号登录（新版桌面 3.16+）'),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Expanded(child: Divider()),
                  if (L10n.resolvedLocale == 'en-US')
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: const Text(
                          '或粘贴链接',
                          maxLines: 2,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('或粘贴链接'),
                    ),
                  Expanded(child: Divider()),
                ],
              ),
            ),
            TextField(
              controller: _url,
              enabled: !_connecting,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontSize: AppType.mobileInputSafe),
              decoration: InputDecoration(
                hintText: tr('https://zcode.z.ai/remote/v4?sid=…'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              enabled: !_connecting,
              style: const TextStyle(fontSize: AppType.mobileInputSafe),
              decoration: InputDecoration(
                labelText: tr('电脑备注名（可选）'),
                hintText: tr('如：书房台式机'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: context.colors.destructive,
                  fontSize: AppType.uiCaption,
                ),
              ),
            ],
            const SizedBox(height: 16),
            // V1 审美优化：主次分级——"扫码添加"是推荐路径保持黑实心，
            // "连接"降级黑描边白底（此前两个同权重黑实心大按钮，评审 2.4）。
            OutlinedButton(
              onPressed: _connecting ? null : () => _connect(app),
              child: _connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('连接'),
            ),
          ],
        ),
      ),
    );
  }
  /// 回测组3 P2-2：配对路径同设备列表——同一台电脑改绑账号（当前
  /// lastUsed 与既有绑定不同）属破坏性操作，弹确认后 forceRebind。
  Future<void> _addProfileResolvingRebind(
    AppState app,
    dynamic params,
  ) async {
    try {
      await app.addV2Profile(params, label: _name.text);
      return;
    } on AccountRebindRequired catch (e) {
      if (!mounted) rethrow;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('改绑这台电脑的账号？'),
          content: Text(
            '该电脑当前绑定账号 ${e.fromAccountId}，将改为 ${e.toAccountId}。'
            '改绑后旧账号在此电脑上的连接会失效。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('改绑'),
            ),
          ],
        ),
      );
      if (ok != true) {
        if (mounted) setState(() => _connecting = false);
        return;
      }
      await app.addV2Profile(params,
          label: _name.text, forceRebind: true);
    }
  }

}

