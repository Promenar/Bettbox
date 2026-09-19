import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'login_page.dart';

String formatTrafficBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  return '${text.endsWith('.00') ? text.substring(0, text.length - 3) : text} ${units[unit]}';
}

/// 订阅及用量信息卡（首页顶部主入口）。
///
/// 数据口径为面板计费（`user/getSubscribe` 的 u/d/transfer_enable），
/// 由节点上报汇总，分钟级延迟，非本地实时流量。
/// 查看即刷新：每次挂载拉齐面板数据与订阅内容（2 分钟节流，登出态跳过）。
class SubscriptionPlanCard extends ConsumerStatefulWidget {
  const SubscriptionPlanCard({super.key});

  @override
  ConsumerState<SubscriptionPlanCard> createState() =>
      _SubscriptionPlanCardState();
}

class _SubscriptionPlanCardState extends ConsumerState<SubscriptionPlanCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        ref.read(xboardSessionProvider.notifier).refreshSubscriptionCycle();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(xboardSessionProvider);
    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: switch (session.status) {
          SessionStatus.restoring => const Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          SessionStatus.unauthenticated => const _LoginPrompt(),
          SessionStatus.authenticated => session.subscribeInfo == null
              ? const _NoPlan()
              : _PlanDetails(
                  subscribe: session.subscribeInfo!,
                  refreshedAt: session.refreshedAt,
                ),
        },
      ),
    );
  }
}

/// 未登录态：与登录后同骨架（标题/进度/流量/到期四行），仅文案变为
/// "未登录" / "登录同步订阅信息"，底部保留登录入口。
class _LoginPrompt extends StatelessWidget {
  const _LoginPrompt();

  @override
  Widget build(BuildContext context) {
    final syncTip = appLocalizations.xbLoginSyncTip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              Icons.workspace_premium_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                appLocalizations.xbUnloggedIn,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: 0,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 8),
        Text(
          '${appLocalizations.xbTrafficUsed}: $syncTip',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          '${appLocalizations.xbExpireAt}: $syncTip',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => BaseNavigator.push(context, const LoginPage()),
            child: Text(appLocalizations.xbLogin),
          ),
        ),
      ],
    );
  }
}

class _NoPlan extends ConsumerWidget {
  const _NoPlan();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          appLocalizations.xbNoPlanTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          appLocalizations.xbNoPlanTip,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () => ref.read(currentPageLabelProvider.notifier).value =
              PageLabel.store,
          child: Text(appLocalizations.xbBuyNow),
        ),
      ],
    );
  }
}

class _PlanDetails extends StatelessWidget {
  const _PlanDetails({required this.subscribe, this.refreshedAt});

  final XboardSubscribeInfo subscribe;
  final DateTime? refreshedAt;

  @override
  Widget build(BuildContext context) {
    final refreshed = refreshedAt;
    final plan = subscribe.plan;
    final total = subscribe.transferEnable;
    final used = subscribe.u + subscribe.d;
    final percent = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final expireText = subscribe.expiredAt > 0
        ? DateFormat(
            'yyyy-MM-dd HH:mm',
          ).format(DateTime.fromMillisecondsSinceEpoch(subscribe.expiredAt * 1000))
        : appLocalizations.unknown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              Icons.workspace_premium_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                plan?.name ?? appLocalizations.xbManagedSubscription,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: percent,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 8),
        Text(
          '${appLocalizations.xbTrafficUsed}: ${formatTrafficBytes(used)} / ${formatTrafficBytes(total)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          '${appLocalizations.xbExpireAt}: $expireText',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (refreshed != null) ...[
          const SizedBox(height: 4),
          Text(
            '${appLocalizations.xbDataUpdated} ${DateFormat('MM-dd HH:mm').format(refreshed)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
