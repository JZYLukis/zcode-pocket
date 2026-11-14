// 应用内更新——流程编排与 UI（in-app-update-1）。
// checkAndPrompt：统一入口（manual=true 跳过 24h 节流并给无更新反馈）。
// 静默检查由 app 启动 30s 后触发（失败无感）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../core/update_check.dart';
import '../core/update_download.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart' show showConfirmDialog;

/// 根 Navigator key（静默检查从 app 层弹窗用；app.dart 挂到 MaterialApp）。
final updateNavigatorKey = GlobalKey<NavigatorState>();

const _channel = MethodChannel('companion/update');

Future<T?> _invoke<T>(String method, [Object? args]) {
  return _channel.invokeMethod<T>(method, args);
}

/// 统一更新入口。
Future<void> checkAndPrompt(BuildContext context, {bool manual = false}) async {
  final app = AppStateScope.of(context);
  final ui = app.uiPrefs;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!manual) {
    // 静默：24h 节流。
    if (now - ui.updateLastCheckAt < 24 * 60 * 60 * 1000) return;
  }
  UpdateInfo info;
  try {
    info = await fetchLatestRelease();
  } catch (_) {
    if (manual) {
      _snack(context, tr('检查更新失败，请稍后再试'));
    }
    return;
  }
  await ui.setUpdateLastCheckAt(now);

  final currentVersion = await _currentVersionName();
  if (currentVersion == null) {
    // 版本获取失败≠无更新（②：不得谎报"已是最新"）。
    if (manual) _snack(context, tr('检查更新失败，请稍后再试'));
    return;
  }
  if (!isNewerVersion(info.version, currentVersion)) {
    if (manual) _snack(context, tr('已是最新版本'));
    return;
  }

  if (!context.mounted) return;
  await _showUpdateDialog(context, info);
}

Future<String?> _currentVersionName() async {
  // 对抗审查 ④/②：版本号在 companion/appinfo 的 get（companion/update
  // 无此方法——此前错调导致 MissingPluginException 被吞，永远"已是最新"）。
  try {
    final res = await const MethodChannel('companion/appinfo')
        .invokeMethod<Map<dynamic, dynamic>>('get');
    return res?['versionName'] as String?;
  } catch (_) {
    return null;
  }
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

Future<void> _showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final doUpdate = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(tr('发现新版本')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'v${info.version}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppType.uiBase),
          ),
          const SizedBox(height: 8),
          if (info.notes.isNotEmpty)
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  info.notes,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    height: 1.5,
                    color: Theme.of(dctx).colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx, false),
          child: Text(tr('稍后')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dctx, true),
          child: Text(tr('立即更新')),
        ),
      ],
    ),
  );
  if (doUpdate != true) return;
  if (!context.mounted) return;
  await _runUpdate(context, info);
}

Future<void> _runUpdate(BuildContext context, UpdateInfo info) async {
  final app = AppStateScope.of(context);
  if (!app.uiPrefs.updateInAppEnabled) {
    _snack(context, tr('应用内更新已关闭，请到 GitHub Releases 手动下载'));
    return;
  }
  // 签名检测：自行构建包（debug/自签）无法覆盖安装官方包。
  try {
    final official = await _invoke<bool>('officialSignatureMatches');
    if (official != true) {
      if (context.mounted) {
        _snack(context, tr('当前为自行构建版本，无法应用内更新到官方包（签名不同），请手动下载安装'));
      }
      return;
    }
  } catch (_) {}

  final abi = await _invoke<String>('abi') ?? 'unknown';
  final asset = info.assetForAbi(abi);
  if (asset == null) {
    if (context.mounted) _snack(context, tr('未找到适配本机架构的安装包'));
    return;
  }

  // 移动数据先问流量（~31MB）。
  final netType = await _invoke<String>('networkType') ?? 'other';
  if (netType == 'cellular') {
    final ok = await showConfirmDialog(
      context,
      title: tr('使用移动数据下载？'),
      message: tr('安装包约 31MB，当前在移动网络下'),
      confirmLabel: tr('继续下载'),
      destructive: false,
    );
    if (!ok) return;
  }

  // 安装授权（API 26+）：未授权跳设置页，用户回来后重新点更新。
  try {
    final can = await _invoke<bool>('canInstall');
    if (can != true) {
      await _invoke<void>('openInstallSettings');
      if (context.mounted) {
        _snack(context, tr('请在系统设置中允许本应用安装应用，然后回来重新点「立即更新」'));
      }
      return;
    }
  } catch (_) {}

  if (!context.mounted) return;
  await _downloadAndInstall(context, info, asset);
}

Future<void> _downloadAndInstall(
  BuildContext context,
  UpdateInfo info,
  UpdateAsset asset,
) async {
  final tmpDir = await getTemporaryDirectory();
  final dir = Directory('${tmpDir.path}/updates');
  await dir.create(recursive: true);
  final file =
      File('${dir.path}/${updateApkFileName(info.version, asset.name)}');

  final downloader = UpdateDownload();
  var failed = false;
  var cancelled = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dctx) => _DownloadDialog(
      downloader: downloader,
      url: asset.url,
      file: file,
      onDone: () => Navigator.pop(dctx),
      onFail: () {
        failed = true;
        Navigator.pop(dctx);
      },
      onCancel: () {
        cancelled = true;
        downloader.cancel();
        Navigator.pop(dctx);
      },
    ),
  );
  downloader.dispose(); // ②：中止在途请求并释放连接
  if (cancelled) return;
  if (failed) {
    if (context.mounted) {
      _snack(context, tr('下载失败，请稍后重试（重试会从断点继续）'));
    }
    return;
  }

  // SHA-256 校验（信任锚：任何渠道的字节对不上官方哈希即拒装）。
  final ok = await UpdateDownload.verifyAndCleanup(file, asset.sha256Hex);
  if (!ok) {
    if (context.mounted) _snack(context, tr('安装包校验失败（可能被篡改或下载不完整），已删除，请重试'));
    return;
  }
  // 对抗审查 ②：SHA 只锚到 API 响应——安装前再用原生校验 APK 文件的
  // 包名与官方签名指纹（fail-closed），把信任锚提升到官方签名本身。
  try {
    final verified = await _invoke<bool>('verifyApk', {'path': file.path});
    if (verified != true) {
      await file.delete().catchError((_) => file);
      if (context.mounted) {
        _snack(context, tr('安装包校验失败（可能被篡改或下载不完整），已删除，请重试'));
      }
      return;
    }
  } catch (_) {}
  final opened = await _invoke<bool>('openApk', {'path': file.path}) == true;
  if (!opened && context.mounted) {
    _snack(context, tr('无法调起安装器，请到 GitHub Releases 手动下载'));
  }
  // 调起安装器后收不到可靠结果——下次启动以 versionName 判定是否升级。
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({
    required this.downloader,
    required this.url,
    required this.file,
    required this.onDone,
    required this.onFail,
    required this.onCancel,
  });

  final UpdateDownload downloader;
  final String url;
  final File file;
  final VoidCallback onDone;
  final VoidCallback onFail;
  final VoidCallback onCancel;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  double? _progress; // null=不定（未知总长）
  String _error = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = '');
    try {
      await widget.downloader.download(
        widget.url,
        widget.file,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total != null && total > 0 ? received / total : null;
          });
        },
      );
      widget.onDone();
    } on UpdateDownloadException {
      if (mounted) {
        setState(() => _error = 'failed');
      } else {
        widget.onFail();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 对抗审查 ②M2：系统返回键必须走取消（barrierDismissible 挡不住
      // 返回键）——否则下载在后台继续、校验读到半截文件误报、甚至安装
      // 器仍然弹出。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onCancel();
      },
      child: AlertDialog(
      title: Text(tr('正在下载更新')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: _progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          const SizedBox(height: 8),
          if (_error.isNotEmpty)
            Text(tr('下载失败'), style: TextStyle(color: context.colors.destructive))
          else if (_progress != null)
            Text('${(_progress! * 100).toStringAsFixed(0)}%')
          else
            Text(tr('准备中…')),
        ],
      ),
      actions: [
        if (_error.isNotEmpty)
          FilledButton(
            onPressed: _start,
            child: Text(tr('重试')),
          ),
        TextButton(
          onPressed: widget.onCancel,
          child: Text(_error.isEmpty ? tr('取消') : tr('关闭')),
        ),
      ],
      ),
    );
  }
}
