/// 邀请分享与收益读取；返佣归属和结算由 Xboard 负责。
library;

import 'api_client.dart';
import 'endpoints.dart';

class XboardInviteSummary {
  const XboardInviteSummary({
    required this.codes,
    required this.registeredCount,
    required this.totalCommission,
    required this.pendingCommission,
    required this.availableCommission,
  });

  final List<String> codes;
  final int registeredCount;

  /// 金额单位为分；分销配置可能使确认中佣金包含小数分。
  final int totalCommission;
  final num pendingCommission;
  final int availableCommission;

  factory XboardInviteSummary.fromJson(dynamic json) {
    if (json is! Map || json['codes'] is! List || json['stat'] is! List) {
      throw const FormatException('邀请响应缺少 codes 或 stat');
    }
    final stat = json['stat'] as List;
    if (stat.length < 5) throw const FormatException('邀请统计字段不完整');
    num number(int index, {bool integer = true}) {
      final raw = stat[index];
      final value = raw is num ? raw : num.tryParse(raw.toString());
      if (value == null ||
          !value.isFinite ||
          value < 0 ||
          (integer && value != value.truncateToDouble())) {
        throw const FormatException('邀请统计字段格式错误');
      }
      return value;
    }

    final codes = <String>[];
    for (final item in json['codes'] as List) {
      if (item is! Map) throw const FormatException('邀请码格式错误');
      final status = item['status'];
      if (status != false && status != 0 && status != '0') continue;
      final code = item['code'];
      if (code is! String || code.trim().isEmpty) {
        throw const FormatException('邀请码为空');
      }
      if (!codes.contains(code.trim())) codes.add(code.trim());
    }
    return XboardInviteSummary(
      codes: List.unmodifiable(codes),
      registeredCount: number(0).toInt(),
      totalCommission: number(1).toInt(),
      pendingCommission: number(2, integer: false),
      availableCommission: number(4).toInt(),
    );
  }
}

/// 使用面板网站的注册路由，不依赖 API 故障转移域名。
/// 路由对应 Xboard 内置主题的 `/#/register?code=`。
Uri? buildXboardInviteLink(String? website, String code) {
  if (website == null || code.trim().isEmpty) return null;
  final base = Uri.tryParse(website.trim());
  if (base == null ||
      base.scheme != 'https' ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment) {
    return null;
  }
  final path = base.path.endsWith('/') ? base.path : '${base.path}/';
  final route = Uri(path: '/register', queryParameters: {'code': code.trim()});
  return base.replace(path: path, fragment: route.toString());
}

class XboardInviteDashboard {
  const XboardInviteDashboard({
    required this.summary,
    required this.currency,
    this.website,
  });

  final XboardInviteSummary summary;
  final String currency;
  final String? website;

  Uri? linkFor(String code) => buildXboardInviteLink(website, code);
}

class XboardInviteRepository {
  XboardInviteRepository(this._client);

  final XboardApiClient _client;

  Future<XboardInviteSummary> fetch() async {
    final result = await _client.get<XboardInviteSummary>(
      XboardEndpoints.inviteFetch,
      parse: XboardInviteSummary.fromJson,
    );
    return result!;
  }

  /// 上游使用 GET 创建邀请码；不可自动重试或在加载页面时调用。
  Future<void> createCode() async {
    final saved = await _client.get<bool>(XboardEndpoints.inviteSave);
    if (saved != true) throw const FormatException('邀请码创建未确认');
  }

  Future<String> _currency() async {
    final result = await _client.get<String>(
      XboardEndpoints.userCommConfig,
      parse: (data) {
        final currency = data is Map ? data['currency'] : null;
        if (currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
          throw const FormatException('面板币种配置无效');
        }
        return currency;
      },
    );
    return result!;
  }

  Future<String?> _website() async {
    try {
      return await _client.get<String>(
        XboardEndpoints.guestCommConfig,
        parse: (data) => data is Map && data['app_url'] is String
            ? data['app_url'] as String
            : '',
      );
    } catch (_) {
      // 公开站点暂不可用时仍可查看收益与复制邀请码。
      return null;
    }
  }

  Future<XboardInviteDashboard> load() async {
    final results = await Future.wait<Object?>([
      fetch(),
      _currency(),
      _website(),
    ]);
    return XboardInviteDashboard(
      summary: results[0] as XboardInviteSummary,
      currency: results[1] as String,
      website: results[2] as String?,
    );
  }
}
