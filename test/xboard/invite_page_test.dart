import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/views/account/invite_page.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

XboardInviteDashboard dashboard({
  List<String> codes = const ['demo-code'],
  String? website = 'https://web.example.com',
}) => XboardInviteDashboard(
  summary: XboardInviteSummary(
    codes: codes,
    registeredCount: 2,
    totalCommission: 12345,
    pendingCommission: 120.5,
    availableCommission: 4567,
  ),
  currency: 'CNY',
  website: website,
);

class _Repository extends XboardInviteRepository {
  _Repository() : super(XboardApiClient(domainManager: XboardDomainManager()));
  int reads = 0;
  int creates = 0;
  Future<XboardInviteDashboard> Function() onLoad = () async => dashboard();
  Future<void> Function() onCreate = () async {};
  @override
  Future<XboardInviteDashboard> load() {
    reads++;
    return onLoad();
  }

  @override
  Future<void> createCode() {
    creates++;
    return onCreate();
  }
}

class _Loading extends Loading {
  @override
  bool build() => false;
}

void main() {
  final previewKey = GlobalKey();
  setUpAll(() async {
    final loader = FontLoader('HarmonyOS_Sans')
      ..addFont(rootBundle.load('assets/fonts/HarmonyOS_Sans_SC_Regular.ttf'));
    await loader.load();
  });
  late _Repository repository;
  late ProviderContainer container;
  setUp(() async {
    await AppLocalizations.load(const Locale('zh', 'CN'));
    repository = _Repository();
    container = ProviderContainer(
      overrides: [
        xboardInviteRepositoryProvider.overrideWithValue(repository),
        xboardAuthDataProvider.overrideWith((ref) => 'test-account-a'),
        loadingProvider.overrideWith(_Loading.new),
        isMobileViewProvider.overrideWith((ref) => true),
      ],
    );
  });
  tearDown(() => container.dispose());
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'HarmonyOS_Sans'),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: RepaintBoundary(key: previewKey, child: const InvitePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('收益展示且二维码与复制的链接完全一致', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await mount(tester);
    expect(find.text('累计佣金'), findsOneWidget);
    expect(find.textContaining('123.45'), findsOneWidget);
    expect(find.textContaining('1.205'), findsOneWidget);
    final previewPath = Platform.environment['BETTBOX_INVITE_PREVIEW'];
    if (previewPath != null) {
      await tester.runAsync(() async {
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(previewPath).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    final painter =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(QrImageView),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as QrPainter;
    await tester.ensureVisible(find.text('复制邀请链接'));
    await tester.tap(find.text('复制邀请链接'));
    await tester.pump();
    expect(copied, 'https://web.example.com/#/register?code=demo-code');
    await tester.runAsync(() async {
      final actual = await painter.toImageData(200);
      final expected = await QrPainter(
        data: copied!,
        version: QrVersions.auto,
        gapless: true,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ).toImageData(200);
      expect(actual!.buffer.asUint8List(), expected!.buffer.asUint8List());
    });
    expect(repository.creates, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('空态主动生成且重复点击只创建一次，成功后刷新', (tester) async {
    final creation = Completer<void>();
    repository.onLoad = () async => dashboard(codes: []);
    repository.onCreate = () => creation.future;
    await mount(tester);
    await tester.tap(find.text('生成邀请码'));
    await tester.tap(find.text('生成邀请码'));
    await tester.pump();
    expect(repository.creates, 1);
    repository.onLoad = () async => dashboard();
    creation.complete();
    await tester.pumpAndSettle();
    expect(repository.reads, 2);
    expect(find.byType(QrImageView), findsOneWidget);
  });
  testWidgets('加载错误可重试且不伪装成零收益', (tester) async {
    repository.onLoad = () async => throw const FormatException('无效响应');
    await mount(tester);
    expect(find.text('累计佣金'), findsNothing);
    repository.onLoad = () async => dashboard();
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('累计佣金'), findsOneWidget);
  });
  testWidgets('网站不可用时只分享邀请码', (tester) async {
    repository.onLoad = () async => dashboard(website: null);
    await mount(tester);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('复制邀请链接'), findsNothing);
    expect(find.text('复制邀请码'), findsOneWidget);
  });
  testWidgets('创建超时只重新读取结果，不自动重放创建', (tester) async {
    repository.onLoad = () async => dashboard(codes: []);
    repository.onCreate = () async {
      repository.onLoad = () async =>
          dashboard(codes: ['created-before-timeout']);
      throw TimeoutException('模拟响应超时');
    };
    await mount(tester);
    await tester.tap(find.text('生成邀请码'));
    await tester.pumpAndSettle();
    expect(repository.creates, 1);
    expect(repository.reads, 2);
    expect(find.text('created-before-timeout'), findsOneWidget);
  });
  testWidgets('换账号等待期间立即隐藏已缓存的邀请码和收益', (tester) async {
    await mount(tester);
    expect(find.text('demo-code'), findsOneWidget);
    final pending = Completer<XboardInviteDashboard>();
    repository.onLoad = () => pending.future;
    container.read(xboardAuthDataProvider.notifier).state = 'test-account-b';
    await tester.pump();
    expect(find.text('demo-code'), findsNothing);
    expect(find.text('累计佣金'), findsNothing);
    pending.complete(dashboard(codes: ['new-account-code']));
    await tester.pumpAndSettle();
    expect(find.text('new-account-code'), findsOneWidget);
  });
  testWidgets('切换账户后不展示旧缓存，旧异步回包不能覆盖新账户', (tester) async {
    final oldRequest = Completer<XboardInviteDashboard>();
    repository.onLoad = () => oldRequest.future;
    await mount(tester);
    repository.onLoad = () async => dashboard(codes: ['new-account-code']);
    container.read(xboardAuthDataProvider.notifier).state = 'test-account-b';
    await tester.pumpAndSettle();
    expect(find.text('new-account-code'), findsOneWidget);
    oldRequest.complete(dashboard(codes: ['old-account-code']));
    await tester.pumpAndSettle();
    expect(find.text('old-account-code'), findsNothing);
    expect(find.text('new-account-code'), findsOneWidget);
    container.read(xboardAuthDataProvider.notifier).state = null;
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('new-account-code'), findsNothing);
  });
  testWidgets('窄屏和大字体不溢出', (tester) async {
    await mount(tester);
    tester.view.physicalSize = const Size(320, 1100);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
