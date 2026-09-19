import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/login_page.dart';
import 'checkout_page.dart';
import 'orders_page.dart';
import 'period_names.dart';

class StoreView extends ConsumerStatefulWidget {
  const StoreView({super.key});

  @override
  ConsumerState<StoreView> createState() => _StoreViewState();
}

class _StoreViewState extends ConsumerState<StoreView> {
  List<XboardPlan>? _plans;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final plans = await ref.read(xboardGuestRepositoryProvider).plans();
      if (mounted) setState(() => _plans = plans);
    } on XboardException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  /// Xboard 价格单位为分（DB 存元，API 下发分，实测）；显示时转元。
String _priceText(num cents) => '¥${(cents / 100).toStringAsFixed(2)}';

  /// F-PAY-2 下单流程：选周期 → order/save → 选支付方式 → checkout → 收银页。
  Future<void> _onBuy(XboardPlan plan) async {
    if (!ref.read(xboardSessionProvider).isAuthenticated) {
      context.showSnackBar(appLocalizations.xbAccountRequired);
      await BaseNavigator.push(context, const LoginPage());
      return;
    }
    if (plan.prices.isEmpty) {
      context.showSnackBar(appLocalizations.xbStoreEmpty);
      return;
    }

    final period = await _selectPeriod(plan);
    debugPrint('[XBOARD_ORDER] period selected: $period');
    if (period == null || !mounted) return;

    String? tradeNo;
    try {
      debugPrint('[XBOARD_ORDER] saving order plan=${plan.id}');
      tradeNo = await ref.read(xboardOrderRepositoryProvider).saveOrder(
            planId: plan.id,
            period: period,
          );
      debugPrint('[XBOARD_ORDER] saved: $tradeNo');
    } on XboardException catch (error) {
      debugPrint('[XBOARD_ORDER] save xboard error: $error');
      if (mounted) {
        context.showSnackBar(error.message);
        // 下单失败后若存在待支付订单，引导至订单页处理旧单
        //（以订单列表为准，不依赖服务端报错文案措辞）。
        try {
          final orders = await ref
              .read(xboardOrderRepositoryProvider)
              .fetchOrders();
          if (orders.any((o) => o.isPending) && mounted && context.mounted) {
            await BaseNavigator.push(context, const OrdersPage());
            await _load();
          }
        } catch (_) {}
      }
      return;
    } catch (error) {
      debugPrint('[XBOARD_ORDER] save error: $error');
      if (mounted) context.showSnackBar('$error');
      return;
    }

    final method = await _selectPaymentMethod();
    if (method == null || !mounted) return;

    XboardCheckoutResult checkout;
    try {
      checkout = await ref.read(xboardOrderRepositoryProvider).checkout(
            tradeNo: tradeNo,
            method: method.id,
          );
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
      return;
    } catch (error) {
      if (mounted) context.showSnackBar('$error');
      return;
    }

    if (!mounted) return;
    await BaseNavigator.push(
      context,
      CheckoutPage(tradeNo: tradeNo, checkout: checkout),
    );
    await _load();
  }

  Future<String?> _selectPeriod(XboardPlan plan) async {
    final entries = plan.prices.entries.toList();
    if (!mounted) return null;
    return globalState.showCommonDialog<String>(
      child: SimpleDialog(
        title: Text(appLocalizations.xbSelectPeriod),
        children: [
          for (final e in entries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(e.key),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(xboardPeriodName(e.key)),
                trailing: Text(_priceText(e.value)),
              ),
            ),
        ],
      ),
    );
  }

  Future<XboardPaymentMethod?> _selectPaymentMethod() async {
    List<XboardPaymentMethod> methods;
    try {
      methods =
          await ref.read(xboardOrderRepositoryProvider).getPaymentMethods();
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
      return null;
    }
    if (methods.isEmpty) {
      if (mounted) {
        context.showSnackBar(appLocalizations.xbNoPaymentMethod);
      }
      return null;
    }
    if (!mounted) return null;
    return globalState.showCommonDialog<XboardPaymentMethod>(
      child: SimpleDialog(
        title: Text(appLocalizations.xbSelectPayment),
        children: [
          for (final m in methods)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(m),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.payment_rounded),
                title: Text(m.name),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plans = _plans;
    return CommonScaffold(
      title: appLocalizations.xbStore,
      actions: [
        IconButton(
          tooltip: appLocalizations.xbMyOrders,
          icon: const Icon(Icons.receipt_long_rounded),
          onPressed: () => BaseNavigator.push(context, const OrdersPage()),
        ),
      ],
      body: plans == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : (plans == null || plans.isEmpty)
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error ?? appLocalizations.xbStoreEmpty),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _load,
                        child: Text(appLocalizations.retry),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: plans.length,
                    itemBuilder: (context, index) {
                      final plan = plans[index];
                      final priceText = plan.prices.isEmpty
                          ? ''
                          : plan.prices.entries
                              .map((e) =>
                                  '${xboardPeriodName(e.key)}: ${_priceText(e.value)}')
                              .join('　');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: CommonCard(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        plan.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                    ),
                                    FilledButton.tonal(
                                      onPressed: () => _onBuy(plan),
                                      child: Text(appLocalizations.xbBuyNow),
                                    ),
                                  ],
                                ),
                                if (priceText.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    priceText,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
