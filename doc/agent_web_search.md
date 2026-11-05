# Agent 网络搜索

在 **Agent → 设置 → 网络搜索** 中分别开启需要的服务。所有开关默认关闭；只启用一个服务也能使用。

| 服务 | 配置 | 用法 |
| --- | --- | --- |
| Bing | 开启开关，无需 Key | 搜索 bing.com 的公开结果，优先读取轻量 RSS，格式或端点不可用时回退 HTML |
| Google | 开启开关，无需 Key | 搜索 google.com 的网页结果，支持语义标题；需要 JavaScript 时使用应用已有 WebView 临时加载 |
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

应用无法改变 Bing/Google 自身的索引和排序。这里只改进请求、解析和去重；返回链接不等于与问题相关，仍需核对来源。重复结果会忽略片段及 utm_*、gclid、fbclid、msclkid 等营销参数，漫画/文档 ID、页码和语言参数保留。

官网可能要求验证码、同意页面、限制频率，或更改页面格式。遇到这些情况会明确返回失败，Agent 可按需要改用其他已开启的服务。应用不会代替用户点击验证，也不会把验证页面当作“没有搜索结果”。Google 需要 JavaScript 时，Linux 当前无法使用临时渲染；可改用 Bing、Tavily 或 DeepSeek。

HTTP 搜索沿用应用的代理、DNS 和 TLS 设置。临时 WebView 在 Android、Windows 上应用代理设置，在 iOS/macOS 上使用系统网络；目前不支持需要用户名和密码的 WebView 代理。临时视图串行创建，搜索结束、失败或停止后释放，不清理其他应用页面的 Cookie。

搜索 Key 和现有模型 Key 一样，仅保存在本机 Agent 目录的 `secrets.json`，不进入普通搜索配置、聊天工具结果、应用备份或 WebDAV。开启独立搜索后，仅在工具被调用时把搜索词发送给所选服务。

## 读取网页正文

搜索只返回摘要。需要核实内容或已有链接时，Agent 可调用 `read_web`，一次读取最多5个网页，输出便于模型阅读的 Markdown。这个工具不要求开启搜索引擎；只在调用时抓取指定链接。

例如：

```json
{"pages":[{"url":"https://example.org/article"},{"url":"https://example.org/guide","max_chars":8000}]}
```

每项返回来源、标题、抓取时间和正文，失败逐项说明原因。正文结合段落和链接密度选择文章，减少菜单、相关推荐、广告和隐藏内容混入；保留标题、链接、列表、定义、引用、文内注释与论坛多帖，代码块空行不被折叠；图片只保留文字描述。网页内容属于不可信资料，不能成为用户指令。

长文默认每项返回12000字，最多30000字（按 UTF-16 单元计数，不拆分 emoji）。有 `has_more` 时，用返回的 `next_start_char` 作为该 URL 的 `start_char` 继续；成功页面缓存2分钟、最多8份，短期续读不重复抓取。每页响应最多4 MiB、总等待25秒。登录、验证码、纯 JavaScript 正文和 PDF/图片等非文本文件会明确失败，不把空壳页面当作已读全文。HTTP(S) 重定向与立即跳转提示页合计最多5次，继续沿用应用网络设置，不转交给第三方网页转换服务。

## 本次公开联调（2026-11-05）

通过环境代理抓取公开响应快照，再运行应用实际搜索解析器和正文提取器；这不等同于设备上的 AgentHttpAdapter/WebView 端到端联调。

- Bing RSS 和 HTML 公开响应均可提取5条结果，但本环境返回来源与 `Venera Prime GitHub` 明显不相关；增加站点和精确词约束的查询也未改善。只验证了解析和可访问性，不能宣称搜索质量已通过，仍需核对相关性或切换其他已启用引擎。
- Google HTTP 200 实际为 JavaScript 页面，正确识别为 `SEARCH_BROWSER_REQUIRED`；Linux 环境没有临时 WebView，未验证真实 Google 搜索结果。
- Wikipedia 的 Markdown 条目可提取正文 Markdown（约4.6万字符），已核对标题、链接和结构；其余任意站点的提取质量不作保证。
- 三种模型协议的批量封面和搜索/网页读取的模拟回归见维护总表。没有使用付费搜索 Key，没有运行手机或 Windows WebView 联调。

## 正文提取改进样本（2026-11-05）

- Dart `Classes` 官方文档：旧输出开头混入目录与站点安全横幅；新输出从正文标题开始，保留文章内 Note/Warning、代码和段落。新正文约1.07万字符，增加的部分包含原先误删的说明，不能只按长度变短判断提取更好。
- Python Discourse 公开主题：原有约5469字符的多帖内容保持；另有确定性用例验证短回复不会因主帖更长而丢失。
- Python Insider 3.14 发布文章：旧输出只得到166字符的跳转提示；网页读取器现在跟随立即跳转并取得实际文章，约7967字符。
- Wikipedia Markdown 条目：仍保留约4.59万字符的文章内容。中文文档样本返回404，不计为提取成功。

快照比较使用相同 HTML 输入；Python Insider 另外通过环境代理、Dart IO 传输运行实际网页读取器验证跳转与正文。没有运行设备原生网络或 WebView，本次结果不代表任意站点均可完整提取。

## 协议依据与验证

- [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search)
- [OpenAI Web search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Anthropic Web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
- [DeepSeek harness 搜索实现](https://github.com/deepseek-ai/deepseek-harness/blob/d743267388641bc76f17c45ce8b4c231aed1d32c/packages/web/web-search-deepseek/src/provider.ts)

确定性测试使用模拟 HTTP、模型响应和本机临时数据库，不需要服务商 Key。`integration_test/agent_web_search_test.dart` 是需显式启用的官网联调，用公开查询 `Venera Prime GitHub` 检查 Bing 请求与 Google WebView，要求结果中包含所查项目的来源，不把不相关链接计为通过；不访问用户账户；运行时添加 `--dart-define=PRIME_SEARCH_LIVE_TEST=true`。具体已完成范围记录在 [任务清单](agent-web-search-tasks.md)。
