# Zotero 云端 → KOReader 单向 PDF 批注同步

本功能使用独立批注缓存，保留原有主库同步和附件下载架构，不引入 SQLite。Zotero 云端是导入批注的唯一来源；插件通过 GET 读取批注和附件元数据，不向 Zotero 或 WebDAV 上传批注。批注导入通过 KOReader 当前文档的设置对象保存，不改写 PDF。

## 使用与维护

1. 升级插件后执行 **Synchronize（同步）**。主库同步成功后，插件为已下载 PDF 补取完整批注，不重新下载 PDF。之后根据精简主库中的批注 key、version、parentItem 判断变化，跳过未变附件。
2. 从插件首次打开 PDF 时，先完成现有下载/校验，再补取缺失或不匹配的批注缓存。批注网络请求失败仍允许打开 PDF，显示未更新提示；上次成功应用的结果继续可用。
3. 后续打开使用缓存。通过“最近阅读”或文件管理器打开受管 PDF 也会应用缓存，读取过程不自动联网。
4. 阅读中执行 Synchronize 只更新独立缓存。关闭并重新打开 PDF 后才替换当前显示的导入项。
5. **Maintenance → Refetch downloaded PDF annotations（重新获取已下载 PDF 的批注）** 先同步主库，再绕过变化判断，重新获取每个已下载 PDF。单个失败不影响其他附件，旧缓存保留。
6. 单个 PDF 可以在 **Browse 中长按附件 → 更新批注（Refresh annotations）**。这会强制读取该 PDF 的完整云端批注快照，不同步全库、不下载 PDF。未下载 PDF 的按钮禁用，EPUB 不显示该按钮；多附件文献先进入附件列表，再长按具体 PDF。
7. 释放空间：**Browse 长按 PDF → 删除本地文件（Delete local file）**，确认后移除本机 PDF、下载校验收据、独立批注缓存、KOReader 本地批注、书签及阅读进度。云端条目和文件、插件主库元数据保留，条目恢复为“未下载”，之后可重新下载。正在阅读的 PDF 需先关闭；未下载 PDF 的按钮禁用，EPUB 不提供此入口。

仅在 Zotero 云端增改批注后重开已缓存 PDF，不会自动联网更新，需要先执行 Synchronize 或上述单文件更新。**Resync entire collection** 先重建主库元数据，再同步已下载 PDF 的批注；它也会补取缺失/发生变化的批注缓存。Synchronize 和 Resync 都不会为未下载 PDF 保存完整批注正文，主库只保留它们的精简索引。

缓存损坏时，从插件打开 PDF 或执行上述维护操作即可重新获取。PDF 文件身份改变后，必须通过插件下载并校验匹配的文件，再应用该文件的批注；从最近阅读打开旧文件不会自动下载。主库版本落后于独立批注缓存时，插件不会根据旧索引推断删除。

KOReader 中没有来源标记的本地批注、书签及阅读进度保留。对 Zotero 导入项修改文字、评论、颜色、范围或在本地删除，均不上传；重新打开时依据最近成功缓存恢复。已有其他同步实现创建的条目不会仅凭相同正文、位置或日期被认领、合并或删除。

## 当前兼容范围

| 项目 | 行为 |
| --- | --- |
| 目标平台 | Kindle Oasis 3、KOReader v2026.03 / v2026.07.2，使用官方构建；真机状态见后文 |
| 批注类型 | PDF `highlight`、`underline`、`image`（区域）；支持多矩形及 `nextPageRects` 跨两页高亮 |
| 批注内容 | 选中文字、附属评论、颜色、日期、云端修改与删除 |
| 页几何 | 标准页框、按批注所在页读取宽高，允许混合页尺寸 |
| 显示方式 | 原版页面，复用 KOReader 的缩放、裁边、屏幕方向、绘制与点击入口 |
| 重排模式 | 隐藏 Zotero 导入叠层；批注列表仍可查看文字和评论 |
| 颜色 | 标准颜色映射至 KOReader 色板，Zotero 品红色映射至紫色；自定义 RGB 选最近色，原值保留 |
| 暂不支持 | EPUB 批注、便笺、墨迹批注、独立裁剪图预览、特殊或非零原点 CropBox、PDF 内置页旋转、组库 |

区域批注使用原始矩形绘制空心边框，保留 PDF 原图。点击区域内部可查看附属评论；没有评论时显示“无附属评论”。没有选中文字的区域在列表中显示“区域批注”。本功能支持查看 Zotero 已创建的区域，不增加 KOReader 内创建并上传 Zotero 区域批注的功能，也不下载额外的裁剪图片。

不支持的类型跳过并计数。支持类型的位置字段损坏、页码越界或读取页尺寸失败时，整份 PDF 的本次转换失败，保留该 PDF 原有导入结果和应用状态，下次打开重试。对特殊页几何，越界矩形会被拒绝；没有实现全面检测 CropBox 或 PDF 内置旋转，不能把通过边界检查视为这些文件已受支持。

导入矩形直接使用 Zotero 的 PDF 坐标，转换为 KOReader 原版页面坐标：`x=x0`、`y=pageHeight-y1`、`w=x1-x0`、`h=y1-y0`。显示时不重新寻找文字框，因此不依赖 OCR 文本层或多栏文本排序。每页的缩放、可见区域及屏幕偏移由 KOReader 原有转换处理；物理设备的屏幕方向与实际落点仍需验收。

## 独立缓存格式

路径为 `<KOReader data directory>/zotero/storage/<userID>/<attachmentKey>/.zotero-annotations.json`。每次仅处理一份 PDF 的完整快照。主库 `library.json` 继续保留精简批注索引，不增加批注正文。

格式版本 `format=1`，示例：

```json
{
  "format": 1,
  "user_id": "123",
  "attachment_key": "ATTACH01",
  "library_version": 42,
  "file_identity": { "md5": "5d41402abc4b2a76b9719d911017c592" },
  "items": [
    {
      "key": "ANNOT001",
      "version": 41,
      "data": {
        "itemType": "annotation",
        "parentItem": "ATTACH01",
        "annotationType": "highlight",
        "annotationPosition": "{\"pageIndex\":0,\"rects\":[[10,100,100,120]]}",
        "annotationText": "选中的文字",
        "annotationComment": "附属评论",
        "annotationColor": "#2ea8e5",
        "annotationPageLabel": "1",
        "annotationSortIndex": "00000|000001|00100",
        "dateAdded": "2026-10-08T04:00:00Z",
        "dateModified": "2026-10-08T05:00:00Z"
      }
    }
  ]
}
```

`file_identity` 优先使用云端 MD5；没有 MD5 时退回附件版本 `{ "version": 41 }`。应用时与已验证本地文件的 `.zotero-cache.json` 收据核对，不在每次打开时重新计算整个 PDF 的 MD5。此核对沿用附件缓存的约定：收据对应插件完成下载校验的文件。

快照写入同目录 `.zotero-annotations.json.tmp`，成功写入、关闭后重命名替换。失败保留原文件并清理临时文件。缓存只保留显示相关字段，原始颜色与位置不丢失。UTC/带时区日期转换为设备本地时间；空评论不创建评论标记。

快照版本与应用版本分别记录。`zotero_annotations_applied` 位于 KOReader 正常 sidecar，包含账号、附件 key、库版本、文件身份和 `converter_version=2`（区域显示支持）。缓存格式仍为 `format=1`，旧格式快照可以直接重新转换。转换/设置失败不推进应用记录；导入列表与该记录由正常 SaveSettings/flush 一同持久化。独立缓存成功写入不代表已成功显示。

每条导入项的 `zotero_source` 标记包含：

```lua
{
    plugin = "zotero.koplugin",
    user_id = "123",
    attachment_key = "ATTACH01",
    annotation_key = "ANNOT001",
    version = 41,
    sort_index = "00000|000001|00100",
    annotation_type = "highlight",
}
```

只有账号、附件及插件标识全部匹配的条目会被重建。完整、合法的空快照移除全部所属导入项；HTTP 错误、对象型响应 `{}`、分页缺项、版本不一致或转换失败均不能变成“批注已清空”。缓存损坏时，在文件身份仍匹配的条件下继续使用上次保存的矩形；文件身份不匹配时保留列表与原有数据，但暂停旧导入叠层，避免套在替换后的 PDF 上。

## 接口与阅读器接入

- `zoteroapi.lua`：`fetchAttachmentAnnotations(key, progress_callback)` 返回完整快照或错误。读取 `/users/<id>/items/<key>/children?itemType=annotation`，复用分页、元数据连接重试和服务器退避；所有分页必须有相同 `Last-Modified-Version`。随后读取附件元数据，确认对应文件身份。附件版本晚于批注快照时重新读取，最多三轮。独立读取不推进主库游标。
- `annotations.lua`：快照校验、独立缓存、批注变化判断、文件身份核对、位置/颜色/日期转换、来源归属与当前文档实例适配。
- `main.lua`：编排主库同步与批注缓存更新，提供长按附件的单文件强制更新。在插件初始化、`DocSettingsLoad` 与 `ReadSettings` 独立识别受管 PDF，关闭设置及当前高亮模块的 `highlight_write_into_pdf`，在 native `ReadSettings` 完成旧格式批注迁移后合并导入项。内置插件消耗 `DocSettingsLoad` 事件也不影响导入；阅读中不直接改写 sidecar。识别路径通过 `ffi/util.realpath` 规范化，避免 Kindle 的相对数据目录 `.` 与最近阅读/文件管理器的绝对文件路径不匹配。
- `localfiles.lua`：确认目标仍对应同一附件路径，拒绝正在阅读的 PDF；先读取 KOReader 设置以定位集中或 hash 存储的 sidecar，成功删除 PDF 后才清理批注与缓存，并更新 KOReader 书籍信息、最近阅读和本地收藏。PDF 删除失败保留原数据；部分清理失败显示具体错误。只删除已确认文件和缓存，不递归清空附件目录，不发起网络请求。
- 阅读器适配只作用于当前文档和模块实例：使用缓存矩形、按 Zotero 排序字段排序、按来源 key 匹配条目；补齐多页高亮的实际点击索引，保留扩展高亮替换过程中的来源标记。相同页内书签排在高亮之前，Zotero 高亮按源排序排在本地高亮之前，本地高亮间使用 native 顺序。
- `progressdialog.lua`：批注获取、文件核对、重试和保存阶段；同步完成摘要报告已缓存/未变化/失败的 PDF 数量、跳过的不支持类型及部分失败原因。新增界面文案支持简体中文。

既有 `syncAllItems`、`downloadAndGetPath` 返回契约保持。新增批注请求均为 GET，没有增加网络写入；原有主库同步与附件下载仍使用 GET/HEAD。独立的 WebDAV 连接检查沿用只读 PROPFIND，不参与批注同步。

依据：[Zotero Web API v3](https://www.zotero.org/support/dev/web_api/v3/basics)、[KOReader v2026.03 加载事件顺序](https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/readerui.lua#L457-L461)、[ReaderAnnotation](https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/modules/readerannotation.lua)、[ReaderView](https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/modules/readerview.lua)、[ReaderHighlight](https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/modules/readerhighlight.lua)、[DocSettings](https://github.com/koreader/koreader/blob/v2026.03/frontend/docsettings.lua)。

## 验证记录（2026-10-08）

| 层级 | 环境与结果 | 能证明的范围 |
| --- | --- | --- |
| 原有基线 | 开始实施前离线套件 93/93 | 主库、附件下载、浏览及旧缓存回归基线 |
| 完整离线回归 | Lua 5.1.1 / Lua 5.4（Pandoc 3.12），135/135 | 原有功能及新增缓存、同步、转换、归属、错误保护流程 |
| KOReader 源码接口检查 | 官方 v2026.03 的实际 ReaderAnnotation、ReaderView、ReaderHighlight、Geometry、optmath 模块；Lua 5.1.1 / Lua 5.4，20 项通过 | native 迁移、排序、绘制调用路径、缩放/可见区/偏移、点击索引、扩展来源标记、重排抑制、SaveSettings |
| 真实 JSON 检查 | Pandoc JSON codec，11 项通过 | Unicode/引号/换行、嵌套位置 JSON、浮点整数账号 ID、空数组及对象响应拒绝、缓存往返 |
| Oasis 3 真机 | 2026-10-09 用户报告：除批注更新流程外，其他原清单项目均正常 | 属于用户验收反馈；本代理未操作设备，没有记录具体 MD5 值；本次修复与区域支持需复验 |

完整回归覆盖：首次补取、旧精简主库、分页版本变化/部分分页、账号校验、重试与退避、重复同步、云端新增/修改/删除最后一条、空快照、部分附件失败、损坏缓存、原子写入失败、库版本回退、文件身份变化、本地数据保护、失败后的重试、混合页尺寸、多矩形/OCR 坐标、下划线与颜色、UTC 时区、跨两页高亮、插件与离线加载事件。

离线套件的 HTTP、KOReader、JSON、crypto 使用替身，磁盘操作与 unzip 为真实操作。源码接口检查运行实际 KOReader Lua 模块，但 PDF 页几何、绘制底层与硬件仍是替身；没有执行 MuPDF、LuaJIT/TLS 或真实 PDF 像素验证。JSON 检查使用真实解析器，但仍不发起真实网络请求。本次没有使用真实账号同步云端批注。这三层检查不能替代真机验收。

复现：

```sh
lua tests/run.lua
# 或 luajit tests/run.lua / pandoc lua tests/run.lua
pandoc lua tests/json-integration.lua

# 已有官方 v2026.03 checkout 时：
pandoc lua tests/koreader-integration.lua /path/to/koreader/frontend
# 也可用 lua / luajit 运行该源码检查
```

## 2026-10-09 更新与复验

用户澄清：此前“批注不更新”的操作是在云端添加批注后直接重开 PDF，未执行 Synchronize；该行为符合离线重开的约定，因此未改成重开自动联网。单文件更新入口补入附件长按信息页。

同时修复了独立问题：原先仅比较路径字符串，插件 Browse 使用相对路径时，最近阅读/文件管理器的绝对路径可能无法识别为受管 PDF。改为核对规范化后的存储目录与文件路径，仍要求账号目录、附件 key、预期文件全部匹配，不接管目录外的同名 PDF。

新增区域批注的边框、原图内点击与评论查看，并保持主 PDF 不写入、无评论可查看、重排抑制和来源归属约束。未实现独立裁剪图预览。

更新验证：离线回归 **142/142**（Lua 5.1.1 / Lua 5.4）；KOReader v2026.03 实际 Lua 模块接口检查 **24 项**（两种 Lua），包括区域绘制路径、区域内部点击和评论窗口；真实 JSON 检查 **11 项**。新检查同样使用几何/绘制底层/HTTP 替身，不能替代本次新功能的真机复验。

## 2026-10-09 本地文件删除验证

完整离线回归 **151/151**（Lua 5.1.5 / Lua 5.4），覆盖确认与取消、PDF 删除失败保留批注、正在阅读时拒绝删除、附件路径变化、旧文件与其他附件保护、部分清理失败、删除后重新下载及批量批注同步跳过未下载文件。真实 JSON 检查仍为 **11 项通过**。

使用官方 KOReader v2026.03 实际 `DocSettings:open/purge`，两种 Lua 下各 **57 项通过**：真实临时文件覆盖文档旁、集中目录及 hash 存储、旧格式与备份、封面/自定义元数据和页面缓存的清理；hash 目录在 PDF 删除前定位。摘要计算、目录枚举、UI、历史与收藏使用替身，未执行真机输入或硬件验证。

复现：`pandoc lua tests/localfiles-integration.lua /path/to/koreader/frontend/docsettings.lua`，也可使用 Lua / LuaJIT。

## 2026-10-09：v2026.07.2 加载事件兼容修复

用户连接 Kindle 后，只读检查确认设备已从 v2026.03 升级到 v2026.07.2。两篇新 PDF 的云端快照已保存，但 sidecar 的 `annotations` 为空；旧两篇的区域项仍在快照及 sidecar 中。文件 MD5 均匹配下载收据和批注缓存，四篇所有支持类型的位置均在实际 PDF 页框内。

根因是内置 `docsettingtweak` 的 `onDocSettingsLoad` 在新版返回 `true`，KOReader 会停止向后续插件传播此事件。插件此前只有在该事件中设置批注所属附件 key，导致后续 `ReadSettings` 直接退出：新 PDF 未导入，旧高亮依靠 native 显示，`zotero_region` 缺少绘制适配而不显示边框。v2026.03 的对应处理器不消耗该事件。

修复在插件初始化和 `ReadSettings` 独立识别当前受管 PDF；后者同时关闭设置及当前高亮模块的 PDF 写入开关，再执行既有导入。保留 `DocSettingsLoad` 接口，支持事件正常到达或提前被消耗的两条路径。日志增加实际应用条数/跳过条数或导入错误，不记录批注正文与账号凭据。

| 用户报告的 PDF | 缓存 | 支持的导入项 | 区域项 |
| --- | --- | --- | --- |
| Analysis and Biophysics of Surface EMG… | 130 | 129（127 高亮 + 2 区域；另 1 个 `text` 便笺暂不支持） | 2 |
| 脑损伤上肢康复机器人及其临床应用研究 | 1 | 1 高亮 | 0 |
| A somato-cognitive action network… | 38 | 34 高亮 + 4 区域 | 4 |
| Next-Generation Neurotechnologies… | 52 | 49 高亮 + 3 区域 | 3 |

验证：Lua 5.1.5 / Lua 5.4 完整回归各 **153/153**；v2026.03 官方源码与 Kindle 当前 v2026.07.2 源码各 **26 项阅读器检查**，两种 Lua 均通过。新增检查实际运行内置设置插件与 Widget/EventListener 的事件传播；旧代码在该路径不能合并云端项，修复后成功。v2026.07.2 原生 DocSettings 删除检查各 **57 项通过**；真实 JSON 检查 **11 项通过**。

使用四份设备上的真实 JSON 快照、实际 PDF 页尺寸和下载收据，全部成功转换为表中条目；没有修改 PDF、快照或 sidecar。上述检查不等同于 MuPDF/电子墨水屏绘制验证，USB 连接期间未运行 Kindle 阅读器，修复后的真机显示待重启、重开验收。

## Oasis 3 验收清单

以下勾选项根据用户在 2026-10-09 的“其他部分均测试正常”反馈更新，代表用户验收结果，不代表本代理已操作设备。批注同步后的更新/删除仍待实际操作验证；本次新增或修复的项目另外列在末尾。

- [x] 在普通 PDF 中准备多行、多栏、OCR 矩形、高亮、下划线、空/非空评论与颜色；包含混合页尺寸和跨两页高亮。
- [x] 从插件首次打开，确认文字、评论、色彩映射、批注列表及点击目标；PDF MD5 与下载校验后的值相同。
- [x] 在 KOReader 中缩放、裁边、横竖屏切换，检查实际叠层位置与点击落点。
- [x] 关闭网络，从已经通过插件打开过的受管 PDF 经各入口重开，显示一致且不请求网络；首次从其他入口打开另见复验项。
- [x] 本地创建高亮、书签并推进阅读进度；编辑/扩展/删除 Zotero 导入项后重开，确认云端项恢复、本地项与进度保持。
- [ ] 阅读中在云端新增/修改批注并执行 Synchronize，确认当前页不被替换，重开后更新；记录失败/断网时旧结果保留。
- [ ] 删除云端最后一条批注后同步、重开，只移除所属导入项。
- [x] 切换重排，确认叠层暂停、列表可查，返回原版页面后恢复。
- [x] 更换云端 PDF，验证旧文件不应用新批注，匹配文件下载后按新尺寸转换；导入操作前后 PDF MD5 不变。
- [x] 核对既有主库同步、PDF/EPUB 与 WebDAV 下载、浏览、书签和进度回归，并记录电子墨水屏刷新表现。
- [ ] 已同步但未从 Browse 打开过该 PDF 时，从最近阅读/文件管理器首次打开，确认直接应用缓存；已显示后同步增改，再从各入口重开也更新。
- [ ] 长按已下载 PDF → 更新批注，确认只刷新该 PDF；更新后重开显示新结果，断网失败保留旧缓存；未下载 PDF 的按钮禁用。
- [ ] 区域批注显示空心矩形，原图保持可见；点击区域内部能查看对应评论，空评论有提示；缩放、裁边、横竖屏与重排切换正常。
- [ ] 长按 PDF → 删除本地文件，取消时保留数据；确认后 PDF、批注及阅读记录被清理，云端与其他附件保持，条目可重新下载；正在阅读时提示先关闭。
- [ ] 更新插件后在 v2026.07.2 重开上述四篇：两篇新 PDF 的列表和高亮可见，旧两篇分别恢复 4 个 / 3 个区域批注；无需重新下载或同步。
