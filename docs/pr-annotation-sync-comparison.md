# 原仓库批注同步 PR 比较与评估

核对日期：2026-10-08（Asia/Shanghai）。结论：**#40 是目前最值得参考的实现，但尚不能作为可靠双向同步直接合并；#23、#24、#31、#40 是同一批代码的演进，不是四套独立同步方案。** 当前项目宜保留已有元数据同步、下载校验和大库缓存方案，单独增加批注同步模块。

本次查看了原仓库全部 9 个 PR 的元数据，阅读了与批注相关的 4 个 PR 的实际补丁、固定提交源码和全部 PR 评论，并检查另外 3 个开放 PR 的补丁。对批注关键路径调用原函数进行了离线模拟。没有使用用户凭据，没有写入真实 Zotero，也没有改动插件业务代码。

**范围与固定版本**

| PR | 作者 / 状态 | 固定 head | 与批注的关系 |
|---|---|---|---|
| [#23 Stelzch dev](https://github.com/stelzch/zotero.koplugin/pull/23) | jarlt；已关闭、未合并 | `4b639c7d6fb411baee8368b01ae727bdd0085750` | 当前 PR head 已含 KOReader 新增批注上传；开 PR 时的描述主要是 HTTPS、清理 ZIP，不能只按描述判断 |
| [#24 Sqlite](https://github.com/stelzch/zotero.koplugin/pull/24) | jarlt；已关闭、未合并 | `c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a` | 增加批注关系表、云端批注导入与远端更新 |
| [#31 Enabling 2-way annotation sync and other enhancements](https://github.com/stelzch/zotero.koplugin/pull/31) | juandiegon；开放、未合并 | `2122efc8226356b4ac1119573099278baf8fd0df` | 继承 jarlt 实现，加入本地删除上传、网络管理、PDF 写入设置、失败汇总，移除 SQLite JSON 依赖 |
| [#40 2 way annotation sync, tag and author browsing of library](https://github.com/stelzch/zotero.koplugin/pull/40) | jarlt；开放、未合并 | `54ca41f47e23ef5ad7378e3741943d6f380b2491` | 继承 juandiegon 改动，修复部分崩溃和离线打开，扩展作者、标签、笔记浏览 |

#23、#24 都在 2026-05-03 关闭；#40 在 2026-05-04 创建。#31 与 #40 当前均被 GitHub 标为不可直接合并。状态与 head 是本次 API 查询的快照，不等于作者对功能完成度的承诺。

另外：[#28](https://github.com/stelzch/zotero.koplugin/pull/28) 主要是 HTML 附件支持，[#30](https://github.com/stelzch/zotero.koplugin/pull/30) 是标题空值回退，[#38](https://github.com/stelzch/zotero.koplugin/pull/38) 是 `imported_url` 附件支持；它们不提供新的批注同步机制。已合并的 [#1](https://github.com/stelzch/zotero.koplugin/pull/1) 和 [#4](https://github.com/stelzch/zotero.koplugin/pull/4) 分别处理无集合资料库及菜单尺寸，也不涉及批注实现。当前分支已经支持 `imported_url` 和标题回退；HTML 支持是另一个可单独决定的范围。

**功能矩阵**

这里的“实现”表示存在可执行路径，不代表相关边界已经可靠。

| 能力 | #23 | #24 | #31 | #40 |
|---|---|---|---|---|
| KOReader 新增 PDF 高亮 / 下划线上传 | 实现 | 实现 | 实现 | 实现 |
| Zotero 批注导入 KOReader | 未实现 | 实现 | 实现 | 实现 |
| Zotero 修改已有批注后更新 KOReader | 未实现 | 按远端版本替换 | 按远端版本替换 | 同 #31 |
| KOReader 修改已上传批注 / 评论后回传 | 未实现 | 未实现 | 未实现 | 未实现 |
| KOReader 删除回传 Zotero | 未实现 | 未实现 | 实现，但可能误删 | 同 #31 |
| Zotero 删除后移除本地批注 | 未实现 | 部分实现、有残留 | 部分实现、有残留 | 同 #31 |
| 两端同时编辑的冲突合并 | 未实现 | 有未接入的实验函数，上传修改仍是空实现 | 未实现 | 未实现 |
| EPUB / 区域图片 / 独立便签 / 手绘批注 | 没有对应实现 | 没有对应实现 | 没有对应实现 | 没有对应实现 |
| 自动同步、同步前强制保存当前阅读文档 | 没有完整实现 | 没有完整实现 | 没有完整实现 | 没有完整实现 |
| 页面尺寸转换 | 上传逐页读取 | 上传逐页；导入使用第一页高度 | 双向逐页高度，仍主要做 Y 轴翻转 | 与 #31 相同 |
| 有效的关键场景自动化测试 | 未见 | 未见 | 未见 | 新增 spec 仍只有恒真断言 |

来源：[#23 README](https://github.com/jarlt/zotero.koplugin/blob/4b639c7d6fb411baee8368b01ae727bdd0085750/README.md#L9-L23)、[#24 README](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/README.md#L9-L25)、[#31 README](https://github.com/juandiegon/zotero.koplugin/blob/2122efc8226356b4ac1119573099278baf8fd0df/README.md#L9-L23)、[#40 README](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/README.md#L9-L28)。

“评论可传递”和“评论修改可双向同步”应分别评估。新建批注可带评论，云端批注也可导入评论；但已有 `zoteroKey` 的本地批注会直接跳过上传。#40 的 Notes 功能是 Zotero 普通笔记的关联与浏览，不是新增便签批注类型或双向编辑笔记。[#40 上传过滤](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/annotations.lua#L533-L545)、[更新说明](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/Changelog.md#L3-L23)。

#24 的 `syncItemAnnotations` 虽然识别 `newerLocal`、`deletedLocal` 等状态，但实际下载路径调用的是另一个 `attachItemAnnotations`。实验函数本身强制设置 `action = "upload"`，该分支随后只输出未实现并保留本地修改，不能视为完成了冲突处理。[实验函数](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/zoteroapi.lua#L1667-L1815)、[实际下载调用](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/zoteroapi.lua#L1328-L1333)。

**#40 相比 #31 修复了什么**

#40 的改进是真实的，但集中在使用体验、空值和异常处理上。

| 项目 | #31 | #40 |
|---|---|---|
| 本地批注为空时同步 | 对 nil 做算术，崩溃 | 修复；跳过创建并返回零失败 |
| 元数据作者缺少 lastName | 会因拼接 nil 崩溃 | 加入空字符串回退，调用另有 pcall |
| 已缓存附件离线打开 | 浏览器路径要求在线 | 分开附件状态检查与下载，只在下载时要求联网 |
| SQLite JSON / JSONB 依赖 | 已移除活跃查询的依赖 | 延续该处理 |
| 作者、标签、My Publications、普通 Notes | 较少 | 新增索引和浏览入口 |
| 本地已上传批注的修改回传 | 不支持 | 仍不支持 |
| 未导入本地的云端批注被误删 | 可复现 | 仍可复现 |
| 51 条以上上传批次重叠 / 结果错位 | 可复现 | 仍可复现 |
| 连续写入使用旧库版本，收到 412 | 可复现 | 仍可复现 |
| 云端删除最后一条，本地仍保留 | 可复现 | 仍可复现 |
| 同一轮删除和更新导致重复 key | 可复现 | 仍可复现 |
| UTC → 本地 → UTC 往返偏差 | 可复现 | 仍可复现 |
| 无法取得 PDF 页尺寸 | 崩溃或失败 | 改成零失败，并错误推进 lastSync |

来源：[#40 Changelog](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/Changelog.md#L3-L23)、[空批注与页尺寸返回值](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/annotations.lua#L490-L530)、[同步调用方](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2275-L2287)、[离线打开路径](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/main.lua#L122-L158)、[作者空值处理](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2688-L2696)。

作者说 #40 处理了 #31 评论中的多数问题，不能据此推定已经修复并发丢失。#40 PR 当前没有评论可用于独立用户验证；新增 [spec](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/spec/zoteroapi_spec.lua#L21-L23) 只有恒真断言。

**关键缺陷的机制与离线证据**

1. **删除没有可靠基线，#31 与 #40 可能误删云端批注。**
   代码读取数据库中的 `version` 和 `syncedVersion`，但判定删除只看 key 是否缺席于 sidecar。模拟数据库中存在 `REMOTE01`、`syncedVersion=0`，sidecar 中只有新本地批注；两个版本都把 `REMOTE01` 送入 `deleteItems`。它从未成功导入本地，缺席并不代表用户删除。云端对象的版本未变时，DELETE 的版本前置条件也挡不住这种意图判断错误。
   一个实际可能的顺序是：同步把云端新批注放进数据库；用户从 Recents 继续读书而未从插件浏览器重新导入；sidecar 保存本地变化；下次同步误判删除。该顺序是基于代码的推断，不是一次真实设备复现。[#40 判定代码](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2204-L2249)。

2. **分批循环错误沿用四代。**
   `start_item` 按 0、50、100 计算，循环却直接从该值开始，下一批重复上一批最后一项。调用四个版本的原 `createItems`，模拟每批成功响应，51 条均产生两批 50、2 条；第二批 ID 是 50、51，返回结果却放入第 51、52 槽。该模拟刻意允许所有写入成功，以隔离分批及映射缺陷；真实服务还可能先因版本条件拒绝下一批。上一轮对 #31 的 100 条模拟得到第二批 51 条，超过官方每批 50 条上限。[#40 循环](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2330-L2374)、[官方批量及响应索引约定](https://www.zotero.org/support/dev/web_api/v3/write_requests#creating_multiple_objects)。

3. **写入版本与已下载快照版本没有正确分开。**
   #31、#40 使用正确的 `If-Unmodified-Since-Version`，但成功创建后不更新下一次写入的版本。模拟服务首笔写入从库版本 100 变为 101，第二笔仍带 100，两个版本都得到 200、412。旧 #23、#24 使用的是 `if-unmodified-since`，不是 Zotero 的版本请求头，因此也没有正确的版本保护。
   对当前项目，应把已成功下载的快照水位与本轮写请求所需版本分开维护，避免既出现连续写入 412，又因过早推进下载水位漏掉远端对象。[#40 写请求](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2339-L2370)、[#24 旧请求头](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/zoteroapi.lua#L1599-L1628)、[官方成功与 412 处理](https://www.zotero.org/support/dev/web_api/v3/syncing#iv_upload_modified_data)。

4. **最后一条远端删除没有传播到 sidecar。**
   #24、#31、#40 都将清理放在 `if zotCount > 0` 内。模拟云端列表为空、sidecar 中仍有一条旧批注；三个版本都保留它，并把 `zoteroLibVersion` 从 99 推到 100。下一次相同库版本下仍不会清理。[#24 分支](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/zoteroapi.lua#L1904-L1958)、[#40 分支](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2762-L2869)。

5. **删除与更新在同一轮进行时，数组位置失效。**
   #31、#40 先记住已有批注的数组位置，再移除其他批注，最后继续按旧位置更新。模拟第 1 条被云端删除、第 2 条被云端更新，最后两个数组项都拥有 `REMOTE01`，旧版本未被替换，出现重复。[#40 位置记录及删除](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2767-L2795)、[使用旧位置更新](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2838-L2843)。

6. **#40 把 PDF 页尺寸读取失败当作成功。**
   `getPageDimensions` 返回 nil 时，代码返回 `#z_annotations, nil`，但此时该数组还没有转换任何批注，长度是 0。模拟 sidecar 中确有待上传批注但页尺寸不可读，结果是零失败，并执行一次 `lastSync` 更新；下次 sidecar 不变就可能不再尝试。这是避免崩溃时引入的错误完成状态。[返回值](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/annotations.lua#L502-L530)、[推进时间](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/zoteroapi.lua#L2281-L2287)。

7. **逐页尺寸不等于完整坐标变换。**
   #24 导入用第一页的高度，混合页面尺寸不可靠。#31、#40 改为逐页高度；但主要算法仍是 `y = page_height - y - h`，读取的 BBox 原点并未参与实际变换，pos0/pos1 固定 rotation=0。旋转、不同 CropBox/MediaBox、特殊文字排列、OCR 和重排阅读需要以真实 PDF 验证。尚未通过几何测试证明这些场景必然出错，也不能保证它们已被支持。[#24 首页假设](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/zoteroapi.lua#L1647-L1664)、[#40 转换](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/annotations.lua#L343-L431)。

8. **时间、颜色、样式和排序不能无损往返。**
   #31、#40 下载时间时只把 UTC 字符串改成本地格式。在 Asia/Shanghai 模拟 `2026-10-08T12:00:00Z`，转换为 sidecar 后再转回 UTC，得到 `2026-10-08T04:00:00Z`。颜色映射也不是互逆：蓝色上传是 `#0066FF`，下载表识别的是 `#2ea8e5`；不认识的值会回退为黄色。strikeout/invert 降级成 highlight，排序的字符偏移固定为 0。对于“保留批注语义”的新实现，这些应保存原始值或明确显示降级。[#40 颜色表](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/annotations.lua#L9-L49)、[时间处理](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/annotations.lua#L441-L465)。

**社区反馈与验证边界**

#24 有用户报告 `jsonb` 不存在，导致同步无法完成；源码确实使用了 `jsonb(?2)`。这说明目标 KOReader 的 SQLite 构建是兼容条件，不能单凭桌面 SQLite 可运行判断可行。#31、#40 已移除这一活跃依赖。[#24 反馈](https://github.com/stelzch/zotero.koplugin/pull/24#issuecomment-3002307973)、[SQL 调用](https://github.com/jarlt/zotero.koplugin/blob/c3ebfdb1f8d60476ef0e95e45082cb40a8c0dd4a/zoteroapi.lua#L225-L227)。

#31 作者报告做过模拟器及 Kobo 测试，但没有测试 WebDAV。后续使用者报告过两端编辑丢失批注、需维护重扫描、OCR 批注偏移；作者确认 sidecar 未落盘和坐标不匹配问题。它们提供了实际使用证据，但不能逐次归因到同一个缺陷。[作者说明](https://github.com/stelzch/zotero.koplugin/pull/31)、[并发丢失反馈](https://github.com/stelzch/zotero.koplugin/pull/31#issuecomment-3920850821)、[sidecar 与坐标说明](https://github.com/stelzch/zotero.koplugin/pull/31#issuecomment-3393515357)。

本次离线探针使用 Pandoc 的 Lua 5.4 运行固定 head 源码，补了 KOReader LuaJIT 的 `table.getn` 兼容函数；用替身模拟 HTTP、DocSettings、SQLite 查询结果、文件 mtime 和 PDF 页尺寸。实际被调用的是 PR 原函数，不是重写后的同步算法。因此上述状态、返回值、分批和数组映射是代码级复现；真实 API 状态依据官方协议模拟。此验证不覆盖 SQLite 原生执行、LuaSocket/TLS、真实 PDF 几何、阅读器内存中尚未保存的数据、真机输入屏幕及 WebDAV 传输。临时源文件和探针在核对后清理。

**面向当前分支的取舍**

| 目标 | 建议参考 | 需要重新实现 |
|---|---|---|
| 单向导出 KOReader 新批注 | #23 的简单入口；以 #40 转换字段为主要参考 | 分批、身份映射、成功回执、重试去重 |
| 导入 Zotero PDF 高亮 / 下划线 | #40 的逐页读取、DocSettings 字段、样式映射 | 坐标验证、保留本地修改、空远端列表处理 |
| 完整双向修改与删除 | 没有可直接采用的完成实现 | 同步基线、dirty 状态、删除记录、三方合并、412 处理 |
| 离线打开与错误显示 | #40 的状态检查和下载分离、#31/#40 的失败统计 | 与当前校验下载及进度界面适配，禁止零失败掩盖跳过 |
| 作者 / 标签 / Notes 浏览 | #40 的浏览入口 | 独立考虑索引及必要元数据字段，避免随批注任务扩大范围 |

批注作为 Zotero annotation 子条目通过 Web API 同步，KOReader 端通过 sidecar 存储；这些实现没有上传改写后的 PDF 到 WebDAV。#31/#40 从插件浏览器打开 PDF 时，默认关闭 `highlight_write_into_pdf`。这是入口设置，不保证用户以其他方式打开文件时也始终关闭写入。[#40 设置](https://github.com/jarlt/zotero.koplugin/blob/54ca41f47e23ef5ad7378e3741943d6f380b2491/main.lua#L36-L48)。

当前项目的 `compact_object` 会过滤 annotation 正文、颜色、位置等字段。同步功能必须另设批注缓存，或为受支持批注保留专门投影；不能直接从当前精简的 `getItems()` 重建完整批注。更合适的是只为下载或打开的 PDF 保留完整批注，减少设备内存负担。[当前缓存投影](/Users/benzene/Projects/zotero.koplugin/zoteroapi.lua:74)。

建议实现顺序：

1. 保留现有资料库一致性检查、账号隔离、下载完整性和大库缓存；批注作为独立模块和独立状态加入。
2. 先实现 PDF 高亮/下划线新增与导入；为新本地批注持久化稳定 ID/远端 key，让服务器成功但回执未落盘的重试也不会产生重复。
3. 同步前保存当前阅读文档，并协调已打开文档的内存状态与 sidecar，避免插件写入后又被阅读器旧状态覆盖。
4. 为每条批注记录最近成功同步的基线、对象版本、明确的本地修改和删除状态。缺席不能直接推断删除。
5. 用“基线 / 本地 / 远端”比较处理修改；两端均改或修改与删除冲突时保留副本或交给用户选择。
6. 单独维护写请求版本与下载快照水位；遇到 412 拉取并合并后有限重试。批次最多 50 条，逐项处理 successful、unchanged、failed。
7. 完成多批次、多 PDF、空列表、部分失败、重试、并发新增、修改与删除冲突及真实 PDF 几何验证后，再开启双向删除。

**推荐决定：以 #40 作为转换与界面参考，以当前分支作为运行基础，重建批注同步状态机。** #23 可帮助缩小最初导出范围；#24 可提供历史设计线索；#31 的故障反馈适合作为回归场景。四个 PR 目前都不能提供完整可靠的双向同步。
