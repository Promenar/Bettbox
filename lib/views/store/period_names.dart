import 'package:bett_box/common/common.dart';

/// Xboard 套餐周期本地化展示。
///
/// 键以服务端实际下发为准：新版为 `monthly` 等枚举，旧版为 `month_price`
/// 等扁平字段（实测），下单时原样回传，服务端自适应。
String xboardPeriodName(String? period) => switch (period) {
  'monthly' || 'month_price' => appLocalizations.xbPeriodMonthly,
  'quarterly' || 'quarter_price' => appLocalizations.xbPeriodQuarterly,
  'half_yearly' || 'half_year_price' => appLocalizations.xbPeriodHalfYearly,
  'yearly' || 'year_price' => appLocalizations.xbPeriodYearly,
  'two_yearly' || 'two_year_price' => appLocalizations.xbPeriodTwoYearly,
  'three_yearly' || 'three_year_price' => appLocalizations.xbPeriodThreeYearly,
  'onetime' || 'onetime_price' => appLocalizations.xbPeriodOnetime,
  'reset_traffic' || 'reset_price' => appLocalizations.xbPeriodReset,
  _ => period ?? '',
};
