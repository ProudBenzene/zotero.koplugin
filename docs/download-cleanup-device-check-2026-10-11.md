# 2026-10-11：Kindle 本机下载清理核对与修复

## 设备核对结果

用户实机结果为“已删除 1；目标已变化 5”。只读检查 `/Volumes/Kindle/koreader` 确认结果准确：删除只部分生效，没有清空所有本机下载。

| 文献 | 附件 key | PDF 与附件目录 | 本地阅读数据与批注缓存 |
| --- | --- | --- | --- |
| 何畅等，脑损伤上肢康复机器人及其临床应用研究 | `3BK26PJN` | 已不存在 | 文档旁目录也已不存在 |
| McManus，2020，Surface EMG | `9JXX5ISC` | 保留，6,793,985 字节 | `.sdr` 主文件/备份、批注缓存均保留 |
| Xia，2022，Startle | `DL6T9KVX` | 保留，1,267,176 字节 | 均保留 |
| He，2025，Multimodal assessment | `GG438MBA` | 保留，4,594,472 字节 | 均保留 |
| Chen，2025，Next-Generation Neurotechnologies | `P2G6RBX4` | 保留，20,637,010 字节 | 均保留 |
| Gordon，2023，Somato-cognitive action network | `Q2SYD2JN` | 保留，17,233,664 字节 | 均保留 |

剩余 5 份 PDF 合计 **50,526,307 字节（约 48.2 MiB）**，逐份 MD5 都与原下载收据及当前主库元数据一致。没有 `.zotero-cleanup.json` 待重试记录。账户配置和主库文件仍存在；本次未读取账户凭据，也未访问云端。

设备为 KOReader `v2026.07.2`，只加载一份 `zotero.koplugin`；其 `main.lua`、`downloadcleanup.lua`、`localfiles.lua` 与初版交付源码逐字节一致，排除旧副本误装。初版 `downloadcleanup.lua` SHA-256 为 `81fdc120ffa1269f47c2e443ea0a88f27ff88c225645c55a80136e17c3eefaa9`。

## 变化判断的问题与修复

初版要求扫描和删除时 `size/modification/change/ino/dev` 全部相同。inode 与 ctime 不是跨时间稳定的内容身份：Linux FAT 实现会在 inode 缓存缺失时重新分配 inode 编号。[Linux FAT 的 inode 重建实现](https://github.com/torvalds/linux/blob/v4.9/fs/fat/inode.c)

设备现存 PDF 内容未变化，旧日志却未记录具体失败字段，无法还原当次扫描与删除之间哪一项属性发生变化。因此，将此次结果归因于 inode/ctime 波动属于与复现一致的解释，尚非设备运行时字段的直接证据。

修正版在生成预览时计算实际文件内容 MD5，执行删除前重新核对路径、大小和内容。inode/ctime 单独变化不再导致新任务跳过；同样大小、同样时间戳的内容替换仍能识别并保留。旧版未带内容摘要的持久化记录继续按原规则兼容检查。

文件摘要按 64 KiB 块读取，扫描和删除均分批交回 UI。新增日志记录被跳过的附件 key 及原因（存储路径、文献路径、大小、内容或清理记录），不记录批注正文与凭据。路径边界、符号链接、打开文档及共享阅读数据保护保持生效。

## 验证证据

- 完整离线回归 **195/195 通过**，新增 inode/ctime 波动、同大小同 stat 内容替换、读取失败、未完成记录与 UI 分批校验检查。
- 使用设备实际 `frontend/docsettings.lua` 执行原生 PDF/EPUB 清理检查，**117 项通过**；真实 JSON **18 项通过**。
- 在临时目录复制设备的 5 份完整 PDF、收据、批注缓存和文档旁设置，再添加一份先删除的控制文档。使用设备实际 `ffi/sha2.lua` 与真实 JSON，模拟第一次删除后 inode/ctime 重建：初版得到 **1 删除、5 跳过**，修正版得到 **6 删除、0 跳过、0 失败、0 待清理**，共 **31 项通过**。每份副本的完整目录均已清理，主库保持，无 HTTP 请求。

复现命令（设备仍安装初版时）：

```sh
pandoc lua tests/run.lua
pandoc lua tests/json-integration.lua
pandoc lua tests/localfiles-integration.lua /Volumes/Kindle/koreader/frontend/docsettings.lua
pandoc lua tests/downloadcleanup-device-integration.lua /Volumes/Kindle/koreader
```

设备副本检查中的文件系统属性、文档设置对象与 UI/历史/收藏接口使用替身；原生 DocSettings 另有独立检查。它验证修正后的兼容性与删除边界，不等同于在 Kindle 上执行新版。

本次检查没有安装插件、再次删除 Kindle 文献或修改设备阅读数据；剩余 5 份仍在。修正版包为 `dist/zotero.koplugin-download-cleanup-fix-2026-10-11.zip`，设备复验步骤见 [本机下载清理测试说明](kindle-download-cleanup-test.md)。

后续用户反馈：重试已解决问题，现在可以完全删除本机上的文献。上述剩余文件统计是当时只读检查的快照，不代表重试后的设备状态。
