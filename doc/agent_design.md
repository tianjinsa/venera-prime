# Venera Prime Agent 接入设计方案

> 版本：v4（2026-09-12）
> 实施基线：6a62b16（Venera Prime 2.2.1，当前上游最新版）
> 本次修订：在分层执行过程、持续对话和上下文压缩的基础上，增加图片输入、会话资源大小统计、资源级联清理和批量删除；继续限制上游接入范围。

## 1. 目标与范围

在应用内接入用户配置的 OpenAI Chat Completions 兼容模型，通过工具搜索漫画、查看详情、批量管理本地收藏和稍后再看。已知源和漫画 ID（含图片识别结果）时可直接调用目标工具，由工具自行取得所需资料；只有漫画名称时通过搜索定位。漫画在独立展示栏呈现。

本期交付：

- 底部五个 Tab：**主页 / 收藏 / Agent / 探索 / 分类**。宽屏沿用现有侧边导航，Agent 同样位于第三项。
- 模型配置：地址、模型名、密钥、视觉能力声明、思考深度列表及请求体补丁、是否回传思考内容。
- 流式对话、停止、失败重试、重新生成、编辑后重发，以及历史会话的新建、搜索、切换、重命名和删除。每段历史显示内容占用大小，支持多选和全选当前搜索结果后批量删除。
- 多张本地图片选择、缩略图、放大预览、发送前移除、纯图片或图文发送；图片随消息持久化，支持补充消息、重试和重启继续识图。
- 一次用户任务包含多次模型响应和运行中补充消息；正文间的连续思考和工具合为默认折叠的过程组，组内每项详情也可独立展开。完成后只展开最终正文，之前的正文、过程组及补充消息再次整体折叠。
- 不限制工具轮数、不按字符数截断模型或工具输出。按最近一次真实 token 统计在模型容量90%时自动压缩，也可手动触发；保留原始记录。
- 19 个工具：源能力、发现、展示、本地收藏、稍后再看；支持批量操作、逐项回执和删除撤销。

保留已有决定：只操作本地收藏；默认全自动；不提供删除收藏夹、清空收藏库、登录、验证码、通过工具获取章节图片或图片收藏写入；不做 headless 第二入口。图片收藏/历史工具、分享入口和会话导入导出留到后续。

视觉能力由模型设置中的“模型支持视觉”声明。选择图片仅加入本机草稿，点击发送后才随请求发给所选模型；不自动下载、上传漫画封面。

## 2. 上游兼容约束

这不是上游作者维护的功能分支，后续需要持续合并作者代码。方案优先减少原文件修改和对私有实现的依赖。

### 2.1 规则

1. 新功能集中在 **lib/agent/**，单向依赖现有应用接口；原有源解析器、JS 引擎、漫画源脚本不认识 Agent。
2. 原文件只承担必要接入，不做全仓格式化、搬迁、重命名或无关重构，不改版本号和平台工程。
3. 模型设置入口放在 Agent 页自己的工具栏，不扩展 SettingsPage 的平行数组/switch，不改 appdata 默认配置和同步白名单。
4. Agent 页打开时懒初始化自己的存储，退出时停止当前生成，重新进入从存储恢复。应用和 headless 启动链路不变。
5. 收藏/稍后再看写入使用原管理器公开 API，不直接连接原数据库写入，不复制表结构、标签翻译或计数逻辑。
6. 首期在适配层读取后分页，不为了 Agent 给两个管理器增加多组查询接口；大库性能是明确的后续优化点。
7. 中文提交信息，设计、通用通知能力、Agent 实现可以独立审查；不提交 SDK、缓存和无关的未跟踪文件。

### 2.2 原文件接入清单

| 文件 | 必要修改 | 合并上游时验证 |
| --- | --- | --- |
| lib/pages/main_page.dart | 接入第三个页面/导航项，映射旧启动页索引 | 五个页面和导航一致，旧设置语义不变 |
| lib/components/navigation_bar.dart | 键盘显示时收起底栏，不重复占用页面高度 | 输入框紧邻键盘，收起键盘后恢复底栏，桌面侧栏不受影响 |
| lib/foundation/favorites.dart | 导入并混入通用批量通知能力 | 单次调用通知行为不变 |
| lib/foundation/read_later.dart | 同上 | 增删语义与原有表结构不变 |
| lib/utils/io.dart | 新增12行通用 withFileSelection 包装，复用原有文件选择状态 | 打开系统选图窗口时保持既有生命周期行为，完成/取消后还原状态 |
| pubspec.yaml / pubspec.lock | 新增 flutter_markdown_plus | 包管理器维护锁文件 |

新增 **lib/foundation/batched_notifications.dart** 不依赖 Agent、不读取数据库，仅在同步操作期间合并通知，可作为独立小补丁提交上游。Agent 适配层在通知窗口内复用原有单项方法。上游有等价接口后只替换适配层。

### 2.3 启动页兼容

旧 initialPage 保存 0=主页、1=收藏、2=探索、3=分类。MainPage 接入边界映射 **0→0、1→1、2→3、3→4**，非法值回退主页，不迁移或重写旧配置。Agent 可视索引固定为 2。通用 NaviPane 保留响应式断点和桌面栏；底部栏在键盘显示期间收起。

## 3. 已核对的应用接口

| 能力 | 使用方式及限制 |
| --- | --- |
| 初始化 | 等待 ComicSourceManager().init()，幂等异步初始化 |
| 源能力 | ComicSource.all()/find()，按运行时能力枚举，不硬编码源数量 |
| 详情 | loadComicInfo 类型允许 null，解析器通常生成包装函数；既检查 null，也检查 Res.error 后再取 data |
| 搜索 | 优先 loadPage，仅有 loadNext 时用游标；省略 options 按 defaultValue 补齐 |
| id 直达 | 显式 source_key、comic_id 直接传给源，不要求 idMatcher 或用户文本匹配；结果采用源规范 id，并保留输入别名。comic_resolve 的 idMatcher 只负责区分查询名称和 ID |
| URL | 仅对 linkHandler.domains 精确匹配的 URL 调用 linkToId，不从任意 URL 猜数字 id |
| 身份 | source_key + comic_id；经 ComicType.fromKey 转换，兼容 local 与 Unknown:<int> |
| 收藏 | folderNames、count、getFolderComics、searchInFolder、find、getComic、addComic、deleteComicWithId、createFolder |
| 稍后再看 | getAll、contains、add、remove、restore；在 Agent 内把详情适配成 Comic |
| UI 刷新 | 管理器 ChangeNotifier 通知已有页面 |
| 同步 | DataSync 监听收藏和源变更，并合并上传期间的等待任务；没有直接监听 ReadLaterManager |
| 备份 | exportAppData 使用显式文件清单，独立 Agent 目录不进入现有手动备份/WebDAV |

纠正原稿：“每次通知必定各上传一次”不准确；loadComicInfo 并非类型上永不为空；headless 在本期和后续都不规划第二入口。

## 4. 模块划分

新增目录 lib/agent 内包含：

| 文件 | 职责 |
| --- | --- |
| agent_models.dart | 配置、消息 parts、会话、漫画引用和展示模型 |
| agent_context.dart | 单次响应 token 统计、上下文摘要与压缩进度 |
| agent_store.dart | 本机配置/密钥、agent.db、会话与展示持久化 |
| agent_client.dart | 独立 Dio、首响应超时保护、SSE 聚合、非流式兼容 |
| agent_http_adapter.dart | 复用现有代理/DNS/TLS 设置，将取消信号传给 rhttp |
| agent_wire.dart | parts 的完整成对投影、摘要边界与当前用户要求保留 |
| agent_controller.dart | 会话生命周期、停止/重试、工具循环、补充消息与上下文压缩 |
| agent_tools.dart | 工具 schema、参数校验、源与集合适配 |
| agent_page.dart | 历史/对话/展示的响应式页面 |
| agent_settings_page.dart | 模型列表和配置编辑 |
| agent_message_view.dart | Markdown、思考与工具详情、用户消息 |
| agent_images.dart / agent_image_view.dart | 跨平台选图、内容格式校验、缩略图和放大预览 |
| agent_history_view.dart | 对话占用大小、搜索结果多选、批量删除 |
| agent_turn_view.dart / agent_activity_view.dart / agent_disclosure.dart | 同一任务的历史折叠、正文间过程组、各条目独立展开和状态恢复 |
| agent_showcase_view.dart | 普通展示、收藏/收藏夹与稍后再看折叠分组 |
| agent_integration.dart | 主页面入口和旧索引映射 |

工具在主 isolate 的 async 任务中复用 JS 和管理器实例，不增加 isolate、子进程、服务端或常驻后台任务。Agent 测试放在 test/agent/，通用通知测试独立放在 test/batched_notifications_test.dart。

## 5. 工具与适配契约

### 5.1 清单

| 组 | 工具 | 主要契约 |
| --- | --- | --- |
| 源 | list_sources | key、name、搜索样式、id_matcher、link_domains |
| 源 | list_search_options | source_key → 选项定义与默认值 |
| 发现 | search_source | source_key、keyword、page/cursor、options → items、has_more、next_cursor |
| 发现 | comic_open_by_id | source_key、comic_id → 详情与收藏/稍后再看状态 |
| 发现 | comic_resolve | query、可选 source_key、limit → 候选和 resolved_by；歧义返回可选源 |
| 发现 | comic_get | source_key、comic_id → 详情，排除内页和 thumbnails |
| 展示 | showcase_comics | comics 数组、title、note、append/replace → 分组和跳过原因 |
| 收藏 | fav_list_folders | 文件夹与实时 count |
| 收藏 | fav_list | folder、page、page_size → items、total、has_more |
| 收藏 | fav_search | keyword、可选 folder、page、page_size → 分页结果 |
| 收藏 | fav_check | comics 数组 → folders、folder、in_favorites |
| 收藏 | fav_add | folder、comics 数组 → 逐项回执 |
| 收藏 | fav_remove | comics 数组、可选 folder；省略为所有本地收藏夹 |
| 收藏 | fav_move | from_folder、to_folder、comics；同名文件夹或目标已有时跳过 |
| 收藏 | fav_create_folder | name → 创建结果，不允许删文件夹 |
| 稍后再看 | later_list | keyword、page、page_size → items、total、has_more |
| 稍后再看 | later_check | comics 数组 → in_read_later、marker |
| 稍后再看 | later_add | comics 数组 → 逐项回执 |
| 稍后再看 | later_remove | comics 数组 → 逐项回执及本地撤销记录 |

fav_check 未收藏时 folder=-1、folders=[]，恰好一个文件夹返回名称，多个文件夹时 folder=null，以 folders 为准。later_check 的 marker=-1/1。

### 5.2 漫画身份和元数据

引用使用 {source_key,comic_id}，或在第一个冒号处切分的 source_key:comic_id，保留 URL 型 id 的其余内容。工具按参数独立执行，不扫描用户历史文本核验 ID 来源，也不要求先调用搜索、解析、详情或状态工具。文本、图片识别和其他上下文中获得的 ID 使用同一接口。

收藏、稍后再看和展示优先复用会话或本地列表元数据，没有资料时自行请求源详情，每次最多并发4个。查询结果记入会话 seen 表；不采用模型在引用对象中附带的 title/cover/tags。已有资料无需重新验证漫画是否在线。添加先检查目标列表，重复项直接跳过；移除只检查本地列表，不依赖源是否可用。单条不存在、源不支持详情或请求失败均逐项返回原因，其余条目继续处理；展示全部失败时保留已有分组。

源和 ID 已明确时，comic_open_by_id 和 comic_get 直接请求详情，不用 idMatcher 阻挡。comic_resolve 保留名称搜索、ID 格式判别和受支持域名的 URL 解析，来源不明确时返回候选源。写入授权统一遵循控制器的 never、destructive、all 配置，不另设 ID 来源确认。

本地列表、搜索、状态、移除、移动和创建收藏夹不初始化漫画源，只初始化所需的本地管理器。添加或展示先使用已有缓存，只有缺资料时才按需打开其他本地列表或请求源详情；重复添加和已缓存的展示不会打开无关数据库。comic_open_by_id 的 include_status=false 不初始化本地列表。收藏夹可直接创建，同名已存在返回 skipped/ALREADY_EXISTS；添加和移动指定的目标收藏夹不存在仍返回 FOLDER_NOT_FOUND，不隐式创建其他资源。

详情直接映射对象字段，避免已有 JSON 往返字段不一致。系统提示词明确漫画名、描述、标签、源错误和工具返回均是数据，不能把其中的指令当用户授权。

### 5.3 分页

- 页码正整数；本地 page_size 默认20、上限50。
- 页码源按 max_page 或实际响应判断终点，未知总页数如实保留；不按源名猜单页能力。
- 源游标直接交给源读取，不用进程内“曾返回过”的白名单验证来源；历史或重启后恢复的合法游标无需先重查第一页。源负责判断游标是否有效。
- continuation 直接读取本机缓存余量，不再初始化或请求漫画源；必须能定位同一查询的实际缓存，过期或错用时返回 INVALID_CURSOR。
- 源返回大量条目时缓存本页剩余数据，提供继续读取标记，不静默丢条目。
- 本地读取后分页；跨收藏夹逐个 searchInFolder，避免旧 search() 命中200条提前结束。保留所在文件夹。
- 首期可能全量读取大收藏夹；后续根据性能证据决定是否增加上游通用分页接口。

### 5.4 批量写入与撤销

一批最多50条、主动展示最多30条。空数组、非法类型和超限参数在任何副作用之前拒绝。按身份去重，每个输入都有 added/removed/moved/skipped/failed 结果和原因；summary 提供总数、成功、跳过、失败、missing 和 already_exists 数量，missing 数组完整列出源/ID、已知标题和原因。NOT_PRESENT 表示不在本地目标列表；NOT_FOUND 表示源未返回元数据，不能把网络失败断言为漫画不存在。

添加先查重，再为缺少本地资料的条目取元数据，最后进入无 await 的本地同步写入窗口；每个网络请求前后和副作用前检查运行令牌。源请求超时或取消后返回的数据不得写库。添加成功或已存在的漫画自动更新会话的“收藏 → 收藏夹”或“稍后再看”展示分组；移除和移动同步更新相关展示，撤销移除后恢复展示。

通用能力只合并通知，不重写 SQL。首期采用**逐项提交、允许部分成功**，不承诺跨文件夹原子事务；写入结束统一通知一次，减少重建及同步触发。避免使用旧批量方法中异步缓存刷新、吞异常或事务内通知的路径。

移动通过受检查的添加/删除实现，先确认目标加入成功，再删源；目标已存在则保留源并跳过。删除前保存公开 API 返回的完整元数据、收藏时间和原文件夹，提供本地撤销按钮；只恢复本次实际删除条目，不覆盖用户后来新加的同身份记录。稍后再看的原始加入时间没有公开读取接口，撤销沿用 add 的新加入时间，不为保留排序修改原管理器。

### 5.5 完整结果

统一 {ok:true,data:...} 或 {ok:false,error:{code,message}}；批量部分失败通过逐项结果表达。常见码：SOURCE_NOT_FOUND、NO_SEARCH_SUPPORT、NO_DETAIL_SUPPORT、NO_LINK_SUPPORT、INVALID_ARGUMENT、INVALID_CURSOR、NOT_FOUND、SOURCE_REQUEST_FAILED、FOLDER_NOT_FOUND、FOLDER_EXISTS、BATCH_TOO_LARGE、TIMEOUT、CANCELLED。源仅返回错误文本时以 NOT_FOUND 表示未取得详情并保留原错误，不据此断言漫画不存在；抛出的请求异常与超时分别返回 SOURCE_REQUEST_FAILED 和 TIMEOUT。

模型正文、思考、工具参数和返回字段不再因软件设定的字符数或响应总长度而停止接收、截短或替换。完整返回合法 JSON，描述、标签、章节目录与推荐条目原样保留；搜索和列表仍提供明确分页，不静默丢弃条目。上下文大小由第7.1节的摘要机制处理。服务商自身的输出上限仍可能结束响应，界面明确提示该情况并保留已收到的内容，不执行不完整工具。

## 6. 配置、存储和网络

### 6.1 模型

每个模型保存 id、name、base_url、model、supports_vision、thinking_levels[{id,label,params}]、default_thinking、include_reasoning_in_context、extra_body、headers、context_window_tokens、可选 temperature 和流式开关。上下文容量默认128000，由用户按实际模型修改。移除最大工具轮数字段，旧配置中的该字段被忽略，不再写回。默认思考深度从上方 JSON 列表动态生成下拉选项；选项删除时回退到首项，无效 JSON 时禁用下拉并提示修正。

请求合并顺序：extra_body → 当前思考 params → 协议字段。model/messages/tools/tool_choice/stream 由客户端最后写入，防止配置绕开工具白名单。思考补丁按模型配置，不声称某厂商参数适用所有网关。

支持标准 base URL 或完整 chat/completions URL，只允许 http/https，不允许 userInfo 和 fragment。默认 confirm_policy=never，也提供 destructive（删除/移动）与 all；仅用户开启后才确认。停止必须解除待确认状态。

### 6.2 本机隔离

App.dataPath/agent 下保存 config.json、secrets.json（modelId→密钥）和 agent.db。全部仅本机，不进入既有 appdata、手动备份或 WebDAV；自定义 headers 同样视为敏感数据。后续同步通过明确排除密钥的导入导出实现。

配置和密钥串行原子写入，不记录密钥、headers 或聊天请求体。Windows 不声称支持 POSIX 0600；使用应用目录/当前用户权限。系统凭据库以后单列，不改平台工程。

SQLite 启用 foreign_keys=ON 和 user_version=3；消息、图片、展示、seen、撤销记录、上下文摘要和操作展示归属关联会话并级联删除。v1 升级从成功工具回执补齐旧会话的操作展示，不重放收藏/稍后再看的实际操作；v2 升级增加 message_images 并启用增量空间回收，保留原消息、模型设置和摘要。展示状态独立于消息，重试不清空面板。未完成消息恢复为 interrupted，排队的补充消息保留；损坏数据报告错误而非静默覆盖。

### 6.3 请求

独立 Dio 复用 RHttpAdapter 的代理/DNS/TLS 设置，不使用 AppDio 的15秒超时、正文日志和 Cloudflare 拦截器。连接20秒，提交请求到收到响应头最多60秒，帧间隔60秒。现有 RHttpAdapter 不完整转发 Dio 的取消和超时设置，因此由 AgentHttpAdapter 桥接 rhttp.CancelToken，并由 AgentClient 独立约束首响应等待；不把长时间流式响应误当成总请求超时。

SSE 处理 UTF-8/行分片、CRLF、空行、注释、usage 空 choices 和 [DONE]；请求 stream_options.include_usage=true，先解析 usage 再判断 choices。只处理 choice 0，按 tool_calls.index 聚合 id/name/arguments。收到完整终止后才校验并执行工具；半截 JSON、服务商 length 结束或无终止的断流不能执行。

支持直接返回的非流式 JSON和显式非流式配置；不对所有网络错误盲目自动重试。reasoning_content/reasoning 可显示及存储；默认不回传，按模型开关投影。

协议依据：[Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[Streaming events](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)。

### 6.4 图片输入与资源清理

- 复用现有 file_selector 跨平台多选；按文件内容识别 JPEG、PNG、WebP、静态 GIF，并验证可解码。单张图片上限20 MB，保留原图字节，不自动降质；动态图或无效文件明确提示。选择后的草稿提供缩略图、点击放大及移除，允许仅发送图片。
- `supports_vision=true` 时，user.content 按顺序投影为 text 与 image_url 数组，图片使用匹配 MIME 的 Base64 data URL；文本消息仍保持原有字符串格式。不支持视觉的模型在发送新图片前提示，保留用户草稿；不能静默丢弃上下文中的图片。
- 消息 JSON 只存图片 ID、文件名、MIME 和字节数；图片二进制保存在 message_images，并以消息为外键级联关联。消息与图片在同一事务提交，不留独立文件或 Base64 存储副本，也不删除用户原先选择的源文件。
- 运行中补充、重新生成、编辑后重发和关闭后继续均保留相应图片。压缩时保留识图结果；当前任务的用户图片继续随请求发送，较早任务可由摘要替代，但原始图片仍可在历史中查看。
- 历史每项显示“约 X KB/MB”，按图片字节、消息/工具记录/搜索文本、展示/撤销记录、摘要等 UTF-8 内容合计，不分摊数据库公共索引及结构开销。占用量读取 BLOB 长度，不把全部图片加载进内存。
- 可逐项多选或全选当前搜索结果，删除前显示数量与内容大小；取消保留选择。批量删除用一个事务清理会话及关联资源，启用 secure_delete 并执行 incremental_vacuum 回收磁盘空间。删除当前任务先停止并等待；删除其他历史不会替换正在流式更新的消息。

接口依据：[OpenAI 图片输入](https://developers.openai.com/api/docs/guides/images)、[Flutter file_selector](https://github.com/flutter/packages/blob/main/packages/file_selector/file_selector/README.md)。模型是否真正支持视觉由服务商决定，能力开关不改变服务商的模型能力。

## 7. 会话执行与重试

消息使用 text/reasoning/tool_call parts；工具 part 同时保存参数、状态、结果。assistant 记录实际 model_id/thinking。投影时 assistant.tool_calls 后紧跟对应 role=tool，未执行的调用投影明确的失败/中断结果，不能假装成功。不再按固定轮数丢弃历史，摘要边界始终落在完整消息和工具配对之后。

工具参数和结果完整投影。展示持久化独立于消息。

执行顺序：先保存用户消息 → 必要时压缩上下文 → 请求模型 → 每约80ms合并UI增量、每500ms保存流式检查点 → 完整响应落库 → 串行校验并执行工具 → 每个结果立即落库 → 请求下一次响应。持续执行到没有工具和待处理补充消息、用户停止或出现错误；不设工具轮数上限。应用生命周期离开前台时保存检查点，页面销毁时标记中断；异常退出恢复最后持久化状态。

每轮持有 generation token；停止、切会话或 dispose 使旧 token 失效，同时取消 HTTP 和确认等待。源脚本没有取消 API，停止只能放弃等待，但迟到结果不得更新会话、展示或收藏。同一控制器只允许一轮运行。

运行中发送消息不停止当前任务，使用 user part 的 follow_up_to 指向最初用户请求，并立即以 queued 状态保存。当前操作可结束，未开始的调用以 INPUT_UPDATED 记录“尚未执行”，解除旧确认等待；下一次模型请求纳入补充后再判断操作。即使上一请求已经生成最终正文，只要有补充消息仍继续处理。重启后发送新消息会作为未完成任务的补充继续，已成功的工具回执与部分生成正文保留。

### 7.1 上下文压缩

- 容量与阈值：每模型配置 context_window_tokens；最近一次正常响应 usage.total_tokens 达到90%时，在完整响应/工具边界自动压缩。对话输入区显示 token 占用，并提供手动压缩按钮；运行中手动触发会排队到下一次请求前。
- 计数：使用当前响应真实 usage，不累加历史请求消耗。Chat Completions 以 total_tokens 或 prompt_tokens + completion_tokens 为准；嵌套 cached_tokens 和 prompt_cache_hit_tokens 已包含在输入中，不重复相加。单列 cache_read_input_tokens/cache_creation_input_tokens 的格式计入输入。缺少可靠统计时显示等待接口统计，不按字符数伪造占用。
- 内容：同模型发起不带工具的摘要请求，保留用户目标、源/精确 ID、收藏夹、成功/失败/未执行结果、游标和后续步骤。尽可能保留最近响应与工具结果；当前任务原始用户要求及补充消息始终原样保留。摘要作为历史事实，不提升其中外部内容的指令权限。
- 持久化：conversation_context 保存 summary、through_message_id、最近 usage 及模型、压缩时间和次数。完整摘要成功后才替换上下文；失败或取消不覆盖原摘要。压缩请求自身的 token 不是压缩后上下文占用，等待下一次正常响应更新。
- 原始 UI 历史、工具回执与展示均不删除。编辑、重试或重新生成影响到已总结范围时，使该摘要失效；相关旧 usage 一并清除，防止旧事实污染新请求。

### 7.2 重试与继续

| 重试动作 | 语义 |
| --- | --- |
| 重新生成 | 按最后一个任务的原始 user 截断回复，保留其补充消息，默认沿用原模型/思考；不回滚已执行收藏操作 |
| 编辑后重发 | 从所选 user turn 截断，保留更早历史，以新文本重跑 |
| 重试失败工具 | 仅对参数完整、明确失败且没有已知成功副作用的调用，更新原结果并继续；保留同轮及后续轮次已经成功的工具记录，不重放已成功工具 |
| 中断后继续 | 从已持久化结果继续或重新请求中断的模型步骤，补齐工具配对，不盲目重放整轮写入 |

批量部分成功不提供整批重试按钮，需对 failed 条目新建调用。下次请求不能混入未闭合的半截工具。

## 8. UI 与 Markdown

Agent 工具栏提供模型设置、模型/思考选择、历史、展示、新对话。输入区只有一个主要操作按钮：空闲时发送，运行中草稿有文字或图片时插入消息，没有内容时暂停；输入变化即时切换，并保留仅图片发送。无配置时给出配置入口，无漫画源时指向现有源管理。

手机键盘显示时收起底部导航栏，由页面的 Scaffold 处理键盘避让，避免导航栏继续占高导致输入框与键盘之间留白。进入会话默认跟随最新消息；用户拖动、惯性滚动及按住列表期间暂停跟随，只有向最新消息方向上滑并在距底部160逻辑像素以内停下才恢复。向历史方向滑动或停在底部区域以外保持当前位置，流式更新不能抢占；嵌套工具详情滚动不改变消息列表的跟随状态。

每次模型请求仍有独立 assistant 记录，但同一任务仅显示一次 Agent 标题。运行中正文按顺序直接呈现；两段正文之间的连续思考和工具合成一个默认收起的“执行过程”组，显示思考/工具数量。分组跨模型响应边界合并，遇到正文或用户补充消息才分隔。展开组后列出各项，思考内容与工具参数/结果仍各自默认折叠，可单独或同时展开多个。过程组采用柔和背景、细边框和较淡的小字号文字，与16px正文区分，兼顾明暗主题。

完成后只保留最后一次请求的正文在外，之前的正文、全部过程组及运行中补充消息收进“已完成”历史区域，原始用户请求留在外面。停止或失败时外层历史默认展开，内部过程组仍默认折叠。折叠状态使用显式 PageStorage 标识，与详情内部滚动状态隔离；流式更新及手动收起再展开保留用户选择，任务完成时重置外层历史、内部过程组和各项详情为折叠状态。

使用内容区 LayoutBuilder 宽度：≥1024 显示历史+对话+展示；720–1023 显示对话+展示、历史弹层；<720 单栏对话，历史和展示分别打开弹层。不要用包含桌面导航的屏幕宽度判三栏。

漫画只出现在展示栏，复用 ComicTile 的详情导航和长按菜单。主动搜索/推荐保留普通展示组；收藏和稍后再看的添加结果按两个操作类型默认折叠，“收藏”内再按收藏夹折叠。分组以会话+类型+收藏夹复用并去重，点击工具的“查看漫画”可定位并展开对应组。单漫画移除用独立的小按钮列/行，不覆盖封面或标题；整组操作置于省略号菜单。移除只改变展示状态；关闭或重启后不复活，后续新操作仅重新显示本次涉及的漫画。删除会话级联清理所有展示。

Markdown 使用 flutter_markdown_plus（纯 Dart/Flutter，无原生工程配置），不加载 Markdown 外链图片或 HTML WebView；链接仅允许 http/https 并复用站内处理。使用 SelectionArea 包裹非 selectable 的 MarkdownBody，避免每段 SelectableText 的内层滚动争夺触摸手势，保留长按选择、复制和链接点击。流式更新节流，缓存已完成消息。

历史按标题和消息内容搜索，首条用户消息产生默认标题，纯图片消息使用首张图片的文件名。每项显示消息数与占用大小，支持多选和批量删除确认。当前模型和思考选择随会话保存。

## 9. 实施与验证

1. 提交设计修订与上游接入清单。
2. 实现通用批量通知并验证嵌套、异常和单项语义。
3. 实现存储、协议、工具、控制器、UI，最后接入第三个 Tab。
4. 用 Flutter 3.41.4 格式化实际修改文件，执行 analyze 和适当回归测试。
5. 检查 diff，确保原文件改动集中，不提交 venera-configs 等现有未跟踪内容。

验证重点：

- 五项导航和旧启动页映射、窄屏/宽屏布局。
- 同一轮多次模型响应的思考、正文、工具顺序；正文间过程组跨响应合并并默认折叠，内部多个思考块和工具详情可独立展开，完成时重置两层折叠。
- SSE 分片、多工具、非流式、断流不执行、配置不能覆盖协议字段。
- wire 配对、完整内容、模型/思考保存，失败重试不重放成功副作用。
- 超过旧工具轮数限制仍可完成；运行中补充会跳过未开始的调用，完成后补充折叠。
- 90%阈值、缓存计数、手动/自动压缩、失败/取消保留原上下文、编辑失效和重启恢复。
- 默认思考深度下拉随 JSON 变化，收藏按收藏夹分组、稍后再看折叠及旧会话展示迁移。
- 会话级联删除、重试保留展示、移除持久化、秘密隔离于已有备份清单。
- 批量上限、去重、写前检查、部分失败、一次通知，同 id 不同源区分，可信数据覆盖伪造 brief。
- 停止后迟到源响应不能写库，删除撤销不覆盖后来修改。
- 纯图片/图文/多图片请求格式、视觉能力校验、预览/移除、补充/编辑/重新生成/重启后的图片保留。
- 图片与消息事务一致性、v2 升级、资源大小统计、批量删除级联和实际磁盘空间回收；搜索全选不会删除未匹配的对话。

没有真实网关密钥时使用本机假 HTTP/假源验证协议和工具闭环，不宣称真实模型与漫画站已完成联调。

### 9.1 首次实现与图片功能验证记录（2026-09-12）

- 本期功能已实现，原有业务文件修改限定为 main_page.dart、favorites.dart、read_later.dart 及 io.dart 的12行通用选文件状态包装；图片功能复用现有依赖。新增依赖仍仅为 flutter_markdown_plus 及其传递依赖 markdown。
- Flutter 3.41.4 / Dart 3.11.1：修改范围内的静态分析通过；**97 项测试通过**，其中 Agent 85 项、通用通知1项、原有功能回归11项。另完成390/1440宽度的2项隔离渲染检查。
- 回归覆盖稍后再看、收藏输入、主页布局、原子写入、网络日志、漫画源设置和凭据同步。Agent 测试覆盖真实 MainPage 五项导航、旧启动设置、320/800/1200 宽度，以及详细/简略漫画展示。
- 360/1200 宽度的同轮执行测试保留3次模型响应、3个思考块、3段正文、4次工具调用及运行中补充，验证跨响应分组、默认折叠、各项独立展开、流式刷新保留选择及完成后重置；已修复折叠状态与内部滚动状态冲突。渲染检查覆盖手机/桌面的默认、组展开、详情展开及完成状态。
- 自动/手动压缩测试覆盖90%边界、真实 usage 字段解析、缓存不重复计数、摘要失败/取消、编辑失效和重启继续；连续20次工具响应可正常结束。添加/移除工具测试覆盖本地重复项、缺失条目回执、完整长内容以及操作展示分组的持久化迁移。
- 停止、页面销毁、首响应超时及迟到源结果均有测试；失败工具重试保留后续成功操作的记录；重启后的中断会话提供继续入口。
- 图片与资源管理新增17项测试，覆盖手机/桌面预览、发送、批量删除，及运行中补图、编辑/重试、压缩/重启、插入失败回滚、v2升级和磁盘空间回收。本机 HTTP 服务收到实际客户端发送的多图片 JSON，并验证图片 token usage 的保存；不以模拟响应宣称完成真实模型识图质量验证。390/1440宽度的渲染检查已核对图片草稿、放大预览和历史多选界面。
- **包含图片和资源管理功能的 Windows x64 Debug 已成功构建并启动**，已确认 Agent 页的图片入口、历史占用大小和管理入口正常显示。程序位于 `build/windows/x64/runner/Debug/venera.exe`，运行时需要同目录的 DLL 和 data 文件夹。本次未打包安装器，未构建 Android/iOS/macOS/Linux 产物。
- 本机使用目录 junction 准备生成的插件链接，复用已有 Visual Studio 2022 MSVC、Windows SDK 和 Android SDK 附带的 CMake；Flutter 生成配置后直接由 CMake/MSBuild 编译。rhttp 使用已获批准的隔离 Rust stable 工具链；NuGet 复用原插件在构建时下载的副本。没有修改平台工程、系统开发者模式或全局 PATH。
- 尚未使用真实模型密钥或真实漫画站验证；本机协议测试使用假 HTTP 服务和假源。

本机验证工具位于 `D:\.tool\flutter-3.41.4`，启动脚本为 `D:\.tool\flutter-venera.ps1`，卸载脚本为 `D:\.tool\uninstall-venera-flutter.ps1`。SDK、依赖缓存和测试临时数据不进入 Git。复现本次检查：

```powershell
& 'D:\.tool\flutter-venera.ps1' analyze --no-pub lib/agent lib/utils/io.dart lib/foundation/batched_notifications.dart lib/foundation/favorites.dart lib/foundation/read_later.dart lib/pages/main_page.dart test/agent test/batched_notifications_test.dart

$env:PATH = 'D:\.tool\venera-flutter-3.41.4-install\native;' + $env:PATH
& 'D:\.tool\flutter-venera.ps1' test --no-pub --concurrency=1 test/agent test/batched_notifications_test.dart test/read_later_test.dart test/favorites_input_test.dart test/home_layout_test.dart test/atomic_file_test.dart test/network_logging_test.dart test/comic_source_settings_test.dart test/credential_sync_test.dart
```

Rust 和 Cargo 缓存位于 `D:\.tool\rust-venera`，版本为 rustc/cargo 1.98.1，卸载脚本为 `D:\.tool\uninstall-venera-rust.ps1`。本机 Windows 构建脚本 `D:\.tool\venera-flutter-3.41.4-install\build-venera-windows.ps1` 封装了上述工具路径与隔离环境，运行结束后恢复调用进程的环境变量；`D:\.tool` 内的辅助 NuGet 副本和缓存由 Flutter 卸载脚本一并清理。复现构建：

```powershell
& 'D:\.tool\venera-flutter-3.41.4-install\build-venera-windows.ps1'
```

首次使用：进入中间的 **Agent** → **模型设置** → **添加模型**，填写服务商的 API 地址、模型 ID 和密钥。漫画源使用原应用的源管理；Agent 空白页提供入口。删除会话不会回滚收藏操作；删除收藏或稍后再看条目后，可在对应工具卡片中撤销。

识图使用：为支持视觉的模型开启 **模型支持视觉**，点击输入框左侧 **添加图片**，选择图片后可预览、移除，再随消息发送。资源管理位于 **历史对话 → 管理对话**，可按占用大小选择并批量删除。

### 9.2 移动交互与工具契约修复（2026-09-12）

- 修复键盘显示时底栏多占高度；运行中只保留随草稿切换的插入/暂停按钮。Markdown 改用统一选择区域，流式跟随区分用户滚动方向、底部距离、惯性滚动和手指按住状态。
- 审计全部19个工具，去掉用户文本、已见引用和源游标来源校验；漫画资料按需在工具内部补齐，重复添加、已有展示资料及本地操作不初始化无关资源，缓存续读不访问源。写前确认策略和逐项错误回执保留。
- 修改范围静态分析通过；**122项相关测试通过**，其中 Agent 115项、批量通知/稍后再看/收藏输入/主页布局7项。移动交互新增14项回归，包含 Android/iOS 的实际文本字形拖动、斜向拖动、长按复制、链接点击，以及键盘、按钮和跟随滚动场景。
- 工具测试使用假漫画源和模拟模型调用，覆盖仅图片消息下 never/destructive/all 三种确认策略。未进行真实手机、真实视觉模型或漫画站联调；本次修复未重新构建发布产物。

本次检查命令：

```powershell
& 'D:\.tool\flutter-venera.ps1' analyze --no-pub lib/agent lib/components/navigation_bar.dart test/agent

$env:PATH = 'D:\.tool\venera-flutter-3.41.4-install\native;' + $env:PATH
& 'D:\.tool\flutter-venera.ps1' test --no-pub --concurrency=1 test/agent test/batched_notifications_test.dart test/read_later_test.dart test/favorites_input_test.dart test/home_layout_test.dart
```

## 10. 后续范围与合并维护

图片收藏/历史只读工具、封面消歧专用工具、分享/详情页入口、会话导入导出、组级批量快捷操作为后续扩展；headless、网络收藏、通过工具获取章节图片、删除收藏夹不在本方案范围。

每次合并上游先检查第2.2节接入文件，再跑 Agent 协议、存储、集合与导航测试；API变化优先改 lib/agent 内的适配，保持上游代码改动面稳定。
