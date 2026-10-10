# Agent 网络搜索任务清单

用户已确认：Bing、Google 直接搜索官网，不要求 API Key；Tavily 单独配置 Key；DeepSeek 作为第四个独立搜索提供商，单独配置 Key、地址和搜索模型，任意聊天模型都可调用。模型原生联网另设开关。所有搜索默认关闭。沿用当前 Agent 分支，不重复处理已验收的性能优化和 2.4.4 合并。

- [x] 确认搜索方式、检查现有模型协议、工具入口与本机密钥存储。
- [x] 核对 Tavily、OpenAI Responses、Anthropic Messages 和 DeepSeek 官方 API 支持，以 DeepSeek 官方 harness 的 Messages 搜索实现为依据。
- [x] 增加 Bing、Google、Tavily、DeepSeek 独立开关；Tavily 与 DeepSeek 密钥单独编辑；支持的模型单独设置原生搜索，默认关闭。
- [x] 实现官网搜索解析、Tavily 与独立 DeepSeek 请求、启用状态检查、取消与错误处理。
- [x] 接入已确认的原生搜索，保留来源引用与多轮工具状态。
- [x] 完成配置、搜索、协议、界面回归及静态分析，验证公开官网搜索请求，并记录外部验证限制。
- [x] 更新使用说明、构建 Android 开发包并用中文提交 Git。

## 实施约束

- 搜索配置与现有 Agent 数据一样只留在本机；Key 单独保存，不进入普通配置、提示词或工具结果。
- 只把已启用的搜索引擎提供给模型，执行时再次检查开关。官网返回验证码、限流或不兼容页面时如实报错。
- 原生搜索以服务商公开 API 为准，不从聊天产品的联网按钮推断 API 参数。
- 不安装工具或新增依赖，不改动无关未跟踪文件，不推送远程。

## 验证记录

2026-10-11：

- `flutter test --no-pub test/agent`：294 项通过。覆盖四个独立提供商、开关和密钥隔离、配置迁移、两种原生搜索协议、流式引用、暂停后停止/重启/恢复、请求取消/超时/错误、网页解析与设置页交互。
- `dart analyze lib test integration_test`：无问题。
- Windows 实际应用组件联调：Bing RSS 返回 3 条可用来源；Google 临时 WebView 收到了官网验证要求，正确返回 SEARCH_BLOCKED 并释放视图。已修正 WebView2 导航取消覆盖真实验证错误的问题。Google 在当前网络上的真实结果未验证成功，不能将该项记为通过。
- Tavily、独立 DeepSeek、OpenAI/Anthropic 原生搜索使用符合官方协议的模拟响应验证，未使用真实付费 Key；没有安装或更新手机上的应用，Android 真机联网尚未验证。
- 公开联网测试位于 `integration_test/agent_web_search_test.dart`，默认跳过，显式添加 `--dart-define=PRIME_SEARCH_LIVE_TEST=true` 后运行；官网验证/网络限制会让“返回真实结果”断言失败，不能掩盖为成功。
- [使用说明](agent_web_search.md) 与 [设计文档](agent_design.md) 已更新；实现、回归和文档在同一中文提交中保存，不推送远程。
- Android arm64 Profile 开发包构建成功（最终构建约39秒），已验证独立开发版包名 `com.github.wgh136.venera.prime.dev`、应用名和必需原生库。产物：`build/app/outputs/flutter-apk/app-arm64-v8a-profile.apk`。
