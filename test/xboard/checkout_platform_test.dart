import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/views/store/checkout_page.dart';
import 'package:bett_box/views/store/redirect_cashier.dart';
import 'package:bett_box/xboard/order_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Loading extends Loading {
  @override
  bool build() => false;
}

// 插件接口禁止恢复为 null，用默认未实现方法恢复无平台能力的状态。
class _UnavailableWebPlatform extends WebViewPlatform {}

class _WebPlatform extends WebViewPlatform {
  int creations = 0;
  int loads = 0;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    creations++;
    return _WebController(params, () => loads++);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebWidget(params);
}

class _WebController extends PlatformWebViewController {
  _WebController(super.params, this.onLoad) : super.implementation();
  final VoidCallback onLoad;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    onLoad();
  }
}

class _WebWidget extends PlatformWebViewWidget {
  _WebWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    TargetPlatform platform, {
    XboardCheckoutType type = XboardCheckoutType.redirect,
    String data = 'https://pay.example.com/order',
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await AppLocalizations.load(const Locale('zh', 'CN'));
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
          home: CheckoutPage(
            tradeNo: 'test-order',
            checkout: XboardCheckoutResult(type: type, data: data),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform 跳转收银不依赖 WebView 插件', (tester) async {
      await mount(tester, platform);
      expect(tester.takeException(), isNull);
      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.text('打开支付页面'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }
  testWidgets('桌面收银二维码正常显示', (tester) async {
    await mount(
      tester,
      TargetPlatform.windows,
      type: XboardCheckoutType.qrcode,
      data: 'payment-test-data',
    );
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('外链明确使用系统浏览器，失败时提示用户', (tester) async {
    MethodCall? launch;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        launch = call;
        return false;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      ),
    );
    await mount(tester, TargetPlatform.windows);
    await tester.tap(find.text('打开支付页面'));
    await tester.pump();
    expect(launch?.method, 'launch');
    expect(launch?.arguments['useWebView'], isFalse);
    expect(launch?.arguments['useSafariVC'], isFalse);
    expect(find.text('无法打开支付页面，请重试或选择其他支付方式。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('拒绝非网页收银地址', (tester) async {
    await mount(tester, TargetPlatform.windows, data: 'javascript:alert(1)');
    expect(find.text('打开支付页面'), findsNothing);
    expect(find.text('无法打开支付页面，请重试或选择其他支付方式。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('拒绝未加密收银地址', (tester) async {
    await mount(tester, TargetPlatform.windows, data: 'http://pay.example.com');
    expect(find.text('打开支付页面'), findsNothing);
    expect(find.text('无法打开支付页面，请重试或选择其他支付方式。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 重绘保持控制器，地址改变才重新加载', (tester) async {
    final previous = WebViewPlatform.instance;
    final web = _WebPlatform();
    WebViewPlatform.instance = web;
    addTearDown(
      () => WebViewPlatform.instance = previous ?? _UnavailableWebPlatform(),
    );
    await mount(tester, TargetPlatform.android);
    await tester.pump();
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(web.creations, 1);
    expect(web.loads, 1);
    await mount(
      tester,
      TargetPlatform.android,
      data: 'https://pay.example.com/another-order',
    );
    await tester.pump();
    expect(web.creations, 2);
    expect(web.loads, 2);
    tester.element(find.byType(RedirectCashier)).markNeedsBuild();
    await tester.pump();
    expect(web.creations, 2);
    expect(web.loads, 2);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
