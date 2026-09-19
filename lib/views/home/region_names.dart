import 'package:bett_box/common/common.dart';
import 'package:bett_box/xboard/node_packager.dart';

/// 从 mihomo 地域组名解析地域码（自动组/兜底组返回 null）。
String? xboardCodeFromGroupName(String name) {
  if (name == kAutoRegionGroupName) return null;
  if (name == kFallbackRegionGroupName) return null;
  final parts = name.split(' ');
  if (parts.isEmpty) return null;
  final last = parts.last.trim();
  if (last.isEmpty) return null;
  return last;
}

/// 地域展示名本地化。
///
/// mihomo 组名保持中文标识不变（`selectedMap`/内核引用依赖其稳定性），
/// 仅展示层按地域码取本地名；未知码回退 [fallback]。
String xboardRegionDisplayName(String code, {String? fallback}) =>
    switch (code) {
      'HK' => appLocalizations.xbRegionHK,
      'TW' => appLocalizations.xbRegionTW,
      'SG' => appLocalizations.xbRegionSG,
      'JP' => appLocalizations.xbRegionJP,
      'KR' => appLocalizations.xbRegionKR,
      'US' => appLocalizations.xbRegionUS,
      'MY' => appLocalizations.xbRegionMY,
      'TH' => appLocalizations.xbRegionTH,
      'VN' => appLocalizations.xbRegionVN,
      'PH' => appLocalizations.xbRegionPH,
      'ID' => appLocalizations.xbRegionID,
      'UK' => appLocalizations.xbRegionUK,
      'DE' => appLocalizations.xbRegionDE,
      'AU' => appLocalizations.xbRegionAU,
      'TR' => appLocalizations.xbRegionTR,
      'BR' => appLocalizations.xbRegionBR,
      'AR' => appLocalizations.xbRegionAR,
      'IN' => appLocalizations.xbRegionIN,
      'RU' => appLocalizations.xbRegionRU,
      'UA' => appLocalizations.xbRegionUA,
      'CH' => appLocalizations.xbRegionCH,
      'AE' => appLocalizations.xbRegionAE,
      'NG' => appLocalizations.xbRegionNG,
      'ZA' => appLocalizations.xbRegionZA,
      'CA' => appLocalizations.xbRegionCA,
      'NL' => appLocalizations.xbRegionNL,
      'FR' => appLocalizations.xbRegionFR,
      'IQ' => appLocalizations.xbRegionIQ,
      _ => fallback ?? code,
    };
