import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import 'app_widgets.dart';
import 'markdown_view.dart';

/// 关于 ZCode Pocket（2026-11-04 开源说明聚合批）：
/// 设置-关于组的唯一入口——把原先散落在 README / LICENSE /
/// THIRD-PARTY-NOTICES / NOTICE-ZCode 里的说明搬进 app：非官方声明、
/// 服务条款提示、隐私说明、项目许可证、第三方来源声明、依赖许可。
/// 文档内容不改写（许可证/声明原文照搬资产文件），只做呈现。
class AboutZcodePocketPage extends StatefulWidget {
 /// 测试/游览缝：跳过原生版本通道，固定展示值。
  final String? versionOverride;

  const AboutZcodePocketPage({super.key, this.versionOverride});

  @override
  State<AboutZcodePocketPage> createState() => _AboutZcodePocketPageState();
}

class _AboutZcodePocketPageState extends State<AboutZcodePocketPage> {
  String? _version;

  @override
  void initState() {
    super.initState();
    final override = widget.versionOverride;
    if (override != null && override.trim().isNotEmpty) {
      _version = override;
      return;
    }
    const MethodChannel('companion/appinfo')
        .invokeMethod<Map>('get')
        .then((res) {
          final raw = res?['versionName'];
          final name = raw is String && raw.trim().isNotEmpty ? raw : null;
          if (mounted && name != null) setState(() => _version = name);
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(
          tr('关于 ZCode Pocket'),
          style: const TextStyle(fontSize: AppType.uiLg),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _header(context),
          const AppSectionHeader('声明'),
          _paragraph(
            context,
            tr('本项目为社区驱动的第三方客户端，与 ZCode / 智谱无关联、'
                '未经其授权或认可；ZCode 名称归其所有者。'),
          ),
          const SizedBox(height: 8),
          _paragraph(
            context,
            tr('使用本应用连接 ZCode 官方服务时，须自行遵守官方服务条款：'
                '现行条款默认限非商业的个人研究学习用途，商业使用需与官方另行约定。'),
          ),
          const AppSectionHeader('隐私'),
          _paragraph(
            context,
            tr('本应用无遥测、无第三方统计；聊天与任务数据只连你配置的 '
                'ZCode 桌面端 / 官方服务。凭据保存在系统安全存储，'
                '系统云备份已关闭。'),
          ),
          const SizedBox(height: 8),
          _paragraph(
            context,
            tr('锁屏默认可能显示通知内容：任务标题与最近回复的前 60 字；'
                '可在系统设置中隐藏敏感通知或关闭锁屏通知。'),
          ),
          const AppSectionHeader('开源'),
          ListTile(
            key: const ValueKey('about-project-license'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined, size: 20),
            title: Text(
              tr('项目许可证（Apache 2.0）'),
              style: const TextStyle(fontSize: AppType.uiBase),
            ),
            subtitle: Text(
              tr('Apache License 2.0 全文随包分发'),
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openText(
              context,
              asset: 'LICENSE',
              title: tr('项目许可证'),
              markdown: false,
            ),
          ),
          ListTile(
            key: const ValueKey('about-third-party-notices'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.handshake_outlined, size: 20),
            title: Text(
              tr('第三方来源声明'),
              style: const TextStyle(fontSize: AppType.uiBase),
            ),
            subtitle: Text(
              tr('移植来源、品牌图标与商标说明'),
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openText(
              context,
              asset: 'THIRD-PARTY-NOTICES.md',
              title: tr('第三方来源声明'),
              markdown: true,
            ),
          ),
          ListTile(
            key: const ValueKey('about-dependency-licenses'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2_outlined, size: 20),
            title: Text(
              tr('开源依赖许可'),
              style: const TextStyle(fontSize: AppType.uiBase),
            ),
            subtitle: Text(
              tr('随安装包分发的第三方依赖许可文本'),
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'ZCode Pocket',
              applicationLegalese:
                  tr('非官方第三方客户端，与 ZCode/智谱无关联。') +
                  '\n' +
                  tr('第三方来源详见仓库 THIRD-PARTY-NOTICES.md。'),
            ),
          ),
          const AppSectionHeader('版权'),
          _paragraph(context, 'Copyright © 2026 JZYLukis and ZCode Pocket contributors'),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final version = _version;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: context.colors.brand,
              borderRadius: BorderRadius.circular(AppRadius.block),
            ),
 // 字阶守卫（R3）：标记字号走 uiXl；Container 宽高给出紧约束，
 // Padding 内收后 FittedBox 真正放大到约 50% 块宽（视觉代理
 // 复核：此前 FittedBox 在松约束下只守字号、实际未放大）。
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  'Z',
                  style: TextStyle(
                    fontSize: AppType.uiXl,
                    fontWeight: FontWeight.w700,
                    color: context.colors.onBrand,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ZCode Pocket',
                  style: TextStyle(
                    fontSize: AppType.uiXl,
                    fontWeight: FontWeight.w600,
                    color: context.colors.foreground,
                  ),
                ),
                if (version != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    version,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  tr('ZCode 桌面端的非官方安卓客户端'),
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _paragraph(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppType.uiCaption,
          height: 1.6,
          color: context.colors.foregroundSubtle,
        ),
      ),
    );
  }

  void _openText(
    BuildContext context, {
    required String asset,
    required String title,
    required bool markdown,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LicenseTextPage(
          asset: asset,
          title: title,
          markdown: markdown,
        ),
      ),
    );
  }
}

/// 许可/声明全文页：资产原文直出（LICENSE 用等宽可选中；Markdown 声明
/// 用现有 MarkdownView 渲染，避免 `#` 记号裸露）。
class LicenseTextPage extends StatefulWidget {
  final String asset;
  final String title;
  final bool markdown;

  const LicenseTextPage({
    super.key,
    required this.asset,
    required this.title,
    this.markdown = false,
  });

  @override
  State<LicenseTextPage> createState() => _LicenseTextPageState();
}

class _LicenseTextPageState extends State<LicenseTextPage> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<String> _load() => rootBundle.loadString(widget.asset);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('读取失败'),
                    style: TextStyle(color: context.colors.foregroundSubtle),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _future = _load()),
                    child: Text(tr('重试')),
                  ),
                ],
              ),
            );
          }
          final text = snapshot.data!;
          if (widget.markdown) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              child: MarkdownView(data: text, codeHighlightEnabled: false),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: AppType.uiCaption,
                height: 1.5,
                color: context.colors.foreground,
              ),
            ),
          );
        },
      ),
    );
  }
}
