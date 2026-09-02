import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/network_speed.dart';
import 'package:bett_box/views/dashboard/widgets/outbound_mode.dart';
import 'package:bett_box/views/dashboard/widgets/start_button.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/domain_scheduler.dart';
import 'package:bett_box/xboard/node_packager.dart';
import 'package:bett_box/xboard/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return CommonScaffold(
      title: appLocalizations.home,
      body: ListView(
        // 底部留白避开浮动导航栏
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (rescue) ...[
            _buildRescueBanner(context),
            const SizedBox(height: 12),
          ],
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
            _buildRegionList(),
          const SizedBox(height: 12),
          const NetworkSpeed(),
          const SizedBox(height: 12),
          const OutboundModeV2(),
          const SizedBox(height: 12),
          const StartButton(),
        ],
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
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: () => ref.read(xboardDomainSchedulerProvider).retry(),
                  child: Text(appLocalizations.xbDomainRetry),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _promptManualDomain(context),
                  child: Text(appLocalizations.xbDomainManual),
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

  /// 区域节点列表（F-NODE-3）：展示包装配置生成的地域组，
  /// 双列紧凑网格，点击切换顶层选择器；状态词替代延迟数字（F-NODE-2）。
  Widget _buildRegionList() {
    final groups = ref.watch(currentGroupsStateProvider).value;
    final selectorName = kSelectorGroupName;
    final selector = groups.getGroup(selectorName);
    final selectedName =
        selector?.now ?? ref.watch(getSelectedProxyNameProvider(selectorName));

    final regionEntries = <(Group, bool)>[];
    for (final group in groups) {
      if (group.name == selectorName) continue;
      // 内置伪节点组不作为地域展示（全局模式出口已自动绑定节点选择）
      if (_builtinGroupNames.contains(group.name)) continue;
      final isAuto = group.name == kAutoRegionGroupName;
      regionEntries.add((group, isAuto));
    }

    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: regionEntries.isEmpty
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
            : ConstrainedBox(
                // 固定最大高度，地域多时列表内部滚动，不把其他组件顶出屏幕
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < regionEntries.length; i += 2)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: _RegionGridTile(
                                  group: regionEntries[i].$1,
                                  isAuto: regionEntries[i].$2,
                                  isSelected:
                                      selectedName == regionEntries[i].$1.name,
                                  selectorName: selectorName,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: i + 1 < regionEntries.length
                                    ? _RegionGridTile(
                                        group: regionEntries[i + 1].$1,
                                        isAuto: regionEntries[i + 1].$2,
                                        isSelected: selectedName ==
                                            regionEntries[i + 1].$1.name,
                                        selectorName: selectorName,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
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
    final statusWord = switch (regionStatusForDelay(delay)) {
      XboardRegionStatus.fluent => appLocalizations.xbStatusFluent,
      XboardRegionStatus.normal => appLocalizations.xbStatusNormal,
      XboardRegionStatus.congested => appLocalizations.xbStatusCongested,
    };
    // 组名形如 "🇭🇰 香港 HK"，瓦片内拆分：前导国旗 + 地区名（紧凑布局省略代号）
    final parts = group.name.split(' ');
    final flag = isAuto ? null : parts.first;
    final label = isAuto
        ? appLocalizations.xbAutoRegion
        : (parts.length > 1 ? parts[1] : group.name);
    return ListItem(
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
            ),
      ),
      trailing: Text(
        statusWord,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: utils.getDelayColor(delay ?? -1),
            ),
      ),
      onTap: () => _select(ref),
    );
  }
}
