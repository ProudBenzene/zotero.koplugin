# Zotero 协议核对与修复记录

首次核对日期：**2026-10-07**；下载时间单位与压缩文件 hash 补核日期：**2026-10-08**。审查基线：插件 commit `73caca82e5d084367181c9347249664121158abe`。以下记录协议、原实现及本轮已实施的调整；Lua 5.1 和 Lua 5.4 的 **46 项离线回归均全部通过**。

官方 Web API 的 [basics](https://www.zotero.org/support/dev/web_api/v3/basics) 与 [file_upload](https://www.zotero.org/support/dev/web_api/v3/file_upload) 页面最近更新时间为 2026-07-29；[syncing](https://www.zotero.org/support/dev/web_api/v3/syncing) 页面为 2022-08-14。文档较旧的下载细节另外核对了官方源码：

- Zotero Desktop：[`9cbba8c4d281dbd6ef33b0083da17cac173397ba`](https://github.com/zotero/zotero/commit/9cbba8c4d281dbd6ef33b0083da17cac173397ba)，2026-10-06。
- Zotero Data Server：[`7e05073df379939bb5252846efd9e5c635b483b3`](https://github.com/zotero/dataserver/commit/7e05073df379939bb5252846efd9e5c635b483b3)，2026-10-05。开源实现用于协议核对，不等同于线上部署版本证明。

## Web API

| 核对项 | 官方约定 | 原实现 → 本轮代码实现 |
|---|---|---|
| 版本与认证 | 仍推荐 HTTPS、API v3、Header API Key。[文档](https://www.zotero.org/support/dev/web_api/v3/basics#api_versioning) | 保留有效协议，移除密钥日志。 |
| 分页 | `limit` 最大 100；`Link` 的 `rel="next"` 给出下一页。[文档](https://www.zotero.org/support/dev/web_api/v3/basics#sorting_and_pagination) | HEAD 估算数量再循环 → 跟随下一页，检查循环、响应及逐页版本。 |
| 回收站 | `includeTrashed=1` 用于 Items endpoints。[文档](https://www.zotero.org/support/dev/web_api/v3/basics#search_parameters_items_endpoints) | items/collections 均传 `true` → items 传 `1`；collections 删除该参数。 |
| 退避 | 成功响应也可能有 `Backoff`；429 遵守 `Retry-After`，缺省时指数退避；503 也可能要求等待。[文档](https://www.zotero.org/support/dev/web_api/v3/basics#rate_limiting) | 忽略 → 记录等待期限，推迟后续请求并提示原因。 |
| 增量与删除 | `since` 是上次成功同步的库版本；永久删除需读 `/deleted?since=…`。[文档](https://www.zotero.org/support/dev/web_api/v3/syncing#ii_get_deleted_data) | 只看对象 `deleted` 字段 → 增量合并删除记录；全量从空快照重建，无需历史删除日志。 |
| 一致性 | 各响应的 `Last-Modified-Version` 必须一致；变化时重启。首个条件请求的 304 表示库未变。[文档](https://www.zotero.org/support/dev/web_api/v3/syncing#iii_check_for_concurrent_remote_updates)、[304](https://www.zotero.org/support/dev/web_api/v3/syncing#i_get_updated_data) | 最后版本直接覆盖 → 暂存整轮结果，一致后原子提交；最多尝试 3 轮，304 保留缓存。 |

`/deleted?since=0` 有效：服务端只拒绝缺省的 `false`，参数验证接受 0；本插件全量重建时不必请求它。[DeletedController](https://github.com/zotero/dataserver/blob/7e05073df379939bb5252846efd9e5c635b483b3/controllers/DeletedController.php#L71)、[参数验证](https://github.com/zotero/dataserver/blob/7e05073df379939bb5252846efd9e5c635b483b3/model/API.inc.php#L288)

条目、集合和版本改为同一 `library.json` 原子快照，owner 为 `user_id` 与 API key 的 SHA-256 指纹。账号/密钥变化不会沿用旧快照；同步前调用 `/keys/current` 核对所属用户与读取权限。[官方权限核对](https://www.zotero.org/support/dev/web_api/v3/syncing#1_verify_key_access)

## 附件与文件下载

官方格式允许 `imported_url` PDF，以及缺省/`false` 的顶层 `parentItem`。原实现拒绝前者，并把 `false` 拼接进路径；本轮已覆盖。[附件文档](https://www.zotero.org/support/dev/web_api/v3/file_upload#i_get_attachment_item_template)、[顶层附件](https://www.zotero.org/support/dev/web_api/v3/file_upload#ii_create_child_attachment_item)

文档要求下载文件 `ETag` 与附件 `md5` 一致；该简述需要结合压缩文件实现理解。[文件下载](https://www.zotero.org/support/dev/web_api/v3/file_upload#ii_download_the_existing_file)

官方客户端下载分两步：API 的 302 提供 `Location` 与 `Zotero-File-MD5`、`Zotero-File-Modification-Time`、`Zotero-File-Compressed`，再下载文件。时间头为**毫秒**：客户端读取后直接传给 `new Date(mtime)`。[客户端 zfs.js](https://github.com/zotero/zotero/blob/9cbba8c4d281dbd6ef33b0083da17cac173397ba/chrome/content/zotero/xpcom/storage/zfs.js#L86)

压缩下载时，`Zotero-File-MD5` 指 **ZIP** 的 hash；附件 `data.md5` 指**主文件**。服务端分别保存 `zipMD5` 与 `md5`，最终 ZIP 的 ETag 不能与主文件 md5 比较；应先校验归档，再解包校验主文件。服务端也可转向附件代理，Location 不能限定为 S3。[ItemsController 下载/上传](https://github.com/zotero/dataserver/blob/7e05073df379939bb5252846efd9e5c635b483b3/controllers/ItemsController.php#L947)、[两类 hash 入库](https://github.com/zotero/dataserver/blob/7e05073df379939bb5252846efd9e5c635b483b3/model/Storage.inc.php#L556)

已改为跨来源移除认证头、阻止 HTTPS 降级、按用户及附件 key 独立缓存，校验临时文件后替换目标；失败保留旧文件。已保留 302 元数据，分别校验 ZIP 与主文件，文件 mtime 落盘时由毫秒转为秒。它们是本插件的实现保护措施，并非 API 新增功能。

## WebDAV

官方当前使用同一附件 key 的 `<KEY>.zip` 与 `<KEY>.prop`；`.prop` 为 `<properties version="1"><mtime>…</mtime><hash>…</hash></properties>`，其中 mtime 为毫秒、hash 为主文件 MD5。读取端仍兼容仅含秒时间戳的旧 `.prop`。这些是 Zotero 文件同步约定，不能用 WebDAV 服务器自身的 ZIP ETag 代替主文件 hash。[webdav.js 元数据](https://github.com/zotero/zotero/blob/9cbba8c4d281dbd6ef33b0083da17cac173397ba/chrome/content/zotero/xpcom/storage/webdav.js#L1456)、[文件地址](https://github.com/zotero/zotero/blob/9cbba8c4d281dbd6ef33b0083da17cac173397ba/chrome/content/zotero/xpcom/storage/webdav.js#L1670)

当前 ZIP 写入普通相对路径；官方解压端兼容 `Base64(相对路径) + "%ZB64"` 旧名称。本轮已兼容这两类主文件名，通过 `unzip -p` 输出指定主文件到临时文件，避免解压覆盖及错误解释退出码。[ZIP 写入](https://github.com/zotero/zotero/blob/9cbba8c4d281dbd6ef33b0083da17cac173397ba/chrome/content/zotero/xpcom/file.js#L1553)、[兼容解码](https://github.com/zotero/zotero/blob/9cbba8c4d281dbd6ef33b0083da17cac173397ba/chrome/content/zotero/xpcom/storage/storageLocal.js#L835)

连接检查已区分传输错误、拒绝访问及其他 HTTP 状态，并使用 `PROPFIND`、`Depth: 0` 和 XML 请求体。[官方检查](https://github.com/zotero/zotero/blob/9cbba8c4d281dbd6ef33b0083da17cac173397ba/chrome/content/zotero/xpcom/storage/webdav.js#L949)

插件 WebDAV **仅支持 Basic**，不增加 Digest 或写入同步。下载以 Web API 的附件 md5 校验主文件，不请求 `.prop`；它提供本轮只读下载所需的完整性检查。云端元数据与 WebDAV 文件不同步时下载会失败，需先在 Zotero 完成同步。

## 本轮范围

API v3 并未过时，当前问题主要来自旧插件实现。此次保留个人云端资料库、PDF/EPUB 浏览与下载；不增加群组库、本地 API、双向条目同步或 annotation 上传。

搜索、返回导航、初始化失败及失效测试属于插件内部问题，随本次修复处理。46 项离线回归在 Lua 5.1 和 Lua 5.4 下均通过，覆盖同步一致性与删除、下载失败保留缓存、跳转与压缩归档、附件格式以及界面导航等。

常规测试使用 KOReader、HTTP、JSON 与摘要计算的 test doubles，并执行真实临时文件读写及 `unzip`。另在 Lua 5.1 中换用官方 [KOReader sha2 模块](https://github.com/koreader/koreader-base/blob/master/ffi/sha2.lua) 和 [LuaSocket URL 模块](https://github.com/lunarmodules/luasocket/blob/master/src/url.lua) 重跑这 46 项测试，全部通过，确认增量摘要、Base64 和 URL 接口兼容。外部 JSON 库与真实网络栈未做集成验证；KOReader 真机、真实 Zotero 云端与用户 WebDAV 服务的联调尚未执行。
