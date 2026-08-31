import 'package:bett_box/common/common.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/login_page.dart';

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

  Future<void> _onBuy(XboardPlan plan) async {
    if (!ref.read(xboardSessionProvider).isAuthenticated) {
      context.showSnackBar(appLocalizations.xbAccountRequired);
      await BaseNavigator.push(context, const LoginPage());
      return;
    }
    // M2：下单/收银闭环待商户凭据就绪后接入（PRD F-PAY-2/3）。
    context.showSnackBar(appLocalizations.xbBuyPendingTip);
  }

  String _priceText(XboardPlan plan) {
    const periodNames = {
      'monthly': '月',
      'quarterly': '季',
      'half_yearly': '半年',
      'yearly': '年',
      'two_yearly': '两年',
      'three_yearly': '三年',
      'onetime': '一次性',
    };
    if (plan.prices.isEmpty) return '';
    return plan.prices.entries
        .map((e) => '${periodNames[e.key] ?? e.key}: ¥${(e.value / 100).toStringAsFixed(2)}')
        .join('　');
  }

  @override
  Widget build(BuildContext context) {
    final plans = _plans;
    return CommonScaffold(
      title: appLocalizations.xbStore,
      body: plans == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : (plans == null || plans.isEmpty)
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error ?? appLocalizations.xbStoreEmpty),
                      const SizedBox(height: 12),
                      TextButton(onPressed: _load, child: Text(appLocalizations.retry)),
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
                      final priceText = _priceText(plan);
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
                                        style: Theme.of(context).textTheme.titleMedium,
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
                                    style: Theme.of(context).textTheme.bodySmall,
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
