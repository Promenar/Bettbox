import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/account/subscription_card.dart';
import 'package:bett_box/views/dashboard/widgets/outbound_mode.dart';
import 'package:bett_box/views/dashboard/widgets/start_button.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/domain_scheduler.dart';
import 'package:bett_box/xboard/node_packager.dart';
import 'package:bett_box/xboard/region_catalog.dart';
import 'package:bett_box/xboard/session.dart';
import 'region_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bett_box/pages/pages.dart';
import 'package:url_launcher/url_launcher.dart';

/// 商业版首页（写死布局，非自定义网格）：
/// 区域节点列表 → 网络与流量监控 → 分流模式 → 启动服务。
class HomeView extends ConsumerStatefulWidget {
  const HomeView({super.key});

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

/// mihomo 内置组名（全局模式伪节点等），区域列表不展示。
const _builtinGroupNames = {'GLOBAL', 'COMPATIBLE', 'REJECT'};
const kMihomoGlobalGroupName = 'GLOBAL';

class _HomeViewState extends ConsumerState<HomeView> {
  @override
  void initState() {
    super.initState();
    // 全局模式：GLOBAL 出口自动跟随"节点选择"（即用户在区域列表选的地域）。
    ref.listenManual(
      patchClashConfigProvider.select((state) => state.mode),
      (previous, next) {
        if (next == Mode.global) {
          _bindGlobalToSelector();
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final domainState = ref.watch(xboardDomainStateProvider);
    final rescue = domainState?.rescue ?? false;
    // 一屏布局：订阅卡 → 分流模式 → 地域列表（占满剩余高度并内部滚动）→ 启动按钮，
    // 保证主流设备无需纵向滚动即可看到全部信息。
    return CommonScaffold(
      title: appLocalizations.home,
      body: Padding(
        // 底部留白避开浮动导航栏
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          getFloatingBottomBarReserveHeight(context),
        ),
        child: Column(
          // 拉伸撑满：各卡片（含订阅卡）宽度与下方组件保持一致
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rescue) ...[
              _buildRescueBanner(context),
              const SizedBox(height: 12),
            ],
            const SubscriptionPlanCard(),
            const SizedBox(height: 12),
            const OutboundModeV2(),
            const SizedBox(height: 12),
            if (mode == Mode.direct)
              CommonCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    appLocalizations.xbDirectModeTip,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              Expanded(child: _buildRegionList()),
            const SizedBox(height: 12),
            const StartButton(),
          ],
        ),
      ),
    );
  }

  /// 救援模式横幅（F-DOMAIN-4）：全池失败时明确提示入口已变更，
  /// 提供一键重试与手动输入新域名，不接受静默断连。
  Widget _buildRescueBanner(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_off_rounded, color: colors.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    appLocalizations.xbDomainChangedTitle,
                    style: theme.textTheme.titleSmall?.copyWith(color: colors.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              appLocalizations.xbDomainChangedTip,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => ref.read(xboardDomainSchedulerProvider).retry(),
                  child: Text(appLocalizations.xbDomainRetry),
                ),
                OutlinedButton(
                  onPressed: () => _promptManualDomain(context),
                  child: Text(appLocalizations.xbDomainManual),
                ),
                OutlinedButton.icon(
                  onPressed: () => _scanDomain(context),
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                  label: Text(appLocalizations.xbScan),
                ),
                if (ref.watch(xboardAnnouncementUrlProvider) != null)
                  OutlinedButton.icon(
                    onPressed: () {
                      final url = ref.read(xboardAnnouncementUrlProvider);
                      if (url != null) launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.campaign_rounded, size: 16),
                    label: Text(appLocalizations.xbAnnouncement),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptManualDomain(BuildContext context) async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(appLocalizations.xbDomainManualTitle),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: appLocalizations.xbDomainManualHint,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(appLocalizations.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(appLocalizations.submit),
            ),
          ],
        );
      },
    );
    if (input == null || input.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(xboardDomainSchedulerProvider).useManualDomain(input);
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(appLocalizations.xbDomainInvalid)));
    } else {
      messenger.showSnackBar(SnackBar(content: Text(appLocalizations.xbDomainUpdated)));
    }
  }

  Future<void> _scanDomain(BuildContext context) async {
    final url = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (url == null || url.isEmpty || !context.mounted) return;
    // 扫码结果可能是完整订阅链接，提取 host 作为新入口
    String candidate = url.trim();
    try {
      final uri = Uri.parse(candidate);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        candidate = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      }
    } catch (_) {}
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(xboardDomainSchedulerProvider).useManualDomain(candidate);
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(appLocalizations.xbDomainInvalid)));
    } else {
      messenger.showSnackBar(SnackBar(content: Text(appLocalizations.xbDomainUpdated)));
    }
  }

  /// 全局模式下 GLOBAL 组默认走"节点选择"，避免出现独立的 GLOBAL 伪节点。
  void _bindGlobalToSelector() {
    try {
      final appController = globalState.appController;
      appController.updateCurrentSelectedMap(
        kMihomoGlobalGroupName,
        kSelectorGroupName,
      );
      appController.changeProxyDebounce(
        kMihomoGlobalGroupName,
        kSelectorGroupName,
      );
    } catch (error) {
      debugPrint('[XBOARD_HOME] bind global error: $error');
    }
  }

  /// 区域节点列表（F-NODE-3/6/7）：包装地域组 + 受限地域（F-NODE-6 锁定态）。
  Widget _buildRegionList() {
    final groups = ref.watch(currentGroupsStateProvider).value;
    final selectorName = kSelectorGroupName;
    final selector = groups.getGroup(selectorName);
    final selectedName =
        selector?.now ?? ref.watch(getSelectedProxyNameProvider(selectorName));
    final catalog = ref.watch(xboardRegionCatalogProvider);
    final session = ref.watch(xboardSessionProvider);
    final planId = session.userInfo?.planId ?? session.subscribeInfo?.plan?.id;

    final regionEntries = <(Group, bool)>[];
    final availableCodes = <String>{};
    for (final group in groups) {
      if (group.name == selectorName) continue;
      if (_builtinGroupNames.contains(group.name)) continue;
      final isAuto = group.name == kAutoRegionGroupName;
      regionEntries.add((group, isAuto));
      if (!isAuto) {
        final code = xboardCodeFromGroupName(group.name);
        if (code != null) availableCodes.add(code);
      }
    }
    // 受限地域：目录有但订阅无（F-NODE-6），展示为锁定态（不可连，点击推商店）。
    final locked = lockedEntries(
      catalog: catalog,
      availableCodes: availableCodes,
      planId: planId,
    );

    final allTiles = <Widget>[];
    // 已授权地域
    for (var i = 0; i < regionEntries.length; i += 2) {
      allTiles.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _RegionGridTile(
                  group: regionEntries[i].$1,
                  isAuto: regionEntries[i].$2,
                  isSelected: selectedName == regionEntries[i].$1.name,
                  selectorName: selectorName,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: i + 1 < regionEntries.length
                    ? _RegionGridTile(
                        group: regionEntries[i + 1].$1,
                        isAuto: regionEntries[i + 1].$2,
                        isSelected: selectedName == regionEntries[i + 1].$1.name,
                        selectorName: selectorName,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    // 受限地域（锁定态，F-NODE-6）
    for (var i = 0; i < locked.length; i += 2) {
      allTiles.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _LockedRegionTile(entry: locked[i])),
              const SizedBox(width: 8),
              Expanded(
                child: i + 1 < locked.length
                    ? _LockedRegionTile(entry: locked[i + 1])
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }

    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: regionEntries.isEmpty && locked.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
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
                  ],
                ),
              )
            : SingleChildScrollView(
                child: Column(children: allTiles),
              ),
      ),
    );
  }

}

class _RegionGridTile extends ConsumerWidget {
  final Group group;
  final bool isAuto;
  final bool isSelected;
  final String selectorName;

  const _RegionGridTile({
    required this.group,
    required this.isAuto,
    required this.isSelected,
    required this.selectorName,
  });

  void _select(WidgetRef ref) {
    final appController = globalState.appController;
    appController.updateCurrentSelectedMap(selectorName, group.name);
    appController.changeProxyDebounce(selectorName, group.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delay = ref.watch(
      getDelayProvider(
        proxyName: group.name,
        testUrl: group.testUrl,
      ),
    );
    // 状态词与颜色严格按同一档位映射，避免同词多色
    final status = regionStatusForDelay(delay);
    final statusWord = switch (status) {
      XboardRegionStatus.fluent => appLocalizations.xbStatusFluent,
      XboardRegionStatus.normal => appLocalizations.xbStatusNormal,
      XboardRegionStatus.congested => appLocalizations.xbStatusCongested,
    };
    final statusColor = switch (status) {
      XboardRegionStatus.fluent => Colors.green,
      XboardRegionStatus.normal => const Color(0xFFC57F0A),
      XboardRegionStatus.congested => context.colorScheme.error,
    };
    final parts = group.name.split(' ');
    final flag = isAuto ? null : parts.first;
    // 组名中文标识仅作内核引用，展示名按地域码本地化
    final code = xboardCodeFromGroupName(group.name);
    final label = isAuto
        ? appLocalizations.xbAutoShort
        : (group.name == kFallbackRegionGroupName
              ? appLocalizations.xbRegionPreferred
              : xboardRegionDisplayName(
                  code ?? '',
                  fallback: parts.length > 1 ? parts[1] : group.name,
                ));
    // 选中态：底色填充 + 标题加粗主色，一眼可辨
    return Container(
      decoration: isSelected
          ? BoxDecoration(
              color: context.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      // 双行：名称独占一行避免长译名被状态词挤压截断，状态词下沉副行
      child: ListItem(
        dense: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        leading: flag == null
            ? Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: isSelected
                    ? context.colorScheme.primary
                    : context.colorScheme.onSurfaceVariant,
              )
            : Text(flag, style: const TextStyle(fontSize: 16, height: 1)),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: isSelected
                    ? context.colorScheme.primary
                    : context.colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.bold : null,
              ),
        ),
        subtitle: Text(
          statusWord,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: statusColor,
                fontWeight: isSelected ? FontWeight.bold : null,
              ),
        ),
        onTap: () => _select(ref),
      ),
    );
  }
}

class _LockedRegionTile extends ConsumerWidget {
  final XboardRegionCatalogEntry entry;

  const _LockedRegionTile({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(xboardRegionCatalogProvider);
    final flag = catalog.flag(entry.code);
    final label = xboardRegionDisplayName(entry.code, fallback: entry.name);
    return ListItem(
      dense: true,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Text(flag, style: const TextStyle(fontSize: 16, height: 1)),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
      ),
      subtitle: Text(
        appLocalizations.xbRestricted,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
      ),
      trailing: Icon(
        Icons.lock_rounded,
        size: 14,
        color: context.colorScheme.onSurfaceVariant,
      ),
      onTap: () {
        final plans = entry.planIds.isEmpty ? '' : entry.planIds.join(', ');
        globalState.showMessage(
          title: label,
          message: TextSpan(
            text: plans.isEmpty
                ? appLocalizations.xbRestrictedTip
                : '${appLocalizations.xbRestrictedTip}\n${appLocalizations.xbRestrictedPlans}: $plans',
          ),
        );
        ref.read(currentPageLabelProvider.notifier).value = PageLabel.store;
      },
    );
  }
}
