import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/views/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class Navigation {
  static Navigation? _instance;

  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) {
    return [
      // 商业版首页：服务启停 / 分流模式 / 区域节点（写死布局）。
      NavigationItem(
        keep: false,
        icon: const Icon(Icons.home_rounded),
        label: PageLabel.home,
        builder: (_) => HomeView(key: const GlobalObjectKey(PageLabel.home)),
        modes: [NavigationItemMode.mobile, NavigationItemMode.desktop],
      ),
      // 原 Dashboard/Proxies 对商业版移动端隐藏（桌面侧栏保留入口，代码可回退）。
      NavigationItem(
        keep: false,
        icon: Icon(Icons.space_dashboard),
        label: PageLabel.dashboard,
        builder: (_) =>
            DashboardView(key: const GlobalObjectKey(PageLabel.dashboard)),
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.article),
        label: PageLabel.proxies,
        builder: (_) => ProviderScope(
          overrides: [queryProvider.overrideWith(() => Query())],
          child: ProxiesView(key: const GlobalObjectKey(PageLabel.proxies)),
        ),
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: Icon(Icons.folder),
        label: PageLabel.profiles,
        builder: (_) =>
            ProfilesView(key: const GlobalObjectKey(PageLabel.profiles)),
        // 商业版：订阅由账号受管（F-SUB-1），手动订阅管理入口撤出移动端底栏。
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: Icon(Icons.view_timeline),
        label: PageLabel.requests,
        builder: (_) =>
            RequestsView(key: const GlobalObjectKey(PageLabel.requests)),
        description: 'requestsDesc',
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: Icon(Icons.ballot),
        label: PageLabel.connections,
        builder: (_) =>
            ConnectionsView(key: const GlobalObjectKey(PageLabel.connections)),
        description: 'connectionsDesc',
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: Icon(Icons.storage),
        label: PageLabel.resources,
        description: 'resourcesDesc',
        builder: (_) =>
            ResourcesView(key: const GlobalObjectKey(PageLabel.resources)),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: Icon(Icons.functions),
        label: PageLabel.script,
        description: 'scriptDesc',
        builder: (_) =>
            ScriptsView(key: const GlobalObjectKey(PageLabel.script)),
        modes: [NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.adb),
        label: PageLabel.logs,
        builder: (_) => LogsView(key: const GlobalObjectKey(PageLabel.logs)),
        description: 'logsDesc',
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: Icon(Icons.construction),
        label: PageLabel.tools,
        builder: (_) => ToolsView(key: const GlobalObjectKey(PageLabel.tools)),
        // 商业版：工具/设置入口移至"我的"页二级页面，不占移动端底栏。
        modes: [NavigationItemMode.desktop, NavigationItemMode.more],
      ),
      NavigationItem(
        icon: const Icon(Icons.storefront_rounded),
        label: PageLabel.store,
        builder: (_) => StoreView(key: const GlobalObjectKey(PageLabel.store)),
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
      NavigationItem(
        icon: const Icon(Icons.person_rounded),
        label: PageLabel.account,
        builder: (_) =>
            AccountView(key: const GlobalObjectKey(PageLabel.account)),
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
    ];
  }

  Navigation._internal();

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }
}

final navigation = Navigation();
