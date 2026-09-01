import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 收银页（F-PAY-2/3）：二维码渲染 / 收银台跳转 / 订单轮询（3s→5s→10s 退避）。
///
/// 支付成功后刷新用户与订阅状态；商户凭据到位后无需改动本页即可联调。
class CheckoutPage extends ConsumerStatefulWidget {
  const CheckoutPage({
    super.key,
    required this.tradeNo,
    required this.checkout,
  });

  final String tradeNo;
  final XboardCheckoutResult checkout;

  @override
  ConsumerState<CheckoutPage> createState() => _CheckoutPageState();
}

enum _CheckoutPhase { pending, paid, failed }

class _CheckoutPageState extends ConsumerState<CheckoutPage> {
  late _CheckoutPhase _phase;
  Timer? _pollTimer;
  int _attempt = 0;
  bool _refreshingAccount = false;

  @override
  void initState() {
    super.initState();
    _phase = widget.checkout.type == XboardCheckoutType.paid
        ? _CheckoutPhase.paid
        : _CheckoutPhase.pending;
    if (_phase == _CheckoutPhase.pending) {
      _startPolling();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    final schedule = checkoutPollSchedule();
    void poll() {
      if (_attempt >= schedule.length || !mounted) return;
      _pollTimer = Timer(schedule[_attempt], () async {
        _attempt++;
        try {
          final result = await ref
              .read(xboardOrderRepositoryProvider)
              .checkOrder(widget.tradeNo);
          if (!mounted) return;
          if (result.paid) {
            _onPaid();
            return;
          }
        } on XboardException catch (error) {
          debugPrint('[XBOARD_CHECKOUT] poll error: $error');
        } catch (_) {}
        poll();
      });
    }

    poll();
  }

  Future<void> _onPaid() async {
    _pollTimer?.cancel();
    if (!mounted) return;
    setState(() => _phase = _CheckoutPhase.paid);
    setState(() => _refreshingAccount = true);
    try {
      await ref.read(xboardSessionProvider.notifier).refreshUserInfo();
      final session = ref.read(xboardSessionProvider);
      if (session.isAuthenticated && session.subscribeInfo != null) {
        await refreshManagedSubscription();
      }
    } catch (error) {
      debugPrint('[XBOARD_CHECKOUT] post-paid refresh error: $error');
    }
    if (mounted) setState(() => _refreshingAccount = false);
  }

  Future<void> _cancel() async {
    final confirmed = await globalState.showCommonDialog<bool>(
      child: CommonDialog(
        title: appLocalizations.cancel,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(appLocalizations.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(appLocalizations.confirm),
          ),
        ],
        child: Text(appLocalizations.xbCancelOrderConfirm),
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(xboardOrderRepositoryProvider).cancelOrder(widget.tradeNo);
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.xbCheckout,
      actions: [
        if (_phase == _CheckoutPhase.pending)
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: appLocalizations.cancel,
            onPressed: _cancel,
          ),
      ],
      body: SafeArea(
        child: switch (_phase) {
          _CheckoutPhase.paid => _buildPaid(),
          _CheckoutPhase.failed => Center(
              child: Text(appLocalizations.xbPayFailed),
            ),
          _CheckoutPhase.pending => _buildPending(),
        },
      ),
    );
  }

  Widget _buildPaid() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            appLocalizations.xbPaySuccess,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _refreshingAccount
                ? null
                : () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: Text(_refreshingAccount
                ? '...'
                : appLocalizations.xbBackToAccount),
          ),
        ],
      ),
    );
  }

  Widget _buildPending() {
    final checkout = widget.checkout;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CommonCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  appLocalizations.xbScanToPay,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  appLocalizations.xbPayPollingTip,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (checkout.type == XboardCheckoutType.qrcode &&
            (checkout.data?.isNotEmpty ?? false))
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
              ),
              child: QrImageView(
                data: checkout.data!,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          )
        else if (checkout.type == XboardCheckoutType.redirect &&
            (checkout.data?.isNotEmpty ?? false))
          Column(
            children: [
              FilledButton.tonal(
                onPressed: () =>
                    launchUrl(Uri.parse(checkout.data!),
                        mode: LaunchMode.externalApplication),
                child: Text(appLocalizations.xbOpenCashier),
              ),
              const SizedBox(height: 12),
              _buildEmbeddedCashier(checkout.data!),
            ],
          )
        else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              appLocalizations.xbPayPendingTip,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  /// Android 内嵌收银台（F-PAY-2 假设 A1）；无法加载时用户可走上方外链按钮。
  Widget _buildEmbeddedCashier(String url) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(url));
    return SizedBox(
      height: 420,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: WebViewWidget(controller: controller),
      ),
    );
  }
}
