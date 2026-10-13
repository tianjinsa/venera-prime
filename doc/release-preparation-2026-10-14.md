# 发布准备记录（2026-10-14）

基于 master 的 PR #31 合并提交 6552a1b。用户要求再次检查后准备发布，并在本轮末尾明确停止测试。当前版本保持 2.5.0，未创建新版本标签或 Release；下一版说明位于 release-next.md，正式发布前需指定新版本并同步版本元数据。

## 复查后修复

- 已下载 APK 被删除或篡改后重新下载；清理 updater 专用目录中的旧包和中断临时文件；拒绝空名、根路径及非 APK 文件名。
- 更新弹窗按真实任务状态显示下载、完成、取消或失败，避免失败被误报为下载完成。
- 原生更新比较当前完整签名集合，并在安装权限返回后后台重新校验 APK，避免旧校验结果继续生效。
- 同名图源替换后探索页更新加载回调和页面缓存；保存图源数据时保留正式文件直到原子替换，避免并行备份遗漏。
- 连续模式首末长图未滚完时继续滚动本章，不提前跨章；新增真实长图手势回归。
- 后台悬浮入口支持 F6 聚焦、Enter/空格操作和聚焦高亮。

## 已完成验证

- 静态分析通过，完整回归 295 项通过、1 项可选外部 TLS 探测跳过。
- Android 主应用 Profile 和 Linux x64 Release 构建通过。
- Android 原生校验分别在单签和双签独立测试包执行：非法路径/格式、错误包名、旧 versionCode、错误签名、签名子集被拒绝；匹配包名、更新版本和完整签名集合被接受。
- Android 安装交互宿主脚本最终重跑通过：拒绝权限、授权等待期间替换文件被拦截、正确包打开系统安装器并取消。早期人工配合的一轮超时，不计为通过；以 installer-device-final.log 中 INSTALLER_PROBE: passed 和 All tests passed 为准。
- 主应用未卸载或替换；所有测试包使用独立 .integrationtest 包名。多签切换只卸载独立测试包。没有安装替代 runner 的 APK 夹具。

## 停测时保留事项

组合真机测试中追更与 WebDAV 用例执行通过，但探索页 3 项失败。日志明确是 test/support/follow_updates_cases.dart 中模拟 _Source 未实现 explorePages，遗留到同一 isolate 的探索页用例中；不是生产 ComicSource 缺少该属性。已给组合入口增加分组及源夹具清理，但根据用户“不要再测试”未重跑，不宣称组合真机回归全绿。

未执行完整 APK 升级后的数据保留验证、真实用户漫画站/坚果云服务验证，也未执行本轮六平台发布构建。发布前仍需选定版本、准备对应 release-X.Y.Z.md，并按 release-policy.md 走正式六平台构建、14 附件与签名核验、完成后清理 Actions 的流程。

原始证据保留于本机忽略目录 build/release-prep-2026-10-14/，包括 analyze.log、tests.log、native-single.log、native-multi.log、installer-device-final.log、regression-device.log、android-main-build.log、linux-build.log。没有将手机截图、私有备份、签名私钥或原始设备日志提交到仓库。
