import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/ui/settings_page.dart';

class _MemStorage extends FlutterSecureStorage {
  final data = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
  }
}

class _LocaleApp extends AppState {
  _LocaleApp(this.uiPrefs);
  @override
  final UiPrefs uiPrefs;
}

void main() {
  tearDown(L10n.resetForTest);

  test('语言偏好落盘往返与非法值回落', () async {
    final storage = _MemStorage();
    final first = UiPrefs(storage: storage);
    await first.setLocalePreference('en-US');
    expect(storage.data['ui.localePreference'], 'en-US');
    final second = UiPrefs(storage: storage);
    await second.load();
    expect(second.localePreference, 'en-US');
    await second.setLocalePreference('invalid');
    expect(second.localePreference, 'system');
  });

  test('跟随系统按语言族解析，显式选择优先', () async {
    final prefs = UiPrefs(storage: _MemStorage());
    L10n.attach(
      listenable: prefs,
      preference: () => prefs.localePreference,
      systemLocale: () => 'en-US',
    );
    expect(L10n.resolvedLocale, 'en-US');
    await prefs.setLocalePreference('zh-CN');
    expect(L10n.resolvedLocale, 'zh-CN');
    await prefs.setLocalePreference('system');
    expect(L10n.resolvedLocale, 'en-US');
  });

  testWidgets('设置真实点击：English/中文即时切换且不重置主题', (tester) async {
    final prefs = UiPrefs(storage: _MemStorage());
    final app = _LocaleApp(prefs)..loaded = true;
    L10n.attach(
      listenable: prefs,
      preference: () => prefs.localePreference,
      systemLocale: () => 'zh-CN',
    );
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: ListenableBuilder(
          listenable: prefs,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            locale: L10n.flutterLocale,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
            home: const SettingsPage(),
          ),
        ),
      ),
    );
    expect(find.text('设置'), findsOneWidget);
    final theme = prefs.themeMode;
    await tester.tap(find.byKey(const ValueKey('locale-en-US')));
    await tester.pump();
    expect(prefs.localePreference, 'en-US');
    expect(L10n.resolvedLocale, 'en-US');
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('System'), findsNWidgets(2));
    expect(prefs.localePreference, 'en-US');
    expect(prefs.themeMode, theme);

    await tester.tap(find.byKey(const ValueKey('locale-zh-CN')));
    await tester.pump();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(prefs.themeMode, theme);
  });
}
