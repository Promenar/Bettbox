/// Xboard 面板 API 端点常量（已核验：cedar2025/Xboard 上游路由定义 + M0 实测）。
///
/// 全部为 `/api/v1/` 下的相对路径；BaseURL 由 [XboardDomainManager] 提供。
abstract final class XboardEndpoints {
  // guest（免鉴权）
  static const guestCommConfig = '/guest/comm/config';
  static const guestPlanFetch = '/guest/plan/fetch';

  // passport（鉴权）
  static const sendEmailVerify = '/passport/comm/sendEmailVerify';
  static const register = '/passport/auth/register';
  static const login = '/passport/auth/login';
  static const forget = '/passport/auth/forget';
  static const checkLogin = '/passport/auth/check';

  // user（Bearer 鉴权）
  static const userInfo = '/user/info';
  static const userGetSubscribe = '/user/getSubscribe';
  static const userResetSecurity = '/user/resetSecurity';
  static const userCheckLogin = '/user/checkLogin';
  static const userServerFetch = '/user/server/fetch';
  static const userPlanFetch = '/user/plan/fetch';
  static const orderSave = '/user/order/save';
  static const orderCheckout = '/user/order/checkout';
  static const orderCheck = '/user/order/check';
  static const orderFetch = '/user/order/fetch';
  static const orderDetail = '/user/order/detail';
  static const orderCancel = '/user/order/cancel';
  static const orderGetPaymentMethod = '/user/order/getPaymentMethod';
  static const couponCheck = '/user/coupon/check';
  static const userCommConfig = '/user/comm/config';
  static const inviteFetch = '/user/invite/fetch';
  static const inviteSave = '/user/invite/save';
}
