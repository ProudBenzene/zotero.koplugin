# Zotero 协议核对与修复记录

首次核对日期：**2026-10-07**；下载时间单位、压缩文件 hash 与 Kindle 稳定性补核日期：**2026-10-08**。审查基线：插件 commit `73caca82e5d084367181c9347249664121158abe`。以下记录协议、原实现及后续调整；首次修复的 46 项离线回归全部通过，当前 Lua 5.1 和 Lua 5.4 均为 **87/87 项通过**。

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

常规测试使用 KOReader、HTTP、JSON 与摘要计算的 test doubles，并执行真实临时文件读写及 `unzip`。另在 Lua 5.1 中换用官方 [KOReader sha2 模块](https://github.com/koreader/koreader-base/blob/master/ffi/sha2.lua) 和 [LuaSocket URL 模块](https://github.com/lunarmodules/luasocket/blob/master/src/url.lua) 重跑首次修复的 46 项测试，全部通过，确认增量摘要、Base64 和 URL 接口兼容。首次提交时尚未执行真实服务联调；后续验证见下文。

## 2026-10-08：WebDAV 下载截断补核

对一次解包失败的附件进行了只读联调。服务器声明 ZIP 长度为 15,870,667 字节，多次普通 GET 提前结束，实际收到的字节数小于声明值。取回完整归档后，文件名匹配现有实现，ZIP CRC 校验通过；主 PDF 为 17,233,664 字节，MD5 与 Zotero 附件元数据一致，PDF 工具可以解析出 34 页，未加密。没有发现这份远端 PDF 或 ZIP 本身损坏。设备失败时的临时 ZIP 已被清理，因此无法直接核对截图对应的那一次下载。

下载实现新增响应长度检查。短响应提供强 ETag 时，使用 `Range` / `If-Range` 最多续传三次；只有返回的范围、总长度和 ETag 均吻合才追加数据。服务器返回完整的 200 响应时替换临时副本；不把它追加到已有片段。续传条件依据 [HTTP RFC 9110 §13.1.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5)。失败删除片段并保留已验证的缓存。

修改后的插件下载逻辑通过真实 WebDAV 验证：首次收到 15,564,800 字节，随后两次续传分别收到 278,528 和 27,339 字节，最终解包及主文件 MD5 校验成功。此次联调通过 Python HTTP 适配器驱动 Lua 插件逻辑，缓存只写临时目录；并未运行 Kindle ARM 上的 LuaSocket/TLS 栈或 PDF 阅读器。目标设备仍需安装新版后复测。

当前 Lua 5.1 与 Lua 5.4 下均为 **76/76 项离线回归通过**，新增覆盖短响应、续传范围/ETag 不一致、服务器忽略范围、重试上限，以及压缩 Zotero Storage 响应头的保留。

## 2026-10-08：大库加载、分页超时与设备日志

只读检查 Kindle Oasis 3 上的插件及缓存，设备日志报告 KOReader v2026.03。现有 `library.json` 为 28,215,548 字节，包含 7,176 个对象、42 个集合、737 个可浏览 PDF/EPUB 附件。笔记 HTML 和批注正文占据了大部分空间，浏览与下载并不需要这些内容。此前加载完整 JSON、保留全部字段，以及阅读器初始化时重置已加载状态，都会增加设备的等待与内存占用。

新增 `librarycache.lua`，大于 2 MiB 的旧快照按 64 KiB 分块、逐对象解码与投影，避免同时保留完整输入和全部正文。较小快照继续使用现有 JSON 解码器。投影只影响插件本地快照，保留所有对象 key、版本、集合层级、显示与校验所需字段；同步收到的对象也立即投影。首次迁移原设备快照后，文件为 **1,275,505 字节**，上述数量保持不变。已加载快照在相同账号的阅读器初始化之间复用，冷启动 Browse 先显示加载提示。

截图中的分页 `sink timeout` 与原有元数据请求的 30 秒总时限相符：即使数据持续到达，该时限也会结束响应。现移除元数据与文件请求的固定总时限，保留 KOReader 的 10 秒元数据、15 秒文件 socket blocking timeout。连接临时超时、提前关闭、响应长度不足和 HTTP 502/504 最多尝试三次，只重试当前页；响应完整后才解析和合并。429/503 仍按 Zotero 的退避规则处理，不立即重复请求。[KOReader socketutil](https://github.com/koreader/koreader/blob/master/frontend/socketutil.lua)、[Zotero rate limiting](https://www.zotero.org/support/dev/web_api/v3/basics#rate_limiting)

用真实云端库执行一次强制全量同步，条目分页完成到第 73 页，随后集合请求完成，结果为 **7,176 个对象、42 个集合、737 个可浏览附件**，新快照为 1,275,506 字节；耗时 **402.2 秒**，本轮没有触发连接重试。该检查通过 Python HTTP/JSON 适配器运行 Lua 5.1 插件逻辑，只写临时目录，没有修改设备缓存、云端条目或配置；它不验证 Kindle ARM 的 LuaSocket/TLS、输入与屏幕实现。

首次 WebDAV 解包失败、第二次成功，仍不足以证明那一次失败的具体原因：旧版已删除失败的 ZIP，通用错误也未保存 `unzip` 输出。现捕获具体解包诊断和退出状态；识别到下载归档损坏时自动重新下载一次，同时保留一份失败归档及 `download-error.log`，包括附件 key、归档大小与诊断。即使重试成功也保留，便于核对偶发问题；缺少指定文件或解压命令不兼容不自动重试。凭据及认证请求头不写入诊断文件。

附带的 Kindle TXT/TGZ 报告属于 `KPPMainAppV2`、`cvm` 等原生进程，其中可见 `SIGABRT`、`could not open the kpp_daemon_fm file` 和系统低内存事件。KOReader `crash.log` 中另有内存警告及大量 input `Broken pipe`，未找到能归因到插件的 Lua traceback。缓存精简能减少插件内存负担，但这些记录不能证明所有原生崩溃均由插件引起，或已被这次修改全部解决。归档只在内存中读取，未执行其中内容。

当前 **87/87** 项回归在 Lua 5.1 与 Lua 5.4 下通过，新增覆盖持续接收超过旧时限、同页有限重试与旧快照保护、缓存精简与账号失效、分块读取边界、冷启动加载提示，以及损坏 WebDAV ZIP 重试后仍保留主文件诊断。
