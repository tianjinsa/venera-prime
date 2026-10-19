# 2.6.2 发布准备检查记录

检查日期：2026-10-17。基线为 `422dc5b`（2.6.1）；当前准备版本为用户指定的 `2.6.2+262`。

## 当前结果

- Flutter 3.41.4、Linux x64 环境：完整 Flutter 回归 334 项通过，2 项外部配置测试跳过。
- 启用 `PRIME_NATIVE_ZIP_TEST=1`，使用本地 `build/linux/x64/release/bundle/lib` 原生库；跳过项缺少 `PRIME_TLS_URL`、`PRIME_UPDATE_FEED`，原生更新模拟测试已运行。
- AltStore 单元测试 3 项、发布身份规则单元测试 6 项通过。
- `dart analyze lib test` 无错误、无警告；保留 `lib/pages/settings/about.dart:59` 既有的 `sort_child_properties_last` 提示。
- `flutter build linux --release --no-pub` 成功，程序位于 `build/linux/x64/release/bundle/venera`。
- `RELEASE_TAG=v2.6.2 python3 tool/check_version.py` 通过，运行时版本、pubspec 及说明标题一致；标签名仅用于检查，尚未创建标签。
- `git diff --check` 通过，工作流 YAML 和 AltStore JSON 结构检查通过；没有执行 actionlint 或线上 Actions。
- 只读检查远端：master 仍为基线提交，当前没有 `v2.6.2` 标签或该版本 Release。

## Release 说明核对

- 读取当前 issue 正文、作者与评论，核实 #37 为 @h0stg、#39 为 @lzx377z、#40 为 @zklall；#41、#42 已由提出者统一到 #40。
- #38 为下载管理新功能提案，本次没有实现，不列为已完成内容。
- #34 的提出者 @MisakaTukasa 已明确反馈“功能符合预期效果，未发现 bug”，不再列为历史待确认。
- 历史待确认表保留本轮能读取并核实的 #26、#33、#35、#36。旧说明中的 #21、#22、#28、#32 当前无法通过 issue 查询读取，未沿用旧作者或确认状态；其中 #28 的 REST API 明确返回已删除。
- 已读取线上 v2.4.4 的正文作为写作参考；本版测试数字和验证范围均来自当前检查，没有沿用历史真机或构建结论。
- 新增功能及修复的具体范围见 `doc/release-2.6.2.md`；WAL 与多设备同步排查见 `doc/webdav-sync-2026-10-17.md`。

## 发布执行约定

本记录保存提交前的本地准备结果。记录时尚未提交、推送、创建标签或发布，未关闭 issue，未修改既有 Release；正式发布结果以随后执行的工作流为准。

正式发布时沿用 Anonymous 或 github-actions[bot] 的 author 和 committer；通过既有机器人流程完成 Android、iOS、macOS、Windows、Linux x64、Linux ARM64 六平台构建及十四个标准附件。以六平台和机器人 Release 任务全部成功作为完成条件，随后记录实际工作流结果，并按既有授权清理已完成的 run 记录。

准备阶段 AltStore 源保留已发布的 2.6.1，没有提前生成 2.6.2 IPA 地址和大小；正式发布成功后，新增工作流读取真实元数据更新源。

本轮没有执行真机安装、真实图源/WebDAV 服务流程、用户原始备份完整恢复或上一版本应用内升级；正式发布前后应据实际结果更新 Release 的验证范围。

## 正式发布结果

- 发布提交：`87fccc405785cb9d2a1581752386abce3fa7bc20`，标签 `v2.6.2`；author、committer 均为 `Anonymous <anonymous@users.noreply.github.com>`。
- [2.6.2 Release](https://github.com/venera-app/venera-prime/releases/tag/v2.6.2) 已正式发布，发布者为 `github-actions[bot]`，不是草稿或预发布。
- [发布工作流 39022448858](https://github.com/venera-app/venera-prime/actions/runs/39022448858)：版本与身份校验、Android、iOS、macOS、Windows、Linux x64、Linux ARM64、Release、Update_AltStore 九项任务全部成功，无失败、取消或跳过任务。
- AltStore 机器人更新提交为 `56263d8`，已快进同步回本地；源使用 Prime 包名和实际发布的 2.6.2 元数据。
- 本轮初始 push 校验工作流为 [39022427450](https://github.com/venera-app/venera-prime/actions/runs/39022427450)，已成功完成。
- 按授权在保留上述结果后清理已完成的 Actions run 记录，因此工作流链接随后可能不可访问；保留 Release、标签和发布附件。
- 本轮未单独下载、核验线上附件、比对哈希或检查 APK 签名；构建成功不代表完成真机安装及升级验证。
