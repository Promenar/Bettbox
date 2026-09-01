import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/network_speed.dart';
import 'package:bett_box/views/dashboard/widgets/outbound_mode.dart';
import 'package:bett_box/views/dashboard/widgets/start_button.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/node_packager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 商业版首页（写死布局，非自定义网格）：
/// 区域节点列表 → 网络与流量监控 → 分流模式 → 启动服务。
class HomeView extends ConsumerStatefulWidget {
  const HomeView({super.key});

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends ConsumerState<HomeView> {
  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.home,
      body: ListView(
        // 底部留白避开浮动导航栏
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
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

  /// 区域节点列表（F-NODE-3）：展示包装配置生成的地域组，
  /// 点击切换顶层选择器；状态词替代延迟数字（F-NODE-2）。
  Widget _buildRegionList() {
    final groups = ref.watch(currentGroupsStateProvider).value;
    final selectorName = kSelectorGroupName;
    final selector = groups.getGroup(selectorName);
    final selectedName =
        selector?.now ?? ref.watch(getSelectedProxyNameProvider(selectorName));

    final regionEntries = <(Group, bool)>[];
    for (final group in groups) {
      if (group.name == selectorName) continue;
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
            : Column(
                children: [
                  for (final (group, isAuto) in regionEntries)
                    _RegionTile(
                      group: group,
                      isAuto: isAuto,
                      isSelected: selectedName == group.name,
                      selectorName: selectorName,
                    ),
                ],
              ),
      ),
    );
  }
}

class _RegionTile extends ConsumerWidget {
  final Group group;
  final bool isAuto;
  final bool isSelected;
  final String selectorName;

  const _RegionTile({
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
    return ListItem(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        isAuto ? Icons.auto_awesome_rounded : Icons.place_rounded,
        color: isSelected
            ? context.colorScheme.primary
            : context.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        isAuto ? appLocalizations.xbAutoRegion : group.name,
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
