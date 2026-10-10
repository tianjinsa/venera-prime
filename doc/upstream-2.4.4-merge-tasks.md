# 2.4.4 主分支合并任务

更新时间：2026-10-11。

## 任务列表

- [x] 核对工作区、远程、主分支和版本。
- [x] 审查 2.4.4 新增内容及与 Agent 分支现有修复的重叠。
- [x] 合并并解决历史分页、阅读器等区域的冲突，保留 Agent 功能及已验证的性能修复。
- [x] 完成相关回归、静态分析、构建与版本校验，记录既有失败和环境限制。
- [x] 记录最终取舍和验证结果，随中文合并提交交付。

## 合并基线

- 当前分支：`codex/agent-center-tab`，合并前提交 `6e65a5a`。
- 用户 fork：`origin`，实际主分支为 `master`（远程不存在 `main`）。
- `git fetch origin --prune` 后，待合并提交为 `b11502de5ae9f441714c8e88ff05912a94d05fdf`，版本 `2.4.4+244`。
- 共同祖先：`142395c0c73c96f1093cab008fafcce5dee4b19d`；主分支新增 1 个提交、涉及 32 个文件。
- 合并前已跟踪文件无未提交修改；保留原有无关未跟踪文件。
- 用户已确认上一轮审查通过，已知性能问题均未再次发现。

## 审查重点

- 双页阅读：页码映射、左右方向、首页独立与末页留白、单双页切换；与图片缓存预算、预取和退出进度保存兼容。
- 历史：搜索栏及日期滚动提示与后台分页、整库搜索和跨页选择兼容，不恢复全量同步加载或关键词屏蔽。
- WebDAV：自动同步关闭时不上传或递增版本，手动同步可用，排队任务重新检查开关；保留 WAL 备份完整性。
- 作者搜索：优先源自定义跳转，缺少规则时正确回退，保留复制行为。
- 旧收藏排序：相同或缺失排序值保持原始顺序；用户收藏、稍后再看和 Agent 推荐仍完整展示。

## 合并与验证记录

### 合并取舍

- 文本冲突限于 `lib/pages/history_page.dart` 和 `lib/pages/reader/images.dart`，逐块整合，保留两侧有效行为。
- 历史沿用 Agent 分支已有的单一顶部搜索框、后台每批 60 条分页、整库搜索和跨页选择。新增上游可拖动滚动条及日期提示，顶部只避让一个应用栏。
- `SliverGridComicsState.firstVisibleComic` 根据当前网格布局读取已缓存的过滤结果，日期提示无需重新过滤或读取整库。历史仍跳过关键词屏蔽，原有作者规则保持有效。
- 双页模式、左右方向、首页单独显示、末页留白、单双页切换及上游正确的图片索引映射均已接入。画廊继续在当前页变化后合并预取，保留内存压力降额、控制器释放和退出前保存最后进度。
- 作者搜索、WebDAV 自动同步门禁及请求合并、旧收藏夹稳定排序按上游接入。核对所有上传调用点，手动入口使用 `force: true`，自动保存继续受开关控制。
- Agent 模块、用户收藏/稍后再看不屏蔽、历史数据库与 WAL 备份逻辑未被上游替换。依赖版本和 Android 配置未变动。
- 上游历史真机用例适配当前搜索入口与异步分页；制作旧备份前先关闭 SQLite 连接，使测试归档包含完整 WAL 数据。

### 自动化验证

- `dart analyze lib test integration_test`：无问题。
- 版本校验脚本通过：`pubspec.yaml` 为 `2.4.4+244`，运行时为 `2.4.4`，发布说明匹配。
- 扩展回归启用现有 Windows SQLite/ZIP 原生库，仅按名称排除下面的符号链接权限用例：428 项通过、13 项失败、1 项按原条件跳过。日志：`.dart_tool/upstream-2.4.4/regression.log`。
- 13 项失败已在合并前 `6e65a5a` 的独立源码快照、相同依赖和运行环境中全部复现：`webview_platform_test.dart` 的 12 种组合未构建 Windows 下预期的模拟视图；`image_downloader_test.dart` 在清理临时目录时遇到文件占用错误 32。它们不是本次合并新增的回归，相关代码和用例没有改动。基线日志：`.dart_tool/upstream-2.4.4/baseline-regression.log`。
- 原有 TLS 探测测试因未配置 `PRIME_TLS_URL` 跳过。
- 首次全量运行中，`download_retry_test.dart` 的 `restored end-of-chapter cursor rewinds without counting existing pages twice` 在创建符号链接时返回 Windows 错误 1314，后续回归按名称排除此项。日志：`.dart_tool/upstream-2.4.4/regression-symlink-environment.log`。
- 系统/用户 `TEMP/TMP` 确实指向 R 盘；测试包装脚本显式覆盖为 `D:\.tool\venera-android-history-20261010\temp`。已检查该目录和父目录无重解析点，D 盘为 NTFS，当前进程未列出 `SeCreateSymbolicLinkPrivilege`，因此本次符号链接失败符合权限不足，不能归因于系统临时目录位于内存盘。未改变系统权限或临时目录配置。
- 新增两种历史布局的日期拖动回归：关键词匹配记录仍显示、作者过滤后日期对应可见条目、拖到末尾继续读取下一批、100 次日期查询不重复读取描述/标签、搜索未加载记录后日期随之更新。原有 1200 条懒加载、整库搜索、选择和封面回归继续通过。
- 双页回归覆盖排列、方向、单独首页、末页留白和位置转换，并验证退出时保存真实图片页码。作者搜索、旧收藏排序、WebDAV 真实本地 HTTP 门禁和请求合并、备份恢复及 Agent 回归均通过。

### Android 构建

- 使用现有环境构建 Android arm64 Profile 开发包，Gradle 阶段 40.3 秒；沿用本地 NDK 覆盖配置，已有版本提示不影响本次构建，未安装新工具。
- 已验证包名 `com.github.wgh136.venera.prime.dev`、应用名 `Venera Prime Dev`、版本 `2.4.4 / 244` 和必需 arm64 原生库。
- 产物：`.dart_tool/upstream-2.4.4/venera-prime-2.4.4-agent-dev.apk`。
- SHA-256：`1869AB978842CA071A795DA733DA23A263523BAE86E0CDAED063FFA33EC7E607`。
- 构建日志：`.dart_tool/upstream-2.4.4/android-build.log`。本次合并完成自动化与构建验证，未进行新版真机安装或交互验证。
