import 'package:dio/dio.dart';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/tools.dart';
import 'package:bett_box/views/account/login_page.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/orders_page.dart';
import 'register_page.dart';

class AccountView extends ConsumerStatefulWidget {
  const AccountView({super.key});

  @override
  ConsumerState<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends ConsumerState<AccountView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(xboardSessionProvider.notifier);
      if (ref.read(xboardSessionProvider).status == SessionStatus.restoring) {
        await notifier.restore();
      }
      // 恢复/登录后完整刷新（含受管订阅内容更新与面板节点同步）
      if (ref.read(xboardSessionProvider).isAuthenticated) {
        await _refresh();
      }
    });
  }

  /// 原始异常 → 人话：服务端中文直透，订阅 403 映射开通引导，
  /// 其余不再透出原文（曾出现 Dio 整页英文刷屏）。
  /// 无订阅判定见 [isNoPlanError]（`lib/xboard/error_map.dart`）。
  String _friendlyError(Object error) {
    if (error is XboardException) return error.message;
    if (error is DioException && error.response?.statusCode == 403) {
      return appLocalizations.xbSubscriptionInactive;
    }
    return appLocalizations.xbNetworkError;
  }

  void _notifyError(Object error, {required bool manual}) {
    debugPrint('[XBOARD_ACCOUNT] error: $error');
    if (!manual || !mounted) return;
    context.showSnackBar(_friendlyError(error));
  }

  Future<void> _refresh({bool manual = false}) async {
    try {
      await ref.read(xboardSessionProvider.notifier).refreshUserInfo();
      final session = ref.read(xboardSessionProvider);
      if (session.isAuthenticated && session.subscribeInfo != null) {
        if (findManagedProfile() == null) {
          final profile = await _syncSubscription(silent: !manual);
          if (profile != null) await refreshManagedSubscription();
        } else {
          await refreshManagedSubscription();
        }
      }
    } on XboardException catch (error) {
      if (isNoPlanError(error)) {
        debugPrint('[XBOARD_ACCOUNT] no-plan state: $error');
        return;
      }
      _notifyError(error, manual: manual);
    } on Exception catch (error) {
      if (isNoPlanError(error)) {
        debugPrint('[XBOARD_ACCOUNT] no-plan state: $error');
        return;
      }
      _notifyError(error, manual: manual);
    }
  }

  Future<void> _toLogin() async {
    await BaseNavigator.push(context, const LoginPage());
    if (ref.read(xboardSessionProvider).isAuthenticated) {
      _syncSubscription(silent: false);
    }
  }

  Future<void> _toRegister() async {
    await BaseNavigator.push(context, const RegisterPage());
    if (ref.read(xboardSessionProvider).isAuthenticated) {
      _syncSubscription(silent: false);
    }
  }

  /// F-SUB-1：登录后自动创建/更新受管 Profile 并选中。
  Future<Profile?> _syncSubscription({bool silent = false}) async {
    final session = ref.read(xboardSessionProvider);
    final subscribe = session.subscribeInfo;
    if (subscribe == null || subscribe.subscribeUrl.isEmpty) return null;
    try {
      final profile = await syncManagedSubscription(
        subscribeUrl: subscribe.subscribeUrl,
        planName: subscribe.plan?.name ?? appLocalizations.xbManagedSubscription,
      );
      if (!mounted) return profile;
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      await globalState.appController.handleChangeProfile();
      return profile;
    } on XboardException catch (error) {
      if (isNoPlanError(error)) {
        debugPrint('[XBOARD_ACCOUNT] no-plan state: $error');
        return null;
      }
      _notifyError(error, manual: !silent);
    } catch (error) {
      if (isNoPlanError(error)) {
        debugPrint('[XBOARD_ACCOUNT] no-plan state: $error');
        return null;
      }
      _notifyError(error, manual: !silent);
    }
    return null;
  }

  Future<void> _resetSubscription() async {
    final confirmed = await globalState.showCommonDialog<bool>(
      child: CommonDialog(
        title: appLocalizations.xbResetSubscription,
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
        child: Text(appLocalizations.xbResetSubscriptionConfirm),
      ),
    );
    if (confirmed != true) return;
    try {
      final url = await ref.read(xboardUserRepositoryProvider).resetSecurity();
      await ref.read(xboardSessionProvider.notifier).refreshUserInfo();
      final subscribe = ref.read(xboardSessionProvider).subscribeInfo;
      await syncManagedSubscription(
        subscribeUrl: url,
        planName: subscribe?.plan?.name ?? appLocalizations.xbManagedSubscription,
      );
      if (mounted) context.showSnackBar(appLocalizations.success);
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(xboardSessionProvider);
    return CommonScaffold(
      title: appLocalizations.account,
      body: switch (session.status) {
        SessionStatus.restoring =>
          const Center(child: CircularProgressIndicator()),
        SessionStatus.unauthenticated => _buildUnauthenticated(),
        SessionStatus.authenticated => _buildAuthenticated(session),
      },
    );
  }

  Widget _buildUnauthenticated() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.person_rounded,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(appLocalizations.xbLoginTip),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _toLogin,
            child: Text(appLocalizations.xbLogin),
          ),
          TextButton(
            onPressed: _toRegister,
            child: Text(appLocalizations.xbRegister),
          ),
        ],
      ),
    );
  }

  // 订阅及用量信息卡已移至首页顶部展示，本页仅保留账号操作入口。
  Widget _buildAuthenticated(XboardSessionState session) {
    final userInfo = session.userInfo;
    return RefreshIndicator(
      onRefresh: () => _refresh(manual: true),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CommonCard(
            child: Column(
              children: [
                ListItem(
                  leading: const Icon(Icons.receipt_long_rounded),
                  title: Text(appLocalizations.xbMyOrders),
                  onTap: () => BaseNavigator.push(context, const OrdersPage()),
                ),
                ListItem(
                  leading: const Icon(Icons.construction),
                  title: Text(appLocalizations.tools),
                  onTap: () =>
                      BaseNavigator.push(context, const ToolsView()),
                ),
                ListItem(
                  leading: const Icon(Icons.refresh_rounded),
                  title: Text(appLocalizations.xbResetSubscription),
                  onTap: _resetSubscription,
                ),
                ListItem(
                  leading: const Icon(Icons.logout_rounded),
                  title: Text(appLocalizations.xbLogout),
                  onTap: () =>
                      ref.read(xboardSessionProvider.notifier).logout(),
                ),
              ],
            ),
          ),
          if (userInfo != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                userInfo.email,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
