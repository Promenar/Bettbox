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
import 'package:intl/intl.dart';

import 'register_page.dart';

String _formatBytes(num bytes) {
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

  Future<void> _refresh() async {
    try {
      await ref.read(xboardSessionProvider.notifier).refreshUserInfo();
      final session = ref.read(xboardSessionProvider);
      if (session.isAuthenticated && session.subscribeInfo != null) {
        if (findManagedProfile() == null) {
          final profile = await _syncSubscription();
          if (profile != null) await refreshManagedSubscription();
        } else {
          await refreshManagedSubscription();
        }
      }
    } on XboardException catch (error) {
      debugPrint('[XBOARD_ACCOUNT] refresh error: $error');
      if (mounted) {
        context.showSnackBar(
          error.statusCode == 403
              ? appLocalizations.xbSubscriptionExpired
              : error.message,
        );
      }
    } on Exception catch (error) {
      debugPrint('[XBOARD_ACCOUNT] refresh error: $error');
      if (mounted) {
        final isExpired = error is DioException &&
            error.response?.statusCode == 403;
        context.showSnackBar(
          isExpired ? appLocalizations.xbSubscriptionExpired : '$error',
        );
      }
    }
  }

  Future<void> _toLogin() async {
    await BaseNavigator.push(context, const LoginPage());
    if (ref.read(xboardSessionProvider).isAuthenticated) {
      _syncSubscription();
    }
  }

  Future<void> _toRegister() async {
    await BaseNavigator.push(context, const RegisterPage());
    if (ref.read(xboardSessionProvider).isAuthenticated) {
      _syncSubscription();
    }
  }

  /// F-SUB-1：登录后自动创建/更新受管 Profile 并选中。
  Future<Profile?> _syncSubscription() async {
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
      debugPrint('[XBOARD_ACCOUNT] sync xboard error: $error');
      if (mounted) context.showSnackBar(error.message);
    } catch (error) {
      debugPrint('[XBOARD_ACCOUNT] sync error: $error');
      if (mounted) context.showSnackBar(error.toString());
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

  Widget _buildAuthenticated(XboardSessionState session) {
    final subscribe = session.subscribeInfo;
    final userInfo = session.userInfo;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CommonCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: subscribe == null
                  ? _buildNoPlan()
                  : _buildPlanCard(subscribe),
            ),
          ),
          const SizedBox(height: 12),
          CommonCard(
            child: Column(
              children: [
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

  Widget _buildNoPlan() {
    return Column(
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
    );
  }

  Widget _buildPlanCard(XboardSubscribeInfo subscribe) {
    final plan = subscribe.plan;
    final total = subscribe.transferEnable;
    final used = subscribe.u + subscribe.d;
    final percent = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final expireText = subscribe.expiredAt > 0
        ? DateFormat('yyyy-MM-dd HH:mm').format(
            DateTime.fromMillisecondsSinceEpoch(subscribe.expiredAt * 1000),
          )
        : appLocalizations.unknown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        LinearProgressIndicator(value: percent, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        const SizedBox(height: 8),
        Text(
          '${appLocalizations.xbTrafficUsed}: ${_formatBytes(used)} / ${_formatBytes(total)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          '${appLocalizations.xbExpireAt}: $expireText',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
