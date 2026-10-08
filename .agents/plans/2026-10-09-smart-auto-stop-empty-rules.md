# 智能启停空规则恢复修复

目标：启用智能启停后清空网络规则，已智能停止的会话应走恢复路径；关闭功能也采用同一串行决策。

事实：35b6443 模拟器实测空规则未恢复；管理器在空规则时直接返回。原生 smartResume 当前只返回启动请求接受，完整原生完成确认和唯一 owner/engine ACK 属于另一个待完成工作包，本计划不得把决策回归等同设备恢复或流量证明。

步骤与所有权：主控维护 lib/manager/smart_auto_stop_policy.dart、smart_auto_stop_manager.dart、test/manager/smart_auto_stop_policy_test.dart 和对应 PDEC/文档。先从生产判断提取保持行为的纯函数，建立空规则及关闭恢复失败回归；再修复决策及接线，串行处理设置变化，拒绝读取地址期间过期的设置决策。未参与施工的原生审阅者只读复核，禁止读取 .test 凭据、.video_agent 或用户数据。

边界：空/仅空白规则不依赖 IP 查询即可恢复已智能停止会话；无 IP 且规则非空保留状态；已普通停止不自动启动；匹配时只停止实际运行会话；等待地址期间设置改变或组件销毁不执行旧决策。

验收：PDEC validate、定向 Flutter red/green、完整 flutter test（同源真实 Go FFI）、flutter analyze、独立审阅。新 APK 的设备恢复另验，不复用旧 APK 作为修复证明。

回滚：只回滚本计划范围的提交，原 APK 和测试配置保留；不改服务端、凭据、系统网络或正式签名配置。
