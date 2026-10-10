# Agent 网络搜索

在 **Agent → 设置 → 网络搜索** 中分别开启需要的服务。所有开关默认关闭；只启用一个服务也能使用。

| 服务 | 配置 | 用法 |
| --- | --- | --- |
| Bing | 开启开关，无需 Key | 搜索 bing.com 的公开结果，优先读取轻量 RSS |
| Google | 开启开关，无需 Key | 搜索 google.com；页面需要 JavaScript 时使用应用已有 WebView 临时加载 |
| Tavily | 填写独立的 Tavily API Key，再开启 | 使用 Tavily 搜索 API，按账户额度计费 |
| DeepSeek | 填写独立的 Key、搜索 API 地址和模型，再开启 | 由 DeepSeek 执行搜索，结果交给当前聊天模型；当前聊天模型可以来自任意服务商 |

Tavily 和 DeepSeek 的开关首次开启时，如果尚未配置 Key，会先打开设置。取消设置不会开启搜索；清空 Key 后保存会关闭对应服务。修改、删除或切换聊天模型会保留这些独立搜索设置。

## DeepSeek 独立搜索

默认参数来自 [DeepSeek 官方 harness 的搜索提供方](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/packages/web/web-search-deepseek/src/provider.ts)：

- 搜索 API 地址：`https://api.deepseek.com/anthropic/v1`
- 搜索模型 ID：`deepseek-v4-flash`
- API Key：在 DeepSeek 账户获取，在“DeepSeek 搜索设置”中单独填写。

也可以填写完整的 `/messages` 地址，或提供相同 Messages 搜索能力的兼容网关。填写地址时不加查询参数或账号密码。

例如，当前对话使用另一个服务商的 Chat Completions 模型时，可以说：“用 DeepSeek 搜索 Venera Prime 最新发布，并给出来源。”Agent 会把搜索词发给独立的 DeepSeek 搜索模型，再把标题、链接和摘要交给当前聊天模型。独立搜索不切换聊天模型，也不会把整段对话发给 DeepSeek。

一次独立搜索使用 `web_search_20250305`，最多允许 5 次服务端搜索调用；服务端暂停时支持续接，最多接收 3 次响应，总等待上限 60 秒。这会消耗 DeepSeek API 的模型及搜索额度，具体以服务商账户计费为准。

只有返回真实的 `web_search_tool_result` 才算已执行搜索；普通模型回答不会冒充联网结果。部分搜索失败会随可用结果返回说明。

## 模型原生搜索

在某个聊天模型的编辑页中，可单独开启“模型原生联网搜索”。这个开关使用该聊天模型的地址、Key 和原生能力，与上面的四个独立开关分别保存。

- **OpenAI Responses**：发送原生 `web_search` 工具，显示回答中的可点击来源。
- **Anthropic Messages**：发送 `web_search_20250305`，支持来源引用、服务端搜索结果和 `pause_turn` 续接。DeepSeek 官方 Messages 搜索也采用这条路径。
- **Chat Completions**：没有统一的原生搜索协议，原生开关不可选；仍可使用四个独立搜索提供商。

兼容接口的服务商不一定实现对应的原生工具。DeepSeek 的 Responses 文档说明会忽略内置工具，因此要用 DeepSeek 搜索时，优先使用独立 DeepSeek 提供商，或支持搜索的 Messages 模型配置。不能用服务商聊天网页上的联网按钮推断所有 API 都支持。

原生搜索的过程会显示在对话执行记录中，正文中的引用可以点击或随正文复制。服务端加密搜索块和引用只用于同模型的后续请求，不在界面中显示。切换模型或压缩上下文时保留可读来源链接；压缩请求不启用搜索。

## 结果与网络

可直接要求“用 Bing 搜索……”或“联网查找……并引用来源”。独立搜索工具为 `search_web(engine, query, max_results)`，默认返回 5 条、最多 10 条；每条包含标题、URL 和摘要，不下载目标网页全文。模型只会看到已开启的引擎，执行时还会再次检查开关。

官网可能要求验证码、同意页面、限制频率，或更改页面格式。遇到这些情况会明确返回失败，Agent 可按需要改用其他已开启的服务。应用不会代替用户点击验证，也不会把验证页面当作“没有搜索结果”。Google 需要 JavaScript 时，Linux 当前无法使用临时渲染；可改用 Bing、Tavily 或 DeepSeek。

HTTP 搜索沿用应用的代理、DNS 和 TLS 设置。临时 WebView 在 Android、Windows 上应用代理设置，在 iOS/macOS 上使用系统网络；目前不支持需要用户名和密码的 WebView 代理。临时视图串行创建，搜索结束、失败或停止后释放，不清理其他应用页面的 Cookie。

搜索 Key 和现有模型 Key 一样，仅保存在本机 Agent 目录的 `secrets.json`，不进入普通搜索配置、聊天工具结果、应用备份或 WebDAV。开启独立搜索后，仅在工具被调用时把搜索词发送给所选服务。

## 协议依据与验证

- [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search)
- [OpenAI Web search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Anthropic Web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
- [DeepSeek harness 搜索实现](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/packages/web/web-search-deepseek/src/provider.ts)

确定性测试使用模拟 HTTP、模型响应和本机临时数据库，不需要服务商 Key。`integration_test/agent_web_search_test.dart` 是需显式启用的官网联调，用公开查询 `Venera Prime GitHub` 检查 Bing 请求与 Google WebView，不访问用户账户；运行时添加 `--dart-define=PRIME_SEARCH_LIVE_TEST=true`。具体已完成范围记录在 [任务清单](agent-web-search-tasks.md)。
