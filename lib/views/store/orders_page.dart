import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'checkout_page.dart';
import 'period_names.dart';

/// 订单列表（F-PAY-4）：待支付可继续支付/取消，其余只读展示。
class OrdersPage extends ConsumerStatefulWidget {
  const OrdersPage({super.key});

  @override
  ConsumerState<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends ConsumerState<OrdersPage> {
  List<XboardOrder>? _orders;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await ref.read(xboardOrderRepositoryProvider).fetchOrders();
      // 按创建时间倒序
      orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _orders = orders);
    } on XboardException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _statusText(int status) => switch (status) {
        0 => appLocalizations.xbOrderPending,
        1 => appLocalizations.xbOrderProcessing,
        2 => appLocalizations.xbOrderCancelled,
        3 => appLocalizations.xbOrderDone,
        4 => appLocalizations.xbOrderCredited,
        _ => '${appLocalizations.xbOrderUnknown}($status)',
      };

  String _priceText(int cents) => '¥${(cents / 100).toStringAsFixed(2)}';
  String _dateText(int ts) {
    if (ts <= 0) return '-';
    // Xboard created_at 为秒级时间戳
    return DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ts * 1000));
  }

  Future<void> _cancel(XboardOrder order) async {
    final confirmed = await globalState.showCommonDialog<bool>(
      child: CommonDialog(
        title: appLocalizations.xbCancelOrderTitle,
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(appLocalizations.cancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(appLocalizations.confirm)),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(order.tradeNo),
            const SizedBox(height: 8),
            Text(appLocalizations.xbConfirmCancel),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(xboardOrderRepositoryProvider).cancelOrder(order.tradeNo);
      if (mounted) context.showSnackBar(appLocalizations.xbOrderCancelled);
      await _load();
    } on XboardException catch (e) {
      if (mounted) context.showSnackBar(e.message);
    }
  }

  Future<void> _continuePay(XboardOrder order) async {
    List<XboardPaymentMethod> methods;
    try {
      methods = await ref.read(xboardOrderRepositoryProvider).getPaymentMethods();
    } on XboardException catch (e) {
      if (mounted) context.showSnackBar(e.message);
      return;
    }
    if (methods.isEmpty) {
      if (mounted) context.showSnackBar(appLocalizations.xbNoPaymentMethod);
      return;
    }
    if (!mounted) return;
    final method = await globalState.showCommonDialog<XboardPaymentMethod>(
      child: SimpleDialog(
        title: Text(appLocalizations.xbSelectPayment),
        children: [
          for (final m in methods)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(m),
              child: ListTile(leading: const Icon(Icons.payment_rounded), title: Text(m.name)),
            ),
        ],
      ),
    );
    if (method == null || !mounted) return;
    try {
      final checkout = await ref.read(xboardOrderRepositoryProvider).checkout(
            tradeNo: order.tradeNo,
            method: method.id,
          );
      if (!mounted) return;
      await BaseNavigator.push(context, CheckoutPage(tradeNo: order.tradeNo, checkout: checkout));
      await _load();
    } on XboardException catch (e) {
      if (mounted) context.showSnackBar(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.xbMyOrders,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!),
                    const SizedBox(height: 12),
                    FilledButton.tonal(onPressed: _load, child: Text(appLocalizations.retry)),
                  ]),
                )
              : (_orders == null || _orders!.isEmpty)
                  ? Center(child: Text(appLocalizations.xbNoOrders))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _orders!.length,
                        itemBuilder: (context, i) {
                          final o = _orders![i];
                          final pending = o.isPending;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: CommonCard(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Expanded(child: Text(o.tradeNo, style: Theme.of(context).textTheme.titleSmall)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: pending ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(_statusText(o.status), style: Theme.of(context).textTheme.labelSmall),
                                    ),
                                  ]),
                                  const SizedBox(height: 8),
                                  Text('${_priceText(o.totalAmount)}  ${xboardPeriodName(o.period)}  ${_dateText(o.createdAt)}', style: Theme.of(context).textTheme.bodySmall),
                                  if (pending) ...[
                                    const SizedBox(height: 12),
                                    Row(children: [
                                      FilledButton.tonal(onPressed: () => _continuePay(o), child: Text(appLocalizations.xbContinuePay)),
                                      const SizedBox(width: 8),
                                      OutlinedButton(onPressed: () => _cancel(o), child: Text(appLocalizations.cancel)),
                                    ]),
                                  ],
                                ]),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
