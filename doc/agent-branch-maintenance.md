# Agent 分支功能总表与上游合并流程

本文件是 `codex/agent-center-tab` 的持续维护入口。目的：合并上游时保留本分支新增功能和既有功能的优化，同时接入上游有效修复。代码可以改写或由上游等价实现替代，但必须逐项核对用户可见行为和数据完整性；Git 无冲突不代表行为没有丢失。

## 1. 本次盘点基线

| 项目 | 2026-11-05 盘点结果 |
| --- | --- |
| 开发分支 | `codex/agent-center-tab` |
| 盘点的开发提交 | `c467bf9a99527f4b2fc52d95bd89f96a5512a0e3` |
| 开发分支已合入的 master 基线（共同祖先） | `efd5d908cbb2227d2ce22f073917352cbd904759`，2.7.0 |
| 本次读取的 fork master | `228fd8d08b3b7c8f40959cc15f7434c163ba50b3` |
| master 尚未合入的内容 | 包含 2.7.1 的瀑布流阅读、可定制主页，以及 2.7.2 的 WebDAV 同步和主页收藏导航修复；本次只盘点，没有执行合并 |
| 当前 origin | `https://github.com/tianjinsa/venera-prime.git`，用户 fork |
| 源仓库 | `https://github.com/venera-app/venera-prime`；GitHub Sync fork 用于将其 master 更新到用户 fork 的 master |

下表基于 `git log origin/master..HEAD`、`git diff origin/master...HEAD`、现有实现及测试整理，覆盖仍保留的分支差异。共同基线已有的下载、同步、备份、阅读等功能列为合并回归保护项，不重复认定为本分支原创。这里的测试均为**现有验证入口**，不是本次运行通过的声明。

## 2. 新增功能与优化总表

代码路径相对仓库根目录；测试路径除特别说明外相对 `test/`。编号用于后续合并记录，新增条目时继续编号，不重排已有编号。

### 2.1 Agent 功能

| 编号 | 功能与必须保留的行为 | 主要实现 | 验证入口 |
| --- | --- | --- | --- |
| A01 | 独立 Agent 导航：手机和宽屏均有入口；旧启动页 0/1/2/3 映射到 0/1/3/4，非法值回退主页；首次进入才初始化 | `lib/pages/main_page.dart`、`lib/components/navigation_bar.dart`、`lib/agent/agent_integration.dart` | `agent/agent_page_test.dart`、`navigation_bar_layout_test.dart` |
| A02 | 进程内后台持续运行：切换页面不停止任务，导航展示运行/待确认状态，返回可继续查看；不能将其承诺为杀进程后仍运行 | `lib/agent/agent_session.dart`、`lib/agent/agent_notice.dart` | `agent/agent_session_test.dart` |
| A03 | 三种协议：Chat Completions、OpenAI Responses、Anthropic Messages；流式/非流式、工具结果续接、协议原生思考深度和网络取消继续可用 | `lib/agent/agent_protocol.dart`、`lib/agent/agent_client.dart`、`lib/agent/agent_http_adapter.dart` | `agent/agent_protocol_test.dart`、`agent/agent_protocols_test.dart`、`agent/agent_http_adapter_test.dart` |
| A04 | 模型管理：连接/密钥/图片输入/思考/请求补丁设置、模型切换、复制配置；按当前连接获取服务商模型列表，支持分页与搜索选择 ID；配置编辑和取消不丢已有值 | `lib/agent/agent_model_settings.dart`、`lib/agent/agent_model_discovery.dart`、`lib/agent/agent_model_picker.dart`、`lib/agent/agent_model_header.dart` | `agent/agent_model_editor_test.dart`、`agent/agent_model_discovery_test.dart`、`agent/agent_model_picker_test.dart`、`agent/agent_model_header_test.dart` |
| A05 | 多轮任务、停止、重试、重新生成、编辑重发；运行中插入消息与队列消息语义分开；队列顺序、取消、附件和重启恢复可用 | `lib/agent/agent_controller.dart`、`lib/agent/agent_queue_view.dart`、`lib/agent/agent_store.dart` | `agent/agent_controller_test.dart`、`agent/agent_message_queue_test.dart`、`agent/agent_queue_view_test.dart` |
| A06 | 上下文管理：按真实 token 用量接近容量时压缩，也可手动压缩；保留原记录、当前要求及成对的工具调用/结果，不用固定字符截断代替上下文管理 | `lib/agent/agent_context.dart`、`lib/agent/agent_wire.dart`、`lib/agent/agent_controller.dart` | `agent/agent_context_controller_test.dart` |
| A07 | 图片和纯文本附件：选择、校验、预览、仅附件发送、持久化、删除与资源清理；Android 使用原生相册，完成/取消后恢复应用文件选择状态 | `lib/agent/agent_images.dart`、`lib/agent/agent_files.dart`、`lib/utils/io.dart`、`android/app/src/main/kotlin/com/github/wgh136/venera/AgentImagePicker.kt` 及 `MainActivity.kt` | `agent/agent_image_picker_test.dart`、`agent/agent_images_resources_test.dart`、`agent/agent_text_files_test.dart`、`agent/agent_text_files_page_test.dart` |
| A08 | 漫画封面识图：`comic_read_cover` 读取实际图片，跨三种协议发送，支持历史预览；仅浏览漫画不自动上传封面；不扩展为章节图片读取 | `lib/agent/agent_tools_cover.dart`、`lib/agent/agent_wire.dart`、`lib/agent/agent_message_view.dart` | `agent/agent_cover_test.dart` |
| A09 | 会话管理与资源管理：新建、搜索、切换、重命名、删除、占用大小、搜索结果多选删除；图片/文本资源可查看并正确清理 | `lib/agent/agent_history_view.dart`、`lib/agent/agent_store.dart`、`lib/agent/agent_image_view.dart` | `agent/agent_images_history_page_test.dart`、`agent/agent_images_resources_test.dart`、`agent/agent_text_files_page_test.dart` |
| A10 | 漫画工具覆盖源、搜索/发现/分类/排行/评论、详情/章节、展示、收藏、稍后再看、追更、历史、本地漫画、下载、网络收藏、屏蔽词、统计和页面导航；批量逐项回执、长列表分页，旧会话调用保持兼容；明确源与 ID 时不强制前置搜索 | `lib/agent/agent_tools*.dart`、`lib/agent/agent_app_bridge.dart`、`lib/agent/agent_tool_schemas.dart` | `agent/agent_more_tools_test.dart`、`agent/agent_storage_tools_test.dart`；逐工具契约见 [Agent 设计](agent_design.md) 第 5 节 |
| A11 | 漫画源诊断/编辑：读取日志、代码分页与搜索、精确替换、解析成功后生效；失败不能破坏原源；自动/手动备份独立限额，自动超额淘汰最旧自动备份，手动备份达到限额时报错；还原前保留当前代码 | `lib/agent/agent_tools_code.dart`、`lib/agent/agent_source_backups.dart`、`lib/agent/agent_backup_settings.dart`、`lib/foundation/log.dart` | `agent/agent_more_tools_test.dart`、`agent/agent_storage_tools_test.dart` |
| A12 | 独立联网：Bing、Google、Tavily、DeepSeek 分别配置和启用；与聊天模型配置独立；只暴露已启用引擎，验证页面/普通回答不能冒充搜索结果 | `lib/agent/agent_web_search.dart`、`lib/agent/agent_search_browser.dart`、`lib/agent/agent_search_settings.dart` | `agent/agent_web_search_test.dart`、`agent/agent_web_search_settings_test.dart`；限制见 [网络搜索](agent_web_search.md) |
| A13 | 模型原生联网：Responses / Messages 使用协议工具，保留搜索过程、引用链接及续接；换模型或压缩后保留可读来源，服务端私有搜索块不跨模型误用；Chat Completions 不假装具有统一原生搜索接口 | `lib/agent/agent_protocol.dart`、`lib/agent/agent_search_results.dart`、`lib/agent/agent_web_links.dart` | `agent/agent_native_search_test.dart`、`agent/agent_protocols_test.dart` |
| A14 | 对话体验与性能：流式长内容按需渲染，思考/工具/历史任务分层折叠；消息和 Markdown 可拖动滚动；用户离开底部后不强制跟随；输入区与上下文条一起避让键盘；模型选择和浅色菜单风格保持一致 | `lib/agent/agent_page.dart`、`lib/agent/agent_message_view.dart`、`lib/agent/agent_floating_composer.dart`、`lib/agent/agent_settings_widgets.dart` | `agent/agent_long_content_test.dart`、`agent/agent_markdown_scroll_test.dart`、`agent/agent_chat_interaction_test.dart`、`agent/agent_floating_composer_test.dart`、`agent/agent_settings_layout_test.dart` |
| A15 | 展示与本地操作性能：漫画卡片按需构建、集合分页读取、优先复用已有元数据，不为单项操作扫描整库或打开无关数据库；使用既有管理器 API 和通用批量通知，避免每条操作触发整页刷新 | `lib/agent/agent_showcase_view.dart`、`lib/agent/agent_tools_library.dart`、`lib/foundation/batched_notifications.dart`、`lib/foundation/read_later.dart`、`lib/foundation/favorites.dart` | `agent/agent_showcase_performance_test.dart`、`agent/agent_storage_tools_test.dart`、`batched_notifications_test.dart`、`favorites_batch_move_test.dart` |

### 2.2 既有页面与阅读体验优化

| 编号 | 功能与必须保留的行为 | 主要实现 | 验证入口 |
| --- | --- | --- | --- |
| O01 | 历史后台分页：首批 60 条、接近底部继续读取；按时间/ID/类型稳定排序，时间相同不漏不重；整库搜索及跨未加载页的选择/删除保持完整，过期请求不能覆盖新结果；不恢复全量同步首屏加载 | `lib/foundation/history.dart`、`lib/foundation/history_pager.dart`、`lib/pages/history_page.dart` | `history_pager_test.dart`、`history_pagination_test.dart`、`history_page_test.dart`、`history_search_test.dart`、`integration_test/history_performance_test.dart` |
| O02 | 历史封面：按展示尺寸解码、复用刷新结果；已有有效封面不因页面重建再请求详情；无效封面恢复去重、限并发和冷却，取消后不继续无用加载 | `lib/components/image.dart`、`lib/foundation/image_provider/history_image_provider.dart` | `history_image_provider_test.dart`、`history_page_test.dart` |
| O03 | 弱网封面：共享请求队列，默认最多 6 个并发，同 key 合并、失败冷却，所有消费者取消时跳过待执行请求 | `lib/network/thumbnail_request_queue.dart`、`lib/network/images.dart`、`lib/foundation/image_provider/base_image_provider.dart` | `thumbnail_request_queue_test.dart`、`image_downloader_test.dart` |
| O04 | 独立作者屏蔽：与标题关键词分开，避免同名标题误屏蔽；共享不可变规则快照，复用描述和标签计算，规则原地修改也使缓存失效；关键词按字面匹配，不意外当正则 | `lib/foundation/comic_blocking.dart`、`lib/components/comic.dart`、`lib/pages/settings/explore_settings.dart`、`lib/foundation/appdata.dart` | `comic_blocking_test.dart`、`comic_grid_filtering_test.dart`、`integration_test/comic_blocking_performance_test.dart` |
| O05 | 屏蔽范围：历史跳过关键词屏蔽，仍应用独立作者规则；本地/网络收藏、追更、稍后再看及 Agent 展示不应用关键词和作者屏蔽；发现、分类、排行和普通搜索保留默认屏蔽；收藏搜索与已读筛选仍有效 | `lib/pages/history_page.dart`、`lib/pages/favorites/`、`lib/pages/follow_updates_page.dart`、`lib/pages/read_later_page.dart`、`lib/components/comic.dart` | `comic_grid_filtering_test.dart`、`history_page_test.dart`、`read_later_page_test.dart`、`agent/agent_showcase_filtering_test.dart` |
| O06 | 列表性能：键盘显示/隐藏不导致漫画列表无意义重建；收藏筛选复用、批量已读/选择通知合并；关闭追更后晚到请求不能恢复旧追更状态 | `lib/foundation/context.dart`、`lib/pages/favorites/local_favorites_page.dart`、`lib/pages/history_page.dart`、`lib/pages/follow_updates_page.dart` | `keyboard_list_performance_test.dart`、`favorites_keyboard_performance_test.dart`、`list_performance_test.dart`、`follow_updates_test.dart` |
| O07 | 阅读缓存：按可用内存 1/16 估算，限制 32–192 MiB；压力通知降至最多 32 MiB 并暂停主动预解码；退出延迟收缩，快速重入取消旧收缩，旧异步结果不能修改新会话预算 | `lib/foundation/reader_image_cache.dart`、`lib/pages/reader/reader.dart`、`lib/pages/reader/images.dart` | `reader_image_cache_test.dart`、`integration_test/reader_performance_test.dart` |
| O08 | 阅读生命周期：退出/后台立即保存最后进度和阅读统计；取消定时器、移除监听并释放分页/缩放控制器；预取安排在页变化后的帧中，退出后的手势、滚动、电量异步回调不可访问已销毁页面；兼容双页真实图片页码 | `lib/pages/reader/reader.dart`、`lib/pages/reader/images.dart`、`lib/pages/reader/gesture.dart`、`lib/pages/reader/scaffold.dart` | `reader_scrubbing_test.dart`、`reader_spread_test.dart`、`reading_statistics_test.dart`、`integration_test/reader_performance_test.dart` |
| O09 | 漫画线条增强与夜览：增强开关/强度，暗色/暖色/红色夜览及强度可组合；保持黑色墨线，减少冷色且不提亮纸白；仅作用于阅读内容，评论可跳过增强但保留夜览；实时调整不重建阅读子树、不丢页码/控制器，保留设备/单漫画设置优先级 | `lib/utils/reader_appearance.dart`、`lib/pages/settings/reader.dart`、`lib/pages/reader/scaffold.dart`、`lib/foundation/appdata.dart` | `reader_color_effects_test.dart`、`reader_appearance_controls_test.dart` |
| O10 | 数据完整性：历史分页独立连接/WAL 不阻塞进度保存；导出用 SQLite 快照包含已提交 WAL；恢复前等待后台读取退出；数据库锁或权限错误不能误判为损坏后重建；收藏读取冲突保留原数据 | `lib/foundation/history.dart`、`lib/foundation/favorites.dart`、`lib/utils/data.dart` | `history_pagination_test.dart`、`data_backup_test.dart`、`favorites_locking_test.dart`、`integration_test/history_legacy_test.dart` |

相关定位提交：Agent 初接入 `cfd8a4c`；后台任务 `c54b3f8`；作者屏蔽 `8af9806`；弱网封面 `6e2cbb6`；历史分页 `d05a02c`；阅读缓存/退出 `2f55f73`；规则复用 `7c88309`；用户列表过滤范围 `5dd8b7a`；联网 `6d59b32`；模型发现/封面识图 `1234488`；线条增强/夜览 `c467bf9`。提交用于追溯设计，不要求合并时逐个重放。

## 3. 高频冲突区域与边界

| 区域 | 合并时必须同时保留 |
| --- | --- |
| 主页、导航、启动页设置 | 上游主页布局和导航修复，以及 A01/A02/A14 的入口、启动页映射、后台状态和键盘布局；新增主页入口也须检查硬编码索引 |
| 历史页、漫画列表组件 | 上游搜索、日期滚动提示、列表布局，以及 O01–O06 的后台分页、跨页选择、过滤范围和缓存；不能把全库搜索降为当前已加载页搜索 |
| 阅读器 images/reader/scaffold/gesture | 上游阅读模式、双页/瀑布流/方向/章节导航，与 O07–O09 的缓存、生命周期、最后进度和实时颜色效果；新增模式逐个核对是否接入效果与清理 |
| 收藏、追更、稍后再看 | 上游数据迁移和排序、取消追更修复，以及批量通知、单项查询、完整展示；不可绕过管理器直接改库 |
| 备份、导入、WebDAV | 上游同步开关、请求队列、导入恢复，以及 O10 的 WAL 快照/等待后台读取；不把独立 Agent 目录或密钥自动纳入现有备份和同步 |
| 网络层、Android method channel、依赖锁文件 | 既有代理/DNS/TLS/取消链路、原生文件选择及临时资源清理；新增依赖与上游依赖一起解析，不能通过全选某侧锁文件掩盖依赖丢失 |

Agent 的会话、模型配置及密钥保存在独立本机目录，现有应用备份/WebDAV 不包含它们。后台持续运行仅限当前应用进程。模型/搜索服务兼容性和平台 WebView 限制见 [Agent 设计](agent_design.md) 与 [网络搜索](agent_web_search.md)。历史性能报告中的特定设备数据不等于任意设备性能保证，详见 [历史与阅读性能记录](history-performance-tasks.md)。详细文档与实现冲突时先核对实现及测试，再修正文档，不能据过期描述删功能。

## 4. 合并上游的操作流程

以下命令在仓库根目录执行，仅在用户要求同步/合并时使用；本文件本身不授权自动推送或发布。

### 第一步：确认与保留现场

1. 阅读 `AGENTS.md`、本总表及本次上游变更说明。执行 `git status --short --branch`，确认开发分支及未提交/未跟踪文件；有改动先保留，不强制切换、重置或清理。
2. 在开发分支上记录完整 `HEAD`，创建不重名的本地备份分支，例如 `git branch backup/agent-before-merge-YYYYMMDD-HHMM HEAD`。它只保护已提交内容，未提交/未跟踪文件需要另行保留。已有备份不能强制覆盖。
3. 使用 GitHub 的 Sync fork 将源仓库 master 同步到 fork master。确认同步方向正确；若 GitHub 提示有分歧，先审查，不使用丢弃本地提交的同步选项。

### 第二步：只获取并审查差异

```bash
git fetch origin refs/heads/master:refs/remotes/origin/master
git branch --show-current
git rev-parse HEAD origin/master
git merge-base HEAD origin/master
git log --oneline HEAD..origin/master
git diff --stat HEAD...origin/master
git diff --name-status origin/master...HEAD
```

显式 refspec 兼容云环境仅检出单个引用、没有通用 fetch 映射的情况。上述 fetch 若因本地引用分歧拒绝更新，先检查原因，不加 `+` 强制覆盖。记录本次两侧完整 SHA 和共同祖先；前一个 diff 用于查看上游新增，后一个用于查看本分支待保留的内容。

把本次触及的 A/O 编号和高频冲突区域写进第 6 节。特别检查无文本冲突却改变调用链、默认值、初始化时机和设置优先级的地方。

### 第三步：在开发分支合并

确认仍在 `codex/agent-center-tab` 且现场已保留，再执行：

```bash
git merge --no-ff --no-commit origin/master
```

逐块整合冲突，不能对阅读器、历史页等共享文件一律选择 ours/theirs。上游出现等价优化时可以采用，但须在总表记录替代位置和行为验证，避免重复缓存、监听、写库或双重过滤。无法保留的行为须明确记录并处理，不能静默删除。

完成后检查 `git diff --name-only --diff-filter=U` 为空，并检查相对合并前备份分支的差异。需要放弃本次合并时，在确认原有工作已保护且仍处合并状态后使用 `git merge --abort`；不要用强制 reset 回退。

### 第四步：按行为验证

1. 每个受影响编号至少运行对应现有测试，并核对用户可见路径。公共层变更需扩大到调用方；小范围功能变更不必机械执行全部真机套件。
2. 完整上游合并建议执行以下基础检查（需已有 Flutter 和项目原生依赖）：

```bash
flutter pub get
git diff --check
flutter analyze
flutter test test/agent/
flutter test
```

检查依赖解析造成的锁文件变化是否合理，不手工删依赖凑通过。全量测试中的平台原生库、设备或服务配置要求以项目现有测试为准。失败先诊断；只有在合并前基线、同环境也复现时，才可归类为既有失败。明确区分通过、失败、跳过和未运行。

3. 手动/设备回归至少逐项核对受影响场景：

- Agent：进入五栏导航、旧启动页、切换模型、流式工具调用、离开再返回、停止/重试、插入与排队、图片/文本附件、封面识图、联网来源及会话重开。
- 历史/收藏：超过 60 条后滚动、搜索未加载记录、同时间记录、跨页全选/删除/撤销、日期拖动、键盘弹出、关键词与作者屏蔽范围、关闭追更后的晚到请求。
- 阅读器：横向/连续/双页及新加入的模式、方向/首页/末页、快速进入退出、后台前最后进度、压力通知后翻页、线条增强与各夜览模式实时切换和单漫画设置。
- 数据：旧备份导入、历史 WAL 最新进度导出恢复、WebDAV 自动关闭与手动同步、下载暂停/重试和原有收藏/稍后再看操作。

性能脚本在 `integration_test/history_performance_test.dart`、`integration_test/comic_blocking_performance_test.dart`、`integration_test/reader_performance_test.dart`；驱动为 `tool/performance_driver.dart`。需设备/原生配置才能运行，不用空跑代替真机证据。搜索官网联调需显式启用，见 [联网任务记录](agent-web-search-tasks.md)。

### 第五步：更新记录并交付

核对全部受影响条目，记录实际命令、结果、未验证场景和已诊断限制；新增上游功能更新总表或回归保护项。按 `AGENTS.md` 的提交身份要求提交已审查的合并结果；不要夹带密钥、用户数据、临时构建产物或无关改动。推送、构建发布和版本变更按用户要求及 [发布规范](release-policy.md) 单独处理。

## 5. 后续维护规则

- 新功能或优化随同实现更新本文件：用户行为、编号、代码位置、测试入口、兼容边界都应写清楚；只写提交标题不足以指导合并。
- 功能拆分、路径移动或被上游替代时同步修正定位，注明替代关系；用户明确决定移除时记录原因，避免下次错误恢复。
- 合并后更新基线及第 6 节；历史合并详情可另存报告并在这里链接，功能总表保持一份。
- 本文件降低功能遗漏风险，不能替代代码审查、数据验证或真机回归。没有执行的验证不得标记为通过。

## 6. 维护与合并记录

### 2026-11-05：首次建立总表

- 开发基线与远程 master 见第 1 节；本次未合并 master、未修改应用功能。
- 已按分支差异、实现和现有测试入口盘点 A01–A15、O01–O10，并添加 `AGENTS.md` 维护入口。
- 验证范围为文档路径、基线和差异检查；未重新执行 Flutter、设备或联网服务测试，历史文档的测试结果不视为本次结果。

### 2026-11-05：合并源仓库 2.7.2

- 合并前 HEAD：`375d050`；备份：`backup/agent-before-merge-20261105-2107`。
- 源仓库 master 与 fork master 均为 `228fd8d08b3b7c8f40959cc15f7434c163ba50b3`，共同祖先 `efd5d908cbb2227d2ce22f073917352cbd904759`，无需重复同步远端。
- 合入 2.7.1/2.7.2：瀑布流阅读、自定义主页与收藏夹快捷入口、WebDAV 数据变更通知及传输超时修复。
- 影响 A01/A02/A10/A15、O02/O03/O05–O10。唯一文本冲突为 AGENTS.md，保留功能维护和代理提交身份规则，并加入上游 issue 状态核对规则。
- 行为审查：瀑布流继承原连续阅读的缓存与释放链路，颜色效果仍由外层 scaffold 应用；历史后台分页/WAL 快照未被替换；稍后再看的通知仍经过批量通知 mixin；主页收藏入口使用独立 FavoritesPage，不依赖主导航下标；Agent 独立目录不进入 WebDAV。
- `git diff --check`、未解决冲突检查通过；Flutter 验证在本次工具优化完成后统一执行并补记。设备和真实 WebDAV 账号回归未运行。

### 下一次合并记录模板（待填写，不代表完成）

```text
日期 / 操作者：
合并前开发 SHA / 备份分支：
目标 origin/master SHA / 共同祖先：
上游新增内容：
受影响的 A/O 编号和共享文件：
逐项处理：保留 / 上游等价替代（位置与证据）/ 经用户确认移除
冲突与无冲突行为变化的取舍：
执行命令与结果：
通过 / 失败 / 跳过 / 未运行：
数据和设备回归结果：
剩余问题与下一步：
合并结果 SHA / 详细报告：
```
