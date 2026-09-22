import 'dart:math' as math;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

final xboardInviteRepositoryProvider = Provider<XboardInviteRepository>(
  (ref) => XboardInviteRepository(ref.watch(xboardApiClientProvider)),
);

/// 凭据变化会丢弃旧请求及缓存，防止跨账户展示邀请信息。
final xboardInviteDashboardProvider =
    FutureProvider.autoDispose<XboardInviteDashboard?>((ref) {
      final auth = ref.watch(xboardAuthDataProvider);
      if (auth == null || auth.isEmpty) return null;
      return ref.watch(xboardInviteRepositoryProvider).load();
    });

class InvitePage extends ConsumerStatefulWidget {
  const InvitePage({super.key});

  @override
  ConsumerState<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends ConsumerState<InvitePage> {
  bool _creating = false;

  String _errorMessage(Object error) =>
      error is XboardException &&
          error.type == XboardErrorType.business &&
          error.message.isNotEmpty
      ? error.message
      : appLocalizations.xbInviteLoadError;

  Future<void> _refresh() async {
    try {
      ref.invalidate(xboardInviteDashboardProvider);
      await ref.read(xboardInviteDashboardProvider.future);
    } catch (_) {
      // 错误由 AsyncValue 在页面内统一展示。
    }
  }

  Future<void> _create() async {
    if (_creating) return;
    final auth = ref.read(xboardAuthDataProvider);
    if (auth == null || auth.isEmpty) return;
    setState(() => _creating = true);
    try {
      await ref.read(xboardInviteRepositoryProvider).createCode();
      if (!mounted || ref.read(xboardAuthDataProvider) != auth) return;
      await _refresh();
    } catch (error) {
      if (mounted && ref.read(xboardAuthDataProvider) == auth) {
        context.showSnackBar(_errorMessage(error));
        // 请求超时也可能已创建成功，仅读取一次，不重放创建请求。
        await _refresh();
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copy(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) context.showSnackBar(appLocalizations.xbInviteCopied);
    } catch (_) {
      if (mounted) context.showSnackBar(appLocalizations.xbInviteCopyError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(xboardAuthDataProvider);
    final dashboard = ref.watch(xboardInviteDashboardProvider);
    return CommonScaffold(
      title: appLocalizations.xbInviteTitle,
      body: auth == null || auth.isEmpty
          ? Center(child: Text(appLocalizations.xbLoginTip))
          : dashboard.when(
              skipLoadingOnRefresh: false,
              skipLoadingOnReload: false,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_errorMessage(error), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed: _refresh,
                        child: Text(appLocalizations.xbInviteRefresh),
                      ),
                    ],
                  ),
                ),
              ),
              data: (data) => data == null
                  ? Center(child: Text(appLocalizations.xbLoginTip))
                  : _content(data),
            ),
    );
  }

  Widget _content(XboardInviteDashboard data) {
    final summary = data.summary;
    String money(num cents) {
      // 后台分销计算可能返回小数分，展示时保留其有效精度。
      final parts = cents.toString().toLowerCase().split('e');
      final fraction = parts.first
          .split('.')
          .skip(1)
          .join()
          .replaceFirst(RegExp(r'0+$'), '');
      final exponent = parts.length == 2 ? int.parse(parts.last) : 0;
      return NumberFormat.currency(
        locale: Localizations.localeOf(context).toString(),
        name: data.currency,
        symbol: data.currency,
        decimalDigits: 2 + math.max(0, fraction.length - exponent),
      ).format(cents / 100);
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _displayCard(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(appLocalizations.xbInviteDescription),
                          const SizedBox(height: 16),
                          _stat(
                            appLocalizations.xbInviteRegistered,
                            '${summary.registeredCount}',
                          ),
                          _stat(
                            appLocalizations.xbInviteTotal,
                            money(summary.totalCommission),
                          ),
                          _stat(
                            appLocalizations.xbInvitePending,
                            money(summary.pendingCommission),
                          ),
                          _stat(
                            appLocalizations.xbInviteAvailable,
                            money(summary.availableCommission),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            appLocalizations.xbInviteSettlementNote,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (summary.codes.isEmpty)
                    _displayCard(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Text(appLocalizations.xbInviteEmpty),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _creating ? null : _create,
                              icon: const Icon(Icons.add_rounded),
                              label: Text(
                                _creating
                                    ? appLocalizations.xbInviteCreating
                                    : appLocalizations.xbInviteCreate,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final code in summary.codes) ...[
                      _codeCard(code, data.linkFor(code)),
                      const SizedBox(height: 16),
                    ],
                  TextButton.icon(
                    onPressed: _creating ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(appLocalizations.xbInviteRefresh),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _displayCard({required Widget child}) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    ),
    child: child,
  );

  Widget _stat(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 16,
      runSpacing: 4,
      children: [Text(label), Text(value)],
    ),
  );

  Widget _codeCard(String code, Uri? link) => _displayCard(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            appLocalizations.xbInviteCode,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SelectableText(code),
          const SizedBox(height: 16),
          if (link != null) ...[
            Center(
              child: Semantics(
                label: appLocalizations.xbInviteQrLabel,
                excludeSemantics: true,
                image: true,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(
                    data: link.toString(),
                    size: 200,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(link.toString()),
          ] else
            Text(appLocalizations.xbInviteWebsiteUnavailable),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (link != null)
                FilledButton.icon(
                  onPressed: () => _copy(link.toString()),
                  icon: const Icon(Icons.link_rounded),
                  label: Text(appLocalizations.xbInviteCopyLink),
                ),
              OutlinedButton.icon(
                onPressed: () => _copy(code),
                icon: const Icon(Icons.copy_rounded),
                label: Text(appLocalizations.xbInviteCopyCode),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
