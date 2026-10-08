import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/views/account/forget_page.dart';
import 'package:bett_box/views/account/login_page.dart';
import 'package:bett_box/views/account/register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Loading extends Loading {
  @override
  bool build() => false;
}

void main() {
  setUp(() async => AppLocalizations.load(const Locale('zh', 'CN')));

  Future<void> mount(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          loadingProvider.overrideWith(_Loading.new),
          isMobileViewProvider.overrideWith((ref) => true),
        ],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: page,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> verifyInput(WidgetTester tester, Finder field) async {
    await tester.ensureVisible(field);
    await tester.showKeyboard(field);
    await tester.pump();
    final configuration = tester.testTextInput.setClientArgs!;
    expect(
      configuration['autocorrect'],
      false,
      reason: '身份标识与密码必须原样传给服务端，禁止输入法改写',
    );
    expect(configuration['enableSuggestions'], false, reason: '凭据输入不向输入法请求候选词');
    expect(configuration['textCapitalization'], 'TextCapitalization.none');
    expect(
      configuration['smartDashesType'],
      SmartDashesType.disabled.index.toString(),
    );
    expect(
      configuration['smartQuotesType'],
      SmartQuotesType.disabled.index.toString(),
    );
  }

  final pages = <String, Widget>{
    '登录': const LoginPage(),
    '注册': const RegisterPage(),
    '找回密码': const ForgetPage(),
  };
  for (final entry in pages.entries) {
    testWidgets('${entry.key}邮箱不允许输入法自动改写', (tester) async {
      await mount(tester, entry.value);
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.keyboardType == TextInputType.emailAddress,
      );
      await verifyInput(tester, field);
      const address = 'bettbox-validation@example.invalid';
      await tester.enterText(field, address);
      expect(tester.widget<TextField>(field).controller!.text, address);
    });
    testWidgets('${entry.key}密码不请求纠错或建议', (tester) async {
      await mount(tester, entry.value);
      final field = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.obscureText,
      );
      await verifyInput(tester, field);
    });
  }
  testWidgets('注册邀请码保持精确输入', (tester) async {
    await mount(tester, const RegisterPage());
    final field = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText ==
              AppLocalizations.current.xbInviteCodeOptional,
    );
    await verifyInput(tester, field);
  });
  testWidgets('显示密码时也不启用纠错或建议', (tester) async {
    await mount(tester, const LoginPage());
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pump();
    final field = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == AppLocalizations.current.xbPassword,
    );
    expect(tester.widget<TextField>(field).obscureText, false);
    await verifyInput(tester, field);
  });
}
