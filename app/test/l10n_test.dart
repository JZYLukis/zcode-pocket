import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/app.dart';
import 'package:zcode_pocket/core/localized_text.dart';

void main() {
  tearDown(L10n.resetForTest);

  test('官方静态文案、参数模板与手机端消歧', () {
    L10n.setTestLocale('en-US');
    expect(tr('归档管理'), 'Archive management');
    expect(tr('设置'), 'Settings');
    expect(tr('3 个会话'), '3 sessions');
    expect(tr('项目'), 'Project');
    expect(tr('回到本回合开始失败：x'), 'Could not return to the start of this turn: x');
  });

  test('中文原样返回；英文未命中只记录不冒充翻译', () {
    expect(tr('归档管理'), '归档管理');
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    const custom = '完全无对应的测试专用中文';
    expect(tr(custom), custom);
    expect(L10n.missingTranslations, contains(custom));
  });

  testWidgets('Text 与 Text.rich 在 build 时翻译并保留参数', (tester) async {
    L10n.setTestLocale('en-US');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('归档管理'),
              Text('3 个会话'),
              Text.rich(TextSpan(text: '回到本回合开始')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Archive management'), findsOneWidget);
    expect(find.text('3 sessions'), findsOneWidget);
    expect(find.text('Back to start of this turn'), findsOneWidget);
  });

  testWidgets('中文模式保持同一文本与组件结构', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('归档管理'))),
    );
    expect(find.text('归档管理'), findsOneWidget);
    expect(find.text('Archive management'), findsNothing);
  });

  test('数字单位、日期与手机端参数格式', () {
    L10n.setTestLocale('en-US');
    expect(tr('150万'), '1.5M');
    expect(tr('10月26日'), 'Oct 26');
    expect(tr('2026年10月26日'), 'Oct 26, 2026');
    expect(tr('已置顶 1'), '1 pinned');
    expect(tr('12 轮 · 34 次工具调用'), '12 turns · 34 tool calls');
  });

  test('断线排队条英文拼接括号成对（P1/P2/P3 三路同报）', () {
    L10n.setTestLocale('en-US');
    // 调用方（conversation_composer）按 前缀+条数+后缀 三段拼接。
    final composed =
        tr('未连接，已排队待发送（') + '2' + tr(' 条），恢复连接后自动发出');
    // 修复前：后半词条英文值丢了 `)`，开括号永悬。
    final opens = '('.allMatches(composed).length;
    final closes = ')'.allMatches(composed).length;
    expect(opens, greaterThan(0), reason: '前缀词条带开括号');
    expect(closes, opens, reason: '英文拼接串括号必须成对闭合');
  });

  testWidgets('用户数据与显式原文作用域不被翻译', (tester) async {
    L10n.setTestLocale('en-US');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('设置', translate: false),
              L10nScope(enabled: false, child: Text('归档管理')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('归档管理'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Archive management'), findsNothing);
  });

  // ── 开源审查批C组1（51 路审查 l10n 大扫除）回归锚点 ──
  // 每组修复抽代表串钉住，防后续批次再漏登记词表。
  test('批C组1：任务主页/中心/归档（L1）', () {
    L10n.setTestLocale('en-US');
    // 连接横幅与搜索分区头（带括号计数 pattern）。
    expect(tr('凭据已失效（桌面可能刷新了二维码）'),
        'Credentials expired (the desktop may have refreshed the QR code)');
    expect(tr('置顶 (3)'), 'Pinned (3)');
    expect(tr('其他工作区 (2)'), 'Other workspaces (2)');
    // run() 失败前缀的 ASCII 冒号形态。
    expect(tr('删除失败: TimeoutException'), 'Delete failed: TimeoutException');
    // 归档页三件套 + P3-1 独立键（Restore 而非 Resume）。
    expect(tr('恢复任务'), 'Restore task');
    expect(tr('已恢复「修复登录」'), 'Restored “修复登录”');
    expect(tr('将删除 12 个归档任务（不可恢复）。确定继续？'),
        'This will delete 12 archived tasks (this cannot be undone). Continue?');
  });

  test('批C组1：归档相对时间占位递归（P1 P2-2 最小修法）', () {
    L10n.setTestLocale('en-US');
    // 调用方（archived_tasks_page）在拼接前先 tr 时间片段，整串再走
    // custom pattern——两步合起来必须产出全英文。
    final composed = '归档于 ${tr('3 天前')}';
    expect(tr(composed), 'Archived 3 days ago');
  });

  test('批C组1：版本行三段前缀（P1-1）与设置/账号族（M3）', () {
    L10n.setTestLocale('en-US');
    expect(tr('本机 ') + '0.1.0-abc' + tr(' · 桌面端 ') + '3.16.3',
        'Local 0.1.0-abc · Desktop 3.16.3');
    // 删除账号确认框正文（破坏性操作必须可读）。
    expect(tr('该账号名下有 2 台电脑档案。删除后这些电脑将无法连接（档案保留，重新登录该账号即可恢复）。'),
        'This account has 2 computer profiles. After deletion, these computers cannot connect (the profiles are kept; sign in to this account again to restore them).');
    // git 分支阻塞码人话与配对失败多行 pattern。
    expect(tr('仓库里有未解决的冲突——请先在桌面端处理'),
        'The repository has unresolved conflicts — resolve them on the desktop first');
    expect(tr('连接失败：TimeoutException\n（桌面端 ZCode 需处于运行状态）'),
        'Connection failed: TimeoutException\n(ZCode must be running on the desktop)');
  });

  test('批C组1：消息渲染/输入链/弹层杂项（B2/D2/O1/O2/C1）', () {
    L10n.setTestLocale('en-US');
    expect(tr('等待中'), 'Waiting');
    expect(tr('终端 · 4 个命令，1 个失败'), 'Terminal · 4 commands, 1 failed');
    // 思考时长：片段预译 + 整串 pattern（B2-6 同根因两步走）。
    expect(tr('思考 · 持续了 ${tr('2 分 3 秒')}'), 'Thought for 2m 3s');
    expect(tr('排队中 (2) · 回合结束后自动发送'),
        'Queued (2) · auto-send when the turn ends');
    expect(tr('提交（已选 2 题）'), 'Submit (2 answered)');
    expect(tr('30 秒后自动结束'), 'Auto-resolves in 30s');
    expect(tr('3 个文件已更改'), '3 files changed');
    expect(tr('2 个子代理'), '2 subagents');
  });

  test('批C组1：重置礼包徽标与 FGS 常驻通知（N1/Q1）', () {
    L10n.setTestLocale('en-US');
    // 徽标（单机会）：倒计时片段预译后整串 pattern（N1 P2-2）。
    final badge = '1 次重置额度 · 剩余 ${tr('2 小时 3 分')}';
    expect(tr(badge), '1 reset credit · 2h 3m left');
    // FGS 常驻通知：任务标题为用户内容，pattern 捕获段必须保持原文。
    expect(tr('「修复登录」等 2 个任务运行中'),
        '“修复登录” and 2 tasks running');
    expect(tr('无任务运行'), 'No tasks running');
  });

  test('批C组1：长句 pattern 抽查（分支确认/回滚弹窗/排队省略行）', () {
    L10n.setTestLocale('en-US');
    expect(
        tr('该工作区有 2 个运行中任务。切分支对整个工作区全局生效（官方语义），运行中的会话也会受影响。确定切换到「feature/x」？'),
        'This workspace has 2 running tasks. Switching branches applies to '
        'the whole workspace (official behavior) and affects running '
        'conversations too. Switch to “feature/x”?');
    expect(
        tr('将把本轮对 3 个文件的修改恢复到本轮开始前；1 个不能安全撤销、2 个已忽略（自动跳过）。聊天记录不受影响。'),
        'Changes to 3 files will be restored to the state before this turn; '
        '1 cannot be safely undone and 2 are ignored (skipped '
        'automatically). Chat history is not affected.');
    // 源串已对齐官方词表空格口径（D2-07）。
    expect(tr('… 还有 3 条'), '… 3 more');
    expect(tr('连接失败：SocketException'), 'Connection failed: SocketException');
  });

  // ── 开源审查 批D组6（core 基础）机制回归锚点 ──
  test('数字压缩进位边界（P2 P3-6：修复前 999999→"1000K"/999999999→"1000M"）',
      () {
    L10n.setTestLocale('en-US');
    expect(tr('99.99万'), '999.9K');
    expect(tr('99.9999万'), '1M',
        reason: '999999/1000=999.999 → toStringAsFixed(2)="1000.00"，'
            '进位后必须升 M 档而非 "1000K"');
    expect(tr('99999.9999万'), '1B', reason: '同款 M→B 进位');
  });

  test('tr 结果缓存随 locale 切换整体失效（P2 P2-3/P3 P3-3 机制）', () {
    L10n.setTestLocale('en-US');
    expect(tr('设置'), 'Settings');
    expect(tr('设置'), 'Settings'); // 第二次命中缓存，可见行为不变
    L10n.setTestLocale('zh-CN');
    expect(tr('设置'), '设置', reason: '缓存必须随 locale 切换清空，不得串档');
    L10n.setTestLocale('en-US');
    expect(tr('设置'), 'Settings');
  });

  test('hasCjk 域含 CJK 标点与全角形式（P2 P3-7）', () {
    expect(hasCjk('、'), isTrue, reason: 'CJK 标点区 U+3000-303F');
    expect(hasCjk('％'), isTrue, reason: '全角形式区 U+FF00-FFEF');
    expect(hasCjk('abc 123'), isFalse);
    // 纯全角符号未命中词表时保持原文（行为不劣化）。
    L10n.setTestLocale('en-US');
    expect(tr('％'), '％');
  });

  testWidgets('system 档跟随系统语言即时生效（P3 P2-1：didChangeLocales → '
      'refresh → 根层重建——修复前需重启 app）', (tester) async {
    // 平台 locale 测试覆写跨用例粘性：显式锚定初始中文并收尾清理，
    // 否则前序用例留下的 en-US 会让首个断言失败（测试卫生）。
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    L10n.resetForTest();
    await tester.pumpWidget(const ZcodeCompanionApp());
    await tester.pump();
    expect(L10n.resolvedLocale, 'zh-CN');
    // 模拟系统语言翻转（configChanges 含 locale → Activity 不重建 →
    // 只走 PlatformDispatcher 通知，正是修复针对的路径）。
    tester.binding.platformDispatcher.localeTestValue = const Locale('en', 'US');
    tester.binding.handleLocaleChanged();
    await tester.pump();
    expect(L10n.resolvedLocale, 'en-US',
        reason: '修复前红：无 didChangeLocales 观察者，locale 翻转无人'
            '刷新，tr()/flutterLocale 停在旧语言直到进程重启');
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale?.languageCode, 'en',
        reason: 'MaterialApp.locale 须同帧跟随（根 builder 合并 '
            'L10n.changes 依赖），否则出现混合语言');
  });
}
