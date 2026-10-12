# Zotero KOReader 插件简体中文汉化方案与实施记录

> 基线版本：`HEAD 374bf8e`\
> 插件范围：`/Users/benzene/Projects/zotero.koplugin`\
> 报告性质：已审定的源码盘点、中文文案设计与实施记录。用户于 2026-10-10 批准实施，由 Codex 修改代码、AGY 协同审核。以下盘点计数与源行号对应实施前基线；最新落实与验证状态见第 14 节。

---

## 审定决策与补漏概况

本方案由 AGY 提出中文文案，再经 Codex 核对源码、讨论术语并补齐界面入口。审定建议如下：

1. **统计口径纠正**：更正静态计数口径。确认源码字面量 `_("...")` / `_([[...]])` 共 85 处；现有硬编码 `chinese` 回退表经精准统计为 `attachmentmenu.lua` 26 键、`annotations.lua` 35 键，两表互不重叠，独立键去重合计 61 键。这两个数字分别表示调用出现次数和现有译文键数量，不能直接相加当作待汉化总数。85 处调用还包含重复文案、通用按钮及用于识别 KOReader 原生菜单的比较。底层错误另按模板和路径列出。

2. **核心概念澄清与纠偏**：
   - **`All Items` 语义**：根据 `main.lua:277-280` 与 `zoteroapi.lua:1093-1107`，该视图仅遍历并显示可见 PDF/EPUB 附件，父书目仅用于提供分组和标签。按用户最新决定，入口与标题保留英文 `All Items`。
   - **空列表占位符区分**：英文 `No Items` 在附件子列表译为“暂无附件”，分类视图译为“暂无分类或可阅读附件”；`No Results` 在“All Items”的空查询视图译为“暂无可阅读附件”，关键词搜索时译为“未找到匹配的附件”。
   - **搜索说明优化**：订正为“按标题、作者信息或 DOI 搜索 PDF/EPUB 附件。”
   - **同步结果统计澄清**：`getLibrarySummary()` 统计的是全部 items（包含书目、附件、笔记、批注等），明确译为“文献库条目：%d”，绝非“文献数”；附件对应为“可阅读 PDF/EPUB 附件：%d”；`Fetching library items…` 订正为“正在获取文献库条目…”。
   - **用户确定的英文专有名称**：`All Items`、`Zotero Annotation` 与源码标签 `Zotero key` 在中文界面也保留英文；批注颜色等其他词仍汉化。
   - **Note/Comment 术语**：`No comment.` 译为“无评论。”；批注附属评论（Comment ➔ 评论）与独立笔记（Standalone Note ➔ 笔记）区分。`Zotero key` 的标签、大小写、标点和标识值保持源码原样。
   - **表单与提示去书面化**：统一全角中文标点与括号，去掉不必要的感叹号及“后方可”等生硬字眼（如“重启 KOReader 后生效。”、“WebDAV 连接正常。”）。
   - **本地删除文案与流程纯正性**：统一使用“本地”（不用本机/本地混用），修正删除确认与结果提示；不虚构代码未定义的弹窗标题与按钮。
   - **进度语义纠偏**：`Applying deletions…` 订正为“正在更新已删除条目…”，避免引发向云端删除数据的误解；`Retrying this page…` 订正为“连接中断，正在重新请求…”，消除与 PDF 页码的混淆；批注冲突订正为“批注有更新，正在重试…”。
   - **底层错误与嵌套模板补全**：全面覆盖插件自写错误提示及动态嵌套模板（如 `Fetching %s (page %d): %s`、`Checking Zotero account: %s`、`Fetching deletions: %s`、下载超时及字节数等），外部系统/unzip/socket 诊断保留为细节。

---

## 目录

1. [盘点口径与统计分类说明](#1-盘点口径与统计分类说明)

2. [术语定义与交互文案设计准则](#2-术语定义与交互文案设计准则)

3. [核心用户流程预期界面串联（5大场景）](#3-核心用户流程预期界面串联5大场景)

4. [全量可见文案清单（按功能区域分组）](#4-全量可见文案清单按功能区域分组)
   - [区域一：插件元数据与 Dispatcher 动作](#区域一插件元数据与-dispatcher-动作)
   - [区域二：顶层主菜单与维护/设置菜单](#区域二顶层主菜单与维护设置菜单)
   - [区域三：配置弹窗与输入校验提示](#区域三配置弹窗与输入校验提示)
   - [区域四：同步与批注抓取进度提示（ProgressDialog）](#区域四同步与批注抓取进度提示progressdialog)
   - [区域五：同步结果反馈与统计摘要](#区域五同步结果反馈与统计摘要)
   - [区域六：文献库浏览、分类层级与搜索界面](#区域六文献库浏览分类层级与搜索界面)
   - [区域七：附件列表、聚合条目与长按详情](#区域七附件列表聚合条目与长按详情)
   - [区域八：本地文件删除与保护拦截](#区域八本地文件删除与保护拦截)
   - [区域九：PDF 只读批注弹窗、颜色、菜单拦截与统计](#区域九pdf-只读批注弹窗颜色菜单拦截与统计)
   - [区域十：嵌套动态错误模板与上层网络/存储提示](#区域十嵌套动态错误模板与上层网络存储提示)

5. [附录：底层候选错误模板调用路径与可见性审查](#5-附录底层候选错误模板调用路径与可见性审查)

6. [非插件翻译数据边界（动态数据隔离）](#6-非插件翻译数据边界动态数据隔离)

7. [电子墨水屏文案长度与排版策略](#7-电子墨水屏文案长度与排版策略)

8. [文档分级策略：运行时 UI 与开发文档](#8-文档分级策略运行时-ui-与开发文档)

9. [技术实施架构建议与约束（供 Lead 审查）](#9-技术实施架构建议与约束供-lead-审查)

---

## 1. 盘点口径与统计分类说明

为确保统计真实可靠，统计区分调用出现次数、独立词典键和底层错误模板，避免混淆缺口数量：

1. **源码 gettext 字面量调用（`_("...")` / `_([[...]])`）**：共 **85** 处。
   - `main.lua`：48 处
   - `progressdialog.lua`：26 处
   - `annotationpolicy.lua`：9 处
   - `_meta.lua`：2 处

2. **源码既有私有中文回退表项（`chinese` 表）**：共 **61** 键（两表键集合无重叠）。
   - `attachmentmenu.lua`：26 键（含聚合状态、单附件状态、详情格式串、本地删除全套提示）
   - `annotations.lua`：35 键（含 10 种颜色名、批注状态、只读策略拦截、批注同步统计）

3. **底层模块抛出的候选错误模板（`zoteroapi.lua` / `annotations.lua` / `librarycache.lua`）**：
   - 包含通过 `error(...)` 或 `return nil, "..."` 构造的自写英文字符串。详见第 5 节附录审查清单（区分“用户可见”、“被上层特定逻辑忽略/吸收”、“内部开发断言”）。

---

## 2. 术语定义与交互文案设计准则

| 英文原词 | 选定简中术语 | 淘汰用词 | 选定理由与代码语义约束 |
| :--- | :--- | :--- | :--- |
| **Library** | **文献库** | 资料库、文库、图书馆 | 准确对应 Zotero 的文献集合整体概念。 |
| **Collection** | **分类** | 集合、收藏夹、文集 | 对应 Zotero 左侧层级目录（分类树），避免“集合”的技术生硬感。 |
| **Browse** | **浏览文献库** / **浏览** | 查看、浏览列表 | 顶层菜单使用“浏览文献库”，上下文明确处使用“浏览”。 |
| **Synchronize** | **同步** | 云同步、更新 | 保持与 Zotero 同步概念一致；单向同步的只读特性在正文和提示中消解。 |
| **Resync entire collection** | **重新同步整个文献库** | 重新同步整个集合、重新同步所有分类 | **代码事实**：`main.lua:458` 触发 `resetSyncState()`，置 `force_full_sync = true`，下次同步带 `since=0` 重新拉取整个 Library 的全部 items 和 collections。原英文 "collection" 实为误称，逻辑是重置整个文献库。 |
| **Library items (summary)** | **文献库条目** | 文献数、项目数 | **代码事实**：`getLibrarySummary()` 遍历所有 items，包含顶层书目、附件、笔记、批注等对象，不能译为“文献数”。 |
| **All Items (browser)** | **All Items（保留英文）** | 汉化入口标签 | 用户最新决定保留英文；此视图列出可阅读 PDF/EPUB 附件，按父条目分组。 |
| **Attachment** | **附件** | 附录、从属项 | 特指挂载在条目下的 PDF/EPUB 文件。 |
| **Visible attachments** | **可阅读 PDF/EPUB 附件** | 可见附件 | 准确说明过滤规则（仅保留受支持的 PDF 与 EPUB）。 |
| **Downloaded** | **已下载** | 已缓存、本地存在 | 状态明确。 |
| **Not downloaded** | **未下载** | 未缓存、云端 | 状态明确。 |
| **Update available** | **待更新** | 有新版本、可用更新 | 本地已下载但云端元数据或 MD5 不匹配。 |
| **Refresh annotations** | **更新批注** | 刷新批注、同步批注 | 强调从云端获取最新批注，规避“上传”歧义。 |
| **Zotero annotations are read-only** | **Zotero 批注只读** | 批注无法修改 | 明确导入自 Zotero 的批注在 KOReader 中只读；可在 Zotero 中编辑。 |
| **Comment** | **评论** | 笔记、附注 | 特指高亮/批注所附带的评论（Comment），区别于独立笔记（Note）。 |
| **Note (standalone)** | **笔记** | 评论、便签 | 独立笔记条目统一使用“笔记”。 |
| **Zotero key** | **Zotero key**（保留英文） | 汉化标签 | 用户明确要求作为专有名称保留；源码当前为小写 key，标识值也原样显示。 |
| **Delete local file** | **删除本地文件** | 移除文件、清除缓存 | 统一使用“本地”（淘汰“本机”混用），强调云端数据保留。 |

---

## 3. 核心用户流程预期界面串联（5大场景）

### 场景 1：首次配置与初次同步

1. **主菜单**：用户点按顶层菜单 `Zotero` → 展开子项：`浏览文献库`、`同步`、`维护`、`设置`。

2. **设置账户**：点按 `设置` → `配置 Zotero 账户`。
   - 弹窗标题：`Zotero 账户设置`
   - 字段 1 占位提示：`用户 ID（数字）`
   - 字段 2 占位提示：`API 密钥`
   - 按钮：`[ 取消 ]` `[ 保存 ]`
   - （若输入非数字 ID）警告浮层：`用户 ID 必须为纯数字。`

3. **WebDAV 设置（可选）**：点按 `设置` → `启用 WebDAV 存储`（勾选）；点按 `配置 WebDAV 账户`。
   - 弹窗标题：`WebDAV 账户设置`
   - 字段：`WebDAV 地址`、`用户名`、`密码`
   - 点按 `测试 WebDAV 连接` → 成功浮层：`WebDAV 连接正常。`

4. **发起初次同步**：点按 `Zotero` → `同步`。
   - 进度弹窗标题：`正在同步 Zotero 文献库`
   - 阶段动态提示：
     - `正在检查 Zotero 账户…`
     - `正在获取文献库条目…`
       `已处理：100 / 450（22%）`
     - `正在获取分类…`
       `已处理：12`
     - `正在更新已删除条目…`（后续增量同步时才可能显示）
     - `正在保存文献库…`
     - 已下载 PDF 时，还会显示 `正在同步已下载 PDF 的批注` 与处理数量。
   - 同步结果浮层（InfoMessage，无虚构标题/确认按钮）：
     ```text
     同步完成。
     文献库条目：450
     分类：12
     可阅读 PDF/EPUB 附件：380
     PDF 批注已缓存：0；未变化：0；失败：0
     缓存批注将在下次打开 PDF 时生效。
     ```

### 场景 2：浏览分类、多附件展开并下载打开

1. **进入浏览**：点按 `Zotero` → `浏览文献库`。
   - 全屏菜单顶部标题：`Zotero`
   - 列表首项：`All Items`
   - 后续项：`计算机科学/`、`深度学习/`（分类项带有 `/`）。

2. **进入子分类**：点按 `深度学习/`。
   - 顶部标题更新为：`深度学习`
   - 多附件条目展示：`Vaswani et al. - Attention Is All You Need`，右侧状态：`2 个附件 · 已下载 1`。

3. **展开多附件子列表**：点按该条目。
   - 顶部标题更新为：`附件`
   - 列表项：
     - `1. 正文 — attention.pdf · PDF · 已下载`
     - `2. 补充材料 — supp.pdf · PDF`

4. **下载打开**：点按未下载的 `2. 补充材料 — supp.pdf`。
   - 进度弹窗标题：`正在下载附件`
   - 阶段提示：`正在下载文件…`（下方动态显示 `已接收：2.4 MiB`）➔ `正在校验下载文件…`（`已校验：2.4 MiB`）➔ `正在获取 PDF 批注…` ➔ 自动唤起阅读器打开。

### 场景 3：阅读器中查看云端批注与只读拦截

1. **查看云端高亮与评论**：
   - 用户在阅读器中点按黄色高亮。
   - 弹窗标题：`Zotero Annotation · 黄`（英文环境仍为 `Zotero Annotation · Yellow`）
   - 正文滚动显示高亮选中文本与评论（若无评论则正文末尾显示 `无评论。`）。
   - 底部按钮：`[ ◀ ] [ ▶ ] [ 转到批注 ] [ … ] [ 关闭 ]`；当前页点按批注时不显示“转到批注”，前后导航根据可用条目启用。

2. **拦截修改尝试**：
   - 用户点按修改高亮样式或删除按钮。
   - 提示浮层：`请在 Zotero 中修改此批注，然后同步并重新打开 PDF。`

3. **原生菜单拦截**：
   - 阅读器主菜单中的“将所有高亮写入 PDF 原文件”被置灰，文案变更为：`Zotero PDF 原文件已保护`。
   - 原生写入或导入动作被拦截时提示：`此 Zotero PDF 原文件已保护。本地批注保存于 KOReader 文档设置。`；已禁用的菜单项不承诺可以点按。

4. **批量样式应用**：
   - 点按“将当前样式和颜色应用于所有高亮”➔ 确认框：`将当前样式和颜色应用于本地高亮？Zotero 批注保持只读。`
   - 确认后浮层反馈：`已修改本地批注：2；已跳过只读 Zotero 批注：8`。

### 场景 4：在桌面端修改批注后在 KOReader 单篇更新

1. **呼出详情**：在浏览器长按已下载的条目。
   - 弹窗标题：`附件信息`
   - 正文内容：
     ```text
     文献：Attention Is All You Need
     附件：attention.pdf
     文件名：attention.pdf
     格式：PDF
     状态：已下载
     本地大小：2150.4 KiB
     文件修改时间：2026-10-09 14:30
     DOI: 10.48550/arXiv.1706.03762

     Zotero key: ABC12345
     ```
   - 底部按钮：`[ 打开 ]` `[ 更新批注 ]` `[ 删除本地文件 ]` `[ 关闭 ]`

2. **更新批注**：点按 `更新批注`。
   - 进度弹窗标题：`正在更新 PDF 批注` ➔ 阶段 `正在获取 PDF 批注…` ➔ `正在核对批注对应的文件…` ➔ `正在保存 PDF 批注…`。
   - 完成浮层：
     ```text
     PDF 批注已更新。
     缓存批注将在下次打开 PDF 时生效。
     ```

### 场景 5：本地空间不足，安全删除本地 PDF

1. **触发删除**：在附件信息弹窗中点按 `删除本地文件`。

2. **确认对话框**：
   - 确认提示（无自定义窗口标题）：
     ```text
     删除本地 PDF 及其批注、书签和阅读进度？Zotero 云端数据会保留，可重新下载。

     attention.pdf
     ```
   - 操作按钮：`[ 取消 ]` `[ 删除本地文件 ]`

3. **占用检查**：若文档当前正在阅读器中打开，则阻止并提示：`请先关闭此 PDF，再删除本地文件。`

4. **成功结果**：浮层提示 `已删除本地 PDF 及其批注、书签和阅读进度。` 列表项状态标签清空。

---

## 4. 全量可见文案清单（按功能区域分组）

### 区域一：插件元数据与 Dispatcher 动作

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 1.1 | `Zotero` | `Zotero` | `_meta.lua:4,5` | 专有名词保留 |
| 1.2 | `Quick access to all PDFs of your Zotero library.` | `浏览 Zotero 文献库，下载并阅读 PDF/EPUB 附件。` | `_meta.lua:6` | 准确反映插件对 PDF/EPUB 附件的完整支持 |
| 1.3 | `Zotero Open` | `打开 Zotero` | `main.lua:322` | Dispatcher 手势/按键动作名称 |
| 1.4 | `Zotero Sync` | `同步 Zotero` | `main.lua:328` | Dispatcher 手势/按键动作名称 |

### 区域二：顶层主菜单与维护/设置菜单

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 2.1 | `Zotero` | `Zotero` | `main.lua:435` | 顶层菜单入口 |
| 2.2 | `Browse` | `浏览文献库` | `main.lua:439` | 进入文献库树状目录 |
| 2.3 | `Synchronize` | `同步` | `main.lua:445` | 发起全库增量同步与批注抓取 |
| 2.4 | `Maintenance` | `维护` | `main.lua:452` | 二级菜单标题 |
| 2.5 | `Resync entire collection` | `重新同步整个文献库` | `main.lua:458` | **代码事实**：底层重置全库并做全量同步（`force_full_sync`） |
| 2.6 | `Refetch downloaded PDF annotations` | `重新获取已下载 PDF 的批注` | `main.lua:466` | 强制重新拉取全部已下载 PDF 的批注快照 |
| 2.7 | `Settings` | `设置` | `main.lua:472` | 二级设置菜单标题 |
| 2.8 | `Configure Zotero account` | `配置 Zotero 账户` | `main.lua:478` | 打开 Zotero 账户设置 |
| 2.9 | `Enable WebDAV storage` | `启用 WebDAV 存储` | `main.lua:484` | 勾选项 |
| 2.10 | `Configure WebDAV account` | `配置 WebDAV 账户` | `main.lua:494` | 打开 WebDAV 账户设置 |
| 2.11 | `Check WebDAV connection` | `测试 WebDAV 连接` | `main.lua:500` | 触发连通性检测 |
| 2.12 | `Items per page` | `每页条目数` | `main.lua:518` | 分页设置项 |

### 区域三：配置弹窗与输入校验提示

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 3.1 | `Edit User Info` | `Zotero 账户设置` | `main.lua:533` | 弹窗标题更明确自然 |
| 3.2 | `User ID (integer)` | `用户 ID（数字）` | `main.lua:537` | 简短自然，统一全角括号 |
| 3.3 | `API Key` | `API 密钥` | `main.lua:541` | 标准术语 |
| 3.4 | `Cancel` | `取消` | `main.lua:82, 547, 607` | 通用取消按钮 |
| 3.5 | `Update` | `保存` | `main.lua:555, 615` | 表单提交按钮使用“保存”更符合表单心智 |
| 3.6 | `The User ID must be an integer number.` | `用户 ID 必须为纯数字。` | `main.lua:561` | 校验错误浮层 |
| 3.7 | `Edit WebDAV credentials` | `WebDAV 账户设置` | `main.lua:589` | 弹窗标题更明确自然 |
| 3.8 | `URL` | `WebDAV 地址` | `main.lua:593` | 避免单字英文 URL，指代更清晰 |
| 3.9 | `Username` | `用户名` | `main.lua:597` | 表单提示 |
| 3.10 | `Password` | `密码` | `main.lua:601` | 表单提示 |
| 3.11 | `Success, WebDAV works!` | `WebDAV 连接正常。` | `main.lua:506` | 去掉感叹号，平实陈述 |
| 3.12 | `WebDAV could not connect: ` | `WebDAV 无法连接：` | `main.lua:508` | 拼接底层原因 |
| 3.13 | `Set items per page` | `设置每页条目数` | `main.lua:638` | SpinWidget 标题 |
| 3.14 | `This change requires a restart of KOReader to take effect.` | `重启 KOReader 后生效。` | `main.lua:646` | 去掉冗余书面语，紧凑直白 |

### 区域四：同步与批注抓取进度提示（ProgressDialog）

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 4.1 | `Synchronizing Zotero library` | `正在同步 Zotero 文献库` | `progressdialog.lua:52` | 进度弹窗标题 |
| 4.2 | `Refreshing PDF annotations` | `正在更新 PDF 批注` | `progressdialog.lua:53` | 批注同步弹窗标题 |
| 4.3 | `Downloading attachment` | `正在下载附件` | `progressdialog.lua:53` | 附件下载弹窗标题 |
| 4.4 | `Checking local file…` | `正在检查本地文件…` | `progressdialog.lua:11` | 阶段提示 |
| 4.5 | `Opening local file…` | `正在打开本地文件…` | `progressdialog.lua:12` | 阶段提示 |
| 4.6 | `Downloading file…` | `正在下载文件…` | `progressdialog.lua:13` | 阶段提示 |
| 4.7 | `Download interrupted. Resuming…` | `下载中断，正在恢复传输…` | `progressdialog.lua:14` | 阶段提示 |
| 4.8 | `Connection interrupted. Retrying this page…` | `连接中断，正在重新请求…` | `progressdialog.lua:15` | **代码事实**：page 指 API 分页，避免与 PDF 页码混淆 |
| 4.9 | `Invalid downloaded archive. Downloading again…` | `下载的压缩包损坏，正在重新下载…` | `progressdialog.lua:16` | WebDAV ZIP 损坏自动重试 |
| 4.10 | `Extracting attachment…` | `正在解压附件…` | `progressdialog.lua:17` | 阶段提示 |
| 4.11 | `Checking downloaded file…` | `正在校验下载文件…` | `progressdialog.lua:18` | 阶段提示 |
| 4.12 | `Saving file…` | `正在保存文件…` | `progressdialog.lua:19` | 阶段提示 |
| 4.13 | `Checking Zotero account…` | `正在检查 Zotero 账户…` | `progressdialog.lua:20` | 阶段提示 |
| 4.14 | `Fetching library items…` | `正在获取文献库条目…` | `progressdialog.lua:21` | **代码事实**：条目包含多种对象，使用“文献库条目” |
| 4.15 | `Fetching collections…` | `正在获取分类…` | `progressdialog.lua:22` | 阶段提示 |
| 4.16 | `Applying deletions…` | `正在更新已删除条目…` | `progressdialog.lua:23` | 说明仅应用到本地缓存，避免“应用云端删除”误解 |
| 4.17 | `Saving library…` | `正在保存文献库…` | `progressdialog.lua:24` | 阶段提示 |
| 4.18 | `Library changed. Restarting synchronization…` | `文献库有变动，正在重新同步…` | `progressdialog.lua:25` | 阶段提示 |
| 4.19 | `Library is up to date.` | `文献库已是最新。` | `progressdialog.lua:26` | 304 未修改提示 |
| 4.20 | `Complete.` | `已完成。` | `progressdialog.lua:27` | 阶段提示 |
| 4.21 | `Fetching PDF annotations…` | `正在获取 PDF 批注…` | `progressdialog.lua:28` | 阶段提示 |
| 4.22 | `Synchronizing downloaded PDF annotations` | `正在同步已下载 PDF 的批注` | `progressdialog.lua:29` | 阶段提示 |
| 4.23 | `Checking annotation file…` | `正在核对批注对应的文件…` | `progressdialog.lua:30` | 阶段提示 |
| 4.24 | `Saving PDF annotations…` | `正在保存 PDF 批注…` | `progressdialog.lua:31` | 阶段提示 |
| 4.25 | `Annotations changed. Retrying…` | `批注有更新，正在重试…` | `progressdialog.lua:32` | 比“批注已变化”更自然贴切 |
| 4.26 | `Preparing…` | `正在准备…` | `progressdialog.lua:72` | 默认未识别阶段 |
| 4.27 | `Waiting for response…` | `正在等待响应…` | `progressdialog.lua:56, 85` | 网络等待提示 |
| 4.28 | `Processed: %d / %d (%d%%)` | `已处理：%d / %d（%d%%）` | `progressdialog.lua:75` | 统一全角中文标点与括号 |
| 4.29 | `Processed: %d` | `已处理：%d` | `progressdialog.lua:78` | 统一全角中文冒号 |
| 4.30 | `Received: %s` | `已接收：%s` | `progressdialog.lua:82` | 统一全角中文冒号 |
| 4.31 | `Checked: %s` | `已校验：%s` | `progressdialog.lua:82` | 统一全角中文冒号 |

### 区域五：同步结果反馈与统计摘要

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 5.1 | `Synchronization complete.` | `同步完成。` | `main.lua:708` | 成功首行 |
| 5.2 | `Library items: %d\nCollections: %d\nVisible PDF/EPUB attachments: %d` | `文献库条目：%d\n分类：%d\n可阅读 PDF/EPUB 附件：%d` | `main.lua:709` | 实际显示为三行，保留换行和三个整数占位符 |
| 5.3 | `PDF annotations cached: %d; unchanged: %d; failed: %d` | `PDF 批注已缓存：%d；未变化：%d；失败：%d` | `annotations.lua:264` | 批注统计 |
| 5.4 | `Unsupported annotations skipped: %d` | `已跳过不支持的批注：%d` | `annotations.lua:266` | 批注统计 |
| 5.5 | `Cached annotations take effect when the PDF is next opened.` | `缓存批注将在下次打开 PDF 时生效。` | `annotations.lua:267` | 引导重新打开文档 |
| 5.6 | `Synchronization failed.` | `同步失败。` | `main.lua:717` | 失败首行，后拼详细错误 |
| 5.7 | `… (%d)` | `……（共 %d 条错误）` | `annotations.lua:269` | 错误超过五条时追加；`%d` 为总错误数，不能译成“还有 %d 条” |

### 区域六：文献库浏览、分类层级与搜索界面

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 6.1 | `All Items` | `All Items`（保留英文） | `main.lua:277, 293` | **代码事实**：实为全部可见附件平铺列表 |
| 6.2 | `No Items` (分类视图) | `暂无分类或可阅读附件` | `main.lua:300` | 上下文区分：根目录或子分类为空时 |
| 6.3 | `No Items` (附件子列表) | `暂无附件` | `main.lua:260` | 上下文区分：条目下无附件时 |
| 6.4 | `No Results` | 空查询：`暂无可阅读附件`；关键词搜索：`未找到匹配的附件` | `main.lua:273` | “All Items”与搜索共用代码，按 query 是否为空区分中文 |
| 6.5 | `Search results` | `搜索结果` | `main.lua:277` | 搜索结果列表标题 |
| 6.6 | `Search Zotero titles` | `搜索 Zotero 文献` | `main.lua:75` | 搜索对话框标题 |
| 6.7 | `search query` | `搜索关键词` | `main.lua:77` | 输入框灰色占位底纹 |
| 6.8 | `This will search title, first author and DOI of all entries.` | `按标题、作者信息或 DOI 搜索 PDF/EPUB 附件。` | `main.lua:78` | 源码使用显示标签中的 creatorSummary，而非显式抽取第一作者；不承诺搜索完整作者列表 |
| 6.9 | `Search` | `搜索` | `main.lua:89` | 搜索按钮 |
| 6.10 | `Loading Zotero library…` | `正在加载 Zotero 文献库…` | `main.lua:680` | 等待提示 |
| 6.11 | `Could not load Zotero library.` | `无法加载 Zotero 文献库。` | `main.lua:672` | 加载失败提示 |

### 区域七：附件列表、聚合条目与长按详情

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 7.1 | `Attachments` | `附件` | `attachmentmenu.lua:9, main.lua:261` | 子列表标题 |
| 7.2 | `%d files` | `%d 个附件` | `attachmentmenu.lua:8` | 聚合项未下载标签 |
| 7.3 | `%d files · %d downloaded` | `%d 个附件 · 已下载 %d` | `attachmentmenu.lua:8` | 聚合项部分已下载标签 |
| 7.4 | `Downloaded` | `已下载` | `attachmentmenu.lua:7` | 单附件状态 |
| 7.5 | `Not downloaded` | `未下载` | `attachmentmenu.lua:7` | 单附件状态 |
| 7.6 | `Update available` | `待更新` | `attachmentmenu.lua:7` | 单附件状态 |
| 7.7 | `Open` | `打开` | `attachmentmenu.lua:13, main.lua:168` | 详情按钮 |
| 7.8 | `Attachment details` | `附件信息` | `attachmentmenu.lua:9, main.lua:195` | 详情弹窗标题 |
| 7.9 | `Document: %s` | `文献：%s` | `attachmentmenu.lua:10` | 统一全角中文冒号 |
| 7.10 | `Attachment: %s` | `附件：%s` | `attachmentmenu.lua:10` | 统一全角中文冒号 |
| 7.11 | `Filename: %s` | `文件名：%s` | `attachmentmenu.lua:11` | 统一全角中文冒号 |
| 7.12 | `Format: %s` | `格式：%s` | `attachmentmenu.lua:11` | 统一全角中文冒号 |
| 7.13 | `Status: %s` | `状态：%s` | `attachmentmenu.lua:12` | 统一全角中文冒号 |
| 7.14 | `Local size: %s` | `本地大小：%s` | `attachmentmenu.lua:12` | 统一全角中文冒号 |
| 7.15 | `File modified: %s` | `文件修改时间：%s` | `attachmentmenu.lua:13` | 统一全角中文冒号 |
| 7.16 | `Long-press a file to see its full name and details.` | `长按附件可查看完整名称和详细信息。` | `attachmentmenu.lua:25` | 聚合详情底部提示 |
| 7.17 | `\nZotero key: ` | 原样保留 `\nZotero key: ` | `attachmentmenu.lua:128` | 用户确定为专有名称；保留前置换行、标签和 key 值 |

### 区域八：本地文件删除与保护拦截

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 8.1 | `Delete local file` | `删除本地文件` | `attachmentmenu.lua:14, main.lua:185, 215` | 按钮及确认操作文案 |
| 8.2 | `Delete this local PDF, its annotations, bookmarks and reading progress? Zotero cloud data is kept. You can download it again.` | `删除本地 PDF 及其批注、书签和阅读进度？Zotero 云端数据会保留，可重新下载。` | `attachmentmenu.lua:15, main.lua:213` | 统一“本地”，表达更连贯自然 |
| 8.3 | `Local PDF and annotations deleted.` | `已删除本地 PDF 及其批注、书签和阅读进度。` | `attachmentmenu.lua:17, main.lua:225` | 完整对应删除的内容范围 |
| 8.4 | `Local PDF deleted; some local data could not be removed.` | `本地 PDF 已删除，但部分本地数据未能清理。` | `attachmentmenu.lua:18, main.lua:224` | 残留警告 |
| 8.5 | `Could not delete the local PDF.` | `无法删除本地 PDF。` | `attachmentmenu.lua:19, main.lua:226` | 失败主提示 |
| 8.6 | `Close this PDF before deleting its local copy.` | `请先关闭此 PDF，再删除本地文件。` | `attachmentmenu.lua:20, localfiles.lua:31` | 正在阅读保护 |
| 8.7 | `Local PDF not found.` | `未找到本地 PDF。` | `attachmentmenu.lua:21, localfiles.lua:14` | 统一使用“本地” |
| 8.8 | `Only downloaded PDF attachments can be removed.` | `只能删除已下载的 PDF 附件。` | `attachmentmenu.lua:22, localfiles.lua:10` | 状态校验拦截 |
| 8.9 | `The PDF path does not match its attachment storage.` | `PDF 路径与附件存储目录不匹配。` | `attachmentmenu.lua:23, localfiles.lua:20` | 安全路径校验 |
| 8.10 | `The local PDF changed. Open its details again.` | `本地 PDF 已发生变化，请重新打开附件信息。` | `attachmentmenu.lua:24, localfiles.lua:28` | 过期提示 |

### 区域九：PDF 只读批注弹窗、颜色、菜单拦截与统计

| 编号 | 当前英文 / 现有文案 | 建议简体中文 | 文件与行号 | 语义与设计说明 |
| :--- | :--- | :--- | :--- | :--- |
| 9.1 | `Zotero Annotation`（标题前缀） | 原样保留 `Zotero Annotation` | `annotationpolicy.lua:26` | 用户确定为专有名称；标题中的颜色仍按当前界面语言显示 |
| 9.2 | 颜色映射：`Yellow`, `Red`, `Green`, `Blue`, `Purple`, `Magenta`, `Orange`, `Gray`, `Olive`, `Cyan` | `黄`, `红`, `绿`, `蓝`, `紫`, `品红`, `橙`, `灰`, `橄榄`, `青` | `annotations.lua:30-31, annotationpolicy.lua:7-13` | 批注标题颜色后缀 |
| 9.3 | `Go to annotation` | `转到批注` | `annotations.lua:29, annotationpolicy.lua:104` | 跨页跳转按钮 |
| 9.4 | `No comment.` | `无评论。` | `annotations.lua:28, annotationpolicy.lua:121` | 特指无批注附属评论 |
| 9.5 | `Area annotation` | `区域批注` | `annotations.lua:27` | 区域框选类型 |
| 9.6 | `Zotero annotations are read-only` | `Zotero 批注只读` | `annotations.lua:32, annotationpolicy.lua:253` | 批量选择弹窗标题 |
| 9.7 | `Edit this annotation in Zotero, then synchronize and reopen the PDF.` | `请在 Zotero 中修改此批注，然后同步并重新打开 PDF。` | `annotations.lua:33, annotationpolicy.lua:64` | 只读拦截提示 |
| 9.8 | `PDF file protected by Zotero` | `Zotero PDF 原文件已保护` | `annotations.lua:34, annotationpolicy.lua:182` | 菜单被禁用项替换文本 |
| 9.9 | `This Zotero PDF is protected. Local annotations are saved in KOReader settings.` | `此 Zotero PDF 原文件已保护。本地批注保存于 KOReader 文档设置。` | `annotations.lua:35, annotationpolicy.lua:186, 294` | 拦截写入文件时的说明 |
| 9.10 | `Apply current style and color to local highlights? Zotero annotations stay read-only.` | `将当前样式和颜色应用于本地高亮？Zotero 批注保持只读。` | `annotations.lua:36, annotationpolicy.lua:164` | 确认提示 |
| 9.11 | `Update selected local annotations? Zotero annotations stay read-only.` | `修改选中的本地批注？Zotero 批注保持只读。` | `annotations.lua:37, annotationpolicy.lua:225` | 确认提示 |
| 9.12 | `Local annotations updated: %d; read-only Zotero annotations skipped: %d` | `已修改本地批注：%d；已跳过只读 Zotero 批注：%d` | `annotations.lua:38, annotationpolicy.lua:69` | 结果浮层 |
| 9.13 | `Refresh annotations` | `更新批注` | `annotations.lua:24, main.lua:177` | 详情按钮 |
| 9.14 | `PDF annotations updated.` | `PDF 批注已更新。` | `annotations.lua:26, main.lua:249` | 成功首行 |
| 9.15 | `PDF annotations were not updated.` | `PDF 批注未更新。` | `annotations.lua:39, main.lua:152, 251` | 失败首行 |
| 9.16 | `Could not apply Zotero annotations.` | `未能显示 Zotero 批注。` | `annotations.lua:40, main.lua:376` | 加载异常提示 |
| 9.17 | `Zotero annotations are displayed in original-page mode.` | `Zotero 批注支持原版页面显示，请关闭文字重排。` | `annotations.lua:41, main.lua:378` | 重排模式警告 |

### 区域十：嵌套动态错误模板与上层网络/存储提示

| 编号 | 动态模板与原文 | 建议简体中文 | 文件与行号 | 嵌套展开与变量说明 |
| :--- | :--- | :--- | :--- | :--- |
| 10.1 | `Fetching %s (page %d): %s` | `获取%s失败（接口分页第 %d 页）：%s` | `zoteroapi.lua:429` | 按顺序：第一个 `%s` 为阶段中文（文献库条目/分类/批注），`%d` 为 API 分页页码，最后一个 `%s` 为已翻译的具体错误；不使用 Lua 不支持的位置占位符 |
| 10.2 | `Checking Zotero account: %s` | `检查 Zotero 账户：%s` | `zoteroapi.lua:584, 965` | `%s` 拼接具体账户校验错误 |
| 10.3 | `Fetching deletions: %s` | `获取已删除条目：%s` | `zoteroapi.lua:540` | `%s` 拼接删除记录接口返回的错误 |
| 10.4 | `File download timed out while waiting for data (received %d bytes; %s)` | `等待数据时文件下载超时（已接收 %d 字节；%s）` | `zoteroapi.lua:344` | 保留字节数与底层 socket 诊断 `%s` |
| 10.5 | `Incomplete file download: received %d of %d bytes. Please retry.` | `文件下载不完整：仅接收 %d / %d 字节，请重试。` | `zoteroapi.lua:741` | 保留字节进度 |
| 10.6 | `Zotero requested a delay. Please retry in %d seconds.` | `Zotero 要求稍后再试，请在 %d 秒后重试。` | `zoteroapi.lua:311` | Backoff 提示 |
| 10.7 | `Network request failed: %s` | `网络请求失败：%s` | `zoteroapi.lua:342` | 保留网络诊断 |
| 10.8 | `Error: API responded with status code %s` | `错误：API 返回状态码 %s` | `zoteroapi.lua:366` | 保留 HTTP 状态码 |
| 10.9 | `Connection failed: %s` | `连接失败：%s` | `zoteroapi.lua:606` | 保留底层 socket 报错 |
| 10.10 | `WebDAV responded with status code %s` | `WebDAV 返回状态码：%s` | `zoteroapi.lua:609` | 保留 HTTP 状态码 |
| 10.11 | `The Zotero library changed during synchronization. Please retry.` | `文献库在同步期间发生变化，请重试。` | `zoteroapi.lua:19` | **代码事实**：此为 `LIBRARY_CHANGED` 哨兵串，内部比较保留原英文，仅在最终呈现在 UI 时映射为简中 |
| 10.12 | `Could not open file.` | `无法打开文件。` | `main.lua:140` | 打开 PDF 失败首行 |
| 10.13 | `Could not initialize Zotero.` | `无法初始化 Zotero。` | `main.lua:400` | 插件初始化失败 |

---

## 5. 附录：底层候选错误模板调用路径与可见性审查

下表按源码调用路径列出底层错误候选。可见性依赖具体失败条件；缓存读取等错误有时会触发恢复而不展示。这里列入可能到达界面的模板，未通过真实故障注入验证每个分支。第 10 节补列初版已有、修订表遗漏的常见模板。

### 5.1 `zoteroapi.lua` 候选漏项

| 文件与行号 | 原文 | 可见性判定 | 建议简体中文 / 处理方式 | 调用链与分析 |
| :--- | :--- | :--- | :--- | :--- |
| `zoteroapi.lua:56` | `Could not encode cache data` | 用户可见 | `无法对缓存数据编码` | 保存缓存失败返回，向上传递给同步结果弹窗 |
| `zoteroapi.lua:64` | `Invalid JSON data` | 用户可见 | `JSON 数据无效` | 读取损坏缓存返回，展示在 UI 警告中 |
| `zoteroapi.lua:166` | `Could not read Zotero cache: ` | 用户可见 | `无法读取 Zotero 缓存：` | 启动或浏览时读缓存失败，抛出并显示在 InfoMessage |
| `zoteroapi.lua:191` | `Could not save Zotero cache: ` | 用户可见 | `无法保存 Zotero 缓存：` | 同步保存时向上传播至同步失败提示 |
| `zoteroapi.lua:209` | `Could not create Zotero directory: ` | 用户可见 | `无法创建 Zotero 目录：` | 初始化失败展示在 `main.lua:400` 弹窗 |
| `zoteroapi.lua:225` | `Could not create attachment storage: ` | 用户可见 | `无法创建附件存储目录：` | 初始化失败展示在 `main.lua:400` 弹窗 |
| `zoteroapi.lua:241` | `Could not create attachment storage: ` | 用户可见 | `无法创建附件存储目录：` | 更改用户 ID 保存时直接弹窗反馈 |
| `zoteroapi.lua:366` | `Error: API responded with status code ` | 用户可见 | `错误：API 返回状态码 ` | 非 200 HTTP 响应向上传递给同步/下载错误 |
| `zoteroapi.lua:391` | `Error: failed to parse JSON in response` | 用户可见 | `错误：响应 JSON 解析失败` | 元数据接口解析失败直接在同步失败中提示 |
| `zoteroapi.lua:392` | `Error: expected a JSON array in Zotero response` | 用户可见 | `错误：Zotero 响应应为 JSON 数组` | API 格式异常直接在同步失败中提示 |
| `zoteroapi.lua:405` | `Error: missing or invalid Last-Modified-Version header` | 用户可见 | `错误：响应缺失或包含无效的 Last-Modified-Version 标头` | 协议版本字段缺失直接在同步失败中提示 |
| `zoteroapi.lua:415` | `Error: could not determine number of items in library` | 当前 UI 未调用的导出接口 | 可参考译文：`无法获取文献库中的条目数量` | 所属 fetchCollectionSize 只存在定义；当前分页与界面不调用它，不计入当前 UI 漏项 |
| `zoteroapi.lua:433` | `Error: invalid pagination link` | 用户可见 | `错误：分页链接无效` | Link header 损坏向上传递至同步失败 |
| `zoteroapi.lua:454` | `Error: expected a JSON array in Zotero response` | 用户可见 | `错误：Zotero 响应应为 JSON 数组` | 分页数据异常向上传递至同步失败 |
| `zoteroapi.lua:458` | `Error: incomplete JSON array in Zotero response` | 用户可见 | `错误：Zotero 响应中的 JSON 数组不完整` | 分页数据异常向上传递至同步失败 |
| `zoteroapi.lua:461` | `Error: invalid object in Zotero response` | 用户可见 | `错误：Zotero 响应中包含无效对象` | 条目数据异常向上传递至同步失败 |
| `zoteroapi.lua:472` | `Error: inconsistent Total-Results header` | 用户可见 | `错误：Total-Results 标头不一致` | 分页总数变化向上传递至同步失败 |
| `zoteroapi.lua:482` | `Error: incomplete pagination` | 用户可见 | `错误：分页未完全接收` | 提前结束向上传递至同步失败 |
| `zoteroapi.lua:584` | `Checking Zotero account: ` | 用户可见 | `检查 Zotero 账户：` | 账户核验失败前缀，向上传播至同步失败提示 |
| `zoteroapi.lua:588` | `Could not synchronize Zotero: ` | 用户可见 | `无法同步 Zotero：` | `syncAllItems` 顶层异常捕获前缀 |
| `zoteroapi.lua:619` | `Invalid attachment key or filename` | 用户可见 | `无效的附件标识或文件名` | 打开附件或获取路径时向上传递至无法打开提示 |
| `zoteroapi.lua:666` | `Invalid download URL` | 用户可见 | `下载地址无效` | 下载附件时向上传递至无法下载提示 |
| `zoteroapi.lua:668` | `Could not create download file: ` | 用户可见 | `无法创建下载临时文件：` | 文件创建失败向上传递至无法下载提示 |
| `zoteroapi.lua:695` | `Could not save download: ` | 用户可见 | `无法保存下载文件：` | 文件落盘失败向上传递至无法下载提示 |
| `zoteroapi.lua:700` | `Missing download redirect location` | 用户可见 | `缺少重定向地址` | 重定向标头缺失向上传递至无法下载提示 |
| `zoteroapi.lua:702` | `Refusing an HTTPS download redirect to HTTP` | 用户可见 | `拒绝从 HTTPS 重定向至不安全的 HTTP` | 安全拦截向上传递至无法下载提示 |
| `zoteroapi.lua:712` | `Unexpected encoding in file download` | 用户可见 | `文件下载编码格式不支持` | 压缩传输异常向上传递至无法下载提示 |
| `zoteroapi.lua:717` | `Invalid response length in file download` | 用户可见 | `文件下载响应长度无效` | 长度校验向上传递至无法下载提示 |
| `zoteroapi.lua:728` | `Could not save resumed download: ` | 用户可见 | `无法保存续传文件：` | 追加文件失败向上传递至无法下载提示 |
| `zoteroapi.lua:734` | `Could not save download: ` | 用户可见 | `无法保存下载文件：` | 重命名落盘失败向上传递至无法下载提示 |
| `zoteroapi.lua:751` | `Too many download redirects` | 用户可见 | `重定向次数过多` | 死循环保护向上传递至无法下载提示 |
| `zoteroapi.lua:794` | `Could not extract the attachment from its WebDAV archive` | 用户可见 | `无法从 WebDAV 压缩包中解压附件` | 解压失败向上传递至无法下载提示 |
| `zoteroapi.lua:798` | `Could not save extracted attachment: ` | 用户可见 | `无法保存解压后的附件：` | 解压后落盘失败向上传递至无法下载提示 |
| `zoteroapi.lua:875` | `The attachment was not found in the library` | 用户可见 | `文献库中未找到该附件` | 打开缺失附件时弹出警告 |
| `zoteroapi.lua:876` | `This item is not an attachment` | 用户可见 | `该条目不是附件` | 误触发非附件项时弹出警告 |
| `zoteroapi.lua:886` | `Could not create attachment directory: ` | 用户可见 | `无法创建附件目录：` | 目录创建失败向上传递至无法下载提示 |
| `zoteroapi.lua:925` | `Could not save unpacked attachment: ` | 用户可见 | `无法保存解压后的附件：` | WebDAV 解压落盘失败提示 |
| `zoteroapi.lua:936` | `Could not save attachment: ` | 用户可见 | `无法保存附件：` | 下载完成保存失败提示 |
| `zoteroapi.lua:940` | `Could not save attachment metadata: ` | 用户可见 | `无法保存附件元数据：` | 缓存写入失败提示 |
| `zoteroapi.lua:961` | `Only PDF annotations are supported` | 用户可见 | `仅支持 PDF 批注` | EPUB 尝试拉取批注时提示 |
| `zoteroapi.lua:965` | `Checking Zotero account: ` | 用户可见 | `检查 Zotero 账户：` | 批注同步时账户核验前缀 |
| `zoteroapi.lua:982` | `Invalid PDF attachment in annotation response` | 用户可见 | `批注响应中包含无效的 PDF 附件` | 批注快照校验向上传递至批注更新失败 |
| `zoteroapi.lua:1003` | `Could not fetch PDF annotations: ` | 用户可见 | `无法获取 PDF 批注：` | 批注抓取顶层捕获向上传递至结果弹窗 |

### 5.2 `annotations.lua` 候选漏项

| 文件与行号 | 原文 | 可见性判定 | 建议简体中文 / 处理方式 | 调用链与分析 |
| :--- | :--- | :--- | :--- | :--- |
| `annotations.lua:83` | `Invalid annotation cache JSON` | 用户可见 | `批注缓存 JSON 无效` | 读取损坏批注缓存时向上传递 |
| `annotations.lua:91` | `Could not encode PDF annotations` | 用户可见 | `无法对 PDF 批注编码` | 批注落盘前 JSON 编码失败 |
| `annotations.lua:111` | `Missing annotation position` | 用户可见 | `缺少批注位置信息` | 批注格式校验失败 |
| `annotations.lua:114` | `Invalid annotation page position` | 用户可见 | `批注页面位置无效` | 批注格式校验失败 |
| `annotations.lua:127` | `Invalid annotation rectangles` | 用户可见 | `批注选框矩形坐标无效` | 批注格式校验失败 |
| `annotations.lua:138` | `Invalid PDF annotation snapshot` | 用户可见 | `PDF 批注快照数据无效` | 批注规范化校验失败 |
| `annotations.lua:149` | `Invalid annotation object in PDF snapshot` | 用户可见 | `PDF 快照中的批注对象无效` | 批注规范化校验失败 |
| `annotations.lua:155` | `Invalid annotation field: ` | 用户可见 | `批注字段无效：` | 字段校验前缀 |
| `annotations.lua:202` | `The annotation library version went backwards` | 用户可见 | `批注版本异常倒退` | 版本乱序校验向上传播至失败提示 |
| `annotations.lua:208` | `Could not save PDF annotations: ` | 用户可见 | `无法保存 PDF 批注：` | 批注写入失败向上传播至失败提示 |
| `annotations.lua:278` | `Invalid annotation date` | 用户可见 | `批注日期无效` | ISO 时间解析失败向上传递 |
| `annotations.lua:281` | `Invalid annotation date` | 用户可见 | `批注日期无效` | 日期月份天数越界向上传递 |
| `annotations.lua:286` | `Invalid annotation timezone` | 用户可见 | `批注时区无效` | 时区偏移解析失败向上传递 |
| `annotations.lua:330` | `Annotation page exceeds PDF page count` | 用户可见 | `批注所在页码超出 PDF 总页数` | 页面映射异常向上传播至文档打开时提示 |
| `annotations.lua:334` | `Could not read PDF page dimensions` | 用户可见 | `无法读取 PDF 页面尺寸` | 尺寸异常向上传播至文档打开时提示 |
| `annotations.lua:341` | `Annotation is outside the standard PDF page; special page geometry is unsupported` | 用户可见 | `批注超出标准 PDF 页面范围；不支持特殊页面几何参数` | 页面映射异常向上传播至文档打开时提示 |
| `annotations.lua:441` | `This PDF reader does not provide annotation geometry methods` | 异常时可见 | `此 PDF 阅读器不支持批注位置计算` | 缺少对应方法时会在文档初始化或批注导入路径抛出，可能进入初始化失败/加载失败提示，需翻译 |
| `annotations.lua:576` | `Reader annotations are not initialized` | 用户可见 | `阅读器批注未初始化` | 载入批注时向上传播至文档打开时提示 |
| `annotations.lua:598` | `Could not confirm the PDF identity of previously imported annotations` | 用户可见 | `无法确认之前导入的批注是否对应当前 PDF` | 文件指纹核验失败向上传播 |
| `annotations.lua:629` | `Could not save imported annotations: ` | 用户可见 | `无法保存已导入的批注：` | 设置持久化失败向上传播至文档打开时提示 |

### 5.3 `librarycache.lua` 候选漏项

| 文件与行号 | 原文 | 可见性判定 | 建议简体中文 / 处理方式 | 调用链与分析 |
| :--- | :--- | :--- | :--- | :--- |
| `librarycache.lua:23` | `Invalid cache JSON separator` | 用户可见 | `缓存 JSON 分隔符无效` | 流式解析大缓存损坏，抛出并在 `zoteroapi.lua:166` 包装后展示在 `main.lua:672` |
| `librarycache.lua:38` | `Unexpected end of cache JSON` | 用户可见 | `缓存 JSON 意外截断` | 缓存文件截断抛出，同上展示给用户 |
| `librarycache.lua:65` | `Unexpected end of cache JSON` | 用户可见 | `缓存 JSON 意外截断` | 缓存文件截断抛出，同上展示给用户 |
| `librarycache.lua:77` | `Invalid cache object key` | 用户可见 | `缓存键名无效` | 键名非字符串抛出，同上展示给用户 |
| `librarycache.lua:92` | `Invalid cache record` | 用户可见 | `缓存记录无效` | 记录非对象抛出，同上展示给用户 |
| `librarycache.lua:99` | `Unexpected trailing cache JSON` | 用户可见 | `缓存 JSON 包含多余的末尾内容` | 文件末尾脏数据抛出，同上展示给用户 |
| `librarycache.lua:103` | `Could not parse cache JSON: ` | 用户可见 | `无法解析缓存 JSON：` | 顶层 pcall 包装返回，同上展示给用户 |

---

## 6. 非插件翻译数据边界（动态数据隔离）

以下数据为用户个人研究资产或协议标识，**严禁**插件做全字符串替换或翻译干预：

1. **文献与条目元数据**：论文题目（`item.data.title`）、作者名称（`item.meta.creatorSummary`）、DOI、出版信息。

2. **分类名称**：用户自定义的文献库分类目录名（`collection.data.name`）。

3. **附件文件名与路径**：用户原始文件名（`item.data.filename`，如 `paper.pdf`）、文件哈希与路径。

4. **Zotero key**：英文标签 `Zotero key: ` 和标识值（如 `P5N8ZQ2W`）均保持源码原样；`Zotero Annotation` 标题前缀也保留英文。

5. **批注原文与读者评论**：PDF 高亮/下划线选中的正文（`item.text`）、读者书写的批注评论内容（`item.note`）、自定义 Hex 色值（如 `#1a2b3c`）。

6. **空值替代符规范**：作者缺失时 `Unknown` ➔ `未知作者`；题名缺失时 `Untitled` ➔ `无标题`。

---

## 7. 电子墨水屏文案长度与排版策略

1. **紧凑列表状态标签（Mandatory Func）**：维持 3 字紧凑原则（`已下载`、`待更新`），适应电子墨水屏列表右侧空间；聚合格式统一使用 `%d 个附件`、`%d 个附件 · 已下载 %d`。

2. **两秒局部刷新节奏**：`ProgressDialog` 设有 2 秒最小刷新间隔，阶段提示文字力求短小平实（如 `正在获取文献库条目…`），避免过长句子导致高度跳变。

3. **固定弹窗几何尺寸**：`ProgressDialog` 采用固定区域覆盖旧提示；换行、裁切、物理刷新与残影效果需在目标设备实际验证。

4. **标点与格式规范**：中文提示一律采用全角冒号与括号，英文变量与数字两端保持合理间隙（如 `已处理：%d / %d（%d%%）`）。

---

## 8. 文档分级策略：运行时 UI 与开发文档

1. **P0 优先级（运行时 UI，必须 100% 完整汉化）**：
   - 涵盖主菜单、设置表单、浏览树、附件详情、下载与同步进度框、二次确认弹窗、只读保护拦截、所有用户可见的底层错误与嵌套模板。

2. **P1 优先级（用户操作指南，后续建议汉化）**：
   - `README.md` 中面向终端用户的配置步骤、操作流程、单向批注保护机制与本地文件删除特性说明，在后续版本中提供中文说明。

3. **P2 优先级（技术协议与测试，保持英文）**：
   - `docs/zotero-api-audit.md`（Zotero API 协议审计）、`tests/`（离线单元与回归测试断言）、开发协议日志及 Git 提交历史，保持英文原文。

---

## 9. 技术实施架构建议与约束（供 Lead 审查）

> 注意：本节仅为架构构想与约束分析，未改动任何代码。

### 9.1 集中轻量级本地化架构（`i18n.lua`）

- 建议抽象单一轻量级 `i18n.lua` 模块，集中管理全量中文映射字典（包含原 `attachmentmenu`、`annotations` 的 61 个译文键、其他插件界面文案及可见错误模板）。
- `_meta.lua` 的插件介绍也使用此入口；该模块只依赖 gettext 等轻量能力，不应为读取插件元数据加载账户 API、阅读器或批注模块。
- 沿用界面语言：当 KOReader 界面语言为 `zh_CN` 或 `zh_Hans` 时优先匹配本插件中文表，未命中或非中文时透明回退至 KOReader 原生 `_("...")`。插件专用文案无需等待上游语言包收录，也无需另设 `.mo` 编译流程。英文和其他语言继续使用 KOReader gettext。

### 9.2 关键实施约束与哨兵值保护

- **`ProgressDialog` 阶段文案延迟求值**：目前 `progressdialog.lua` 中的 `stages` 表在模块 `require` 时即完成求值。实施时应保留键名，在实例创建 (`init`) 或界面更新 (`update`) 时动态调用翻译，避免模块加载顺序导致的语言状态不同步。
- **协议控制哨兵值隔离**：
  - `zoteroapi.lua:19` 中的 `LIBRARY_CHANGED` 既是错误信息，也是控制流的重试比较哨兵 (`if err == LIBRARY_CHANGED`)，**绝对不能**在定义处改变原英文值！只能在最终传递至上层 UI 展示时通过翻译函数映射为中文。
  - 同理，`NOT_MODIFIED`、`unsupported`、`unchanged`、`updated` 等控制值严禁改动。
- **防误伤安全边界**：严禁对文件路径、URL、JSON 键名、用户论文标题或批注文本做全局字符串正则盲目替换。


## 10. 核对补充：常见错误、原生按钮与显示边界

以下文案采用 AGY 首版译文及双方讨论的术语，补足修订清单未重复列出的模板。位置以 `374bf8e` 源码为准；拼接前缀统一按模板翻译后再插入参数。

### 10.1 常见错误补表

| 当前英文或模板 | 建议简体中文 | 源位置与注意点 |
| --- | --- | --- |
| `Invalid Zotero cache. Use Maintenance > Resync entire collection.` | `Zotero 本地缓存无效，请使用“维护 → 重新同步整个文献库”。` | `zoteroapi.lua:169`；路径应与中文菜单一致 |
| `Error: must set a numeric User ID` | `请先设置数字用户 ID。` | `zoteroapi.lua:299` |
| `Error: must set API Key` | `请先设置 API 密钥。` | `zoteroapi.lua:300` |
| `Error: the API key does not belong to this User ID` | `API 密钥与该用户 ID 不匹配。` | `zoteroapi.lua:497` |
| `Error: the API key does not permit reading your library` | `该 API 密钥没有文献库读取权限。` | `zoteroapi.lua:499` |
| `Zotero rate limit reached. Please retry later.` | `已达到 Zotero 请求频率限制，请稍后重试。` | `zoteroapi.lua:365` |
| `Error: %s` / `request failed` | `请求失败：%s` / `请求失败` | `zoteroapi.lua:364`；已知 socket 原因给中文说明，原始诊断可作为细节保留 |
| `Error: incomplete metadata response (received %d of %d bytes)` | `元数据响应不完整（已接收 %d / %d 字节）。` | `zoteroapi.lua:385` |
| `Error: invalid deletion log in Zotero response` | `错误：Zotero 响应中的删除记录无效。` | `zoteroapi.lua:547`；增量同步的已删除条目或分类字段格式无效，最终进入 `main.lua:717` 的同步失败弹窗 |
| `The library version went backwards. Please resync the entire collection.` | `文献库版本异常倒退，请重新同步整个文献库。` | `zoteroapi.lua:528` |
| `A valid HTTP or HTTPS WebDAV URL is required` | `请填写有效的 HTTP 或 HTTPS WebDAV 地址。` | `zoteroapi.lua:598,804` |
| `Access forbidden. Check username and password.` | `访问被拒绝，请检查用户名和密码。` | `zoteroapi.lua:608`；不把所有 403 都断言为密码错误 |
| `Attachment not found` | `未找到附件。` | `zoteroapi.lua:614`；与 `The attachment was not found in the library` 分别保留上下文 |
| `The resumed download does not match the original file or byte range` | `续传内容与原文件或字节范围不一致。` | `zoteroapi.lua:725` |
| `Unsupported attachment link mode: %s. Linked files and linked URLs are not stored by Zotero.` | `不支持的附件链接方式：%s。Zotero 不存储链接文件和链接网址附件。` | `zoteroapi.lua:879`；`linkMode` 原值作为诊断信息保留 |
| `Only PDF and EPUB attachments are supported` | `仅支持 PDF 和 EPUB 附件。` | `zoteroapi.lua:881` |
| `The downloaded ZIP does not match Zotero's storage checksum.` | `下载的 ZIP 文件与 Zotero 校验和不匹配。` | `zoteroapi.lua:916` |
| `The downloaded file does not match Zotero's attachment metadata. Synchronize the library and retry.` | `下载的文件与 Zotero 附件元数据不匹配，请同步文献库后重试。` | `zoteroapi.lua:930`；使用常规“同步”，不误导用户必须做完整重同步 |
| `The downloaded attachment is empty` | `下载的附件文件为空。` | `zoteroapi.lua:933` |
| `Could not download attachment: %s` | `无法下载附件：%s` | `zoteroapi.lua:948`；继续翻译插件生成的嵌套错误 |
| `Cached annotations belong to a different PDF file; download the current attachment` | `缓存批注属于不同的 PDF 文件，请下载当前附件。` | `annotations.lua:603` |
| `unzip command failed (%s: %s)` / `. The unzip command failed.` | `unzip 解压命令失败（%s：%s）` / `。unzip 解压命令失败。` | `zoteroapi.lua:788,795`；外部 unzip 诊断原样保留，插件写的说明译成中文 |

已知网络原因采用简短说明，例如 `timeout` → “连接超时”、`closed` → “连接已关闭”、`sink timeout` → “接收数据超时（sink timeout）”。只处理已知错误字段，不扫描替换文件名、URL 或整段用户文本。

### 10.2 KOReader 原生按钮与菜单比较

`annotationpolicy.lua` 的 9 个 gettext 字面量调用中，有通用按钮和原生菜单匹配。它们不是 9 个新增的插件专用译文键：

| 原文 | 中文含义 | 处理 |
| --- | --- | --- |
| `Close` | 关闭 | 沿用 KOReader gettext |
| `Select all` | 全选 | 沿用 KOReader gettext |
| `Select page` | 选择本页 | 沿用 KOReader gettext |
| `Deselect all` | 取消全选 | 沿用 KOReader gettext |
| `Delete note` | 删除评论 | 此处删除的是高亮/批注的评论，不是独立笔记；沿用 KOReader 原生按钮译文，必要时再核对界面用词 |
| `Exit select mode` | 退出选择模式 | 沿用 KOReader gettext |
| `Remove` | 删除 | 沿用 KOReader gettext |
| `Apply current style and color to all highlights` | 将当前样式和颜色应用于所有高亮 | `annotationpolicy.lua:161` 用于比较原生菜单文字，必须保留同一 KOReader gettext 结果 |
| `Write all highlights into PDF file` | 将所有高亮写入 PDF 文件 | `annotationpolicy.lua:181` 用于比较原生菜单文字，必须保留同一 KOReader gettext 结果 |

上表中文是含义说明，实际按钮沿用目标 KOReader 语言包。只读保护相关比较不能换成插件自有译文，否则可能找不到原生菜单项。`main.lua` 的 Cancel/Search/Settings 等按钮可由统一入口按上下文显示中文；账户表单的 Update 固定译为“保存”。

### 10.3 数据与流程显示边界

- `Unknown` / `Untitled` 是插件提供的空值替代文字，分别译为“未知作者”/“无标题”。实际作者名和题名原样保留；源位置为 `zoteroapi.lua:1015,1016,1083,1099`。
- 源码本地文件大小当前使用 `%.1f KiB`（`attachmentmenu.lua:122`），本轮只汉化标签，不新增单位换算。传输进度本来支持 B/KiB/MiB，仍保留这些单位。
- 首次完整同步没有增量删除阶段；没有已下载 PDF 时不会显示批量批注处理阶段。流程示例用于展示典型文案，较快阶段还可能因两秒刷新间隔而未显示。
- 不新增确认按钮、弹窗标题、下载百分比、预计时间或新的上传操作。设置、同步、更新批注和删除的行为保持当前代码契约。
- `annotations.lua:441` 的阅读器接口缺失属于异常时可能可见的错误，也纳入翻译。损坏批注缓存可能被恢复流程替代；如果最终向用户报错，则插件说明必须中文化。

## 11. 实施范围与验收（审定方案）

本次建议批准运行时界面完整简体中文覆盖，并补充 README 中直接指导用户安装、账户配置、WebDAV 配置、日常使用与升级的中文说明。README 中的菜单路径同步更新。开发协议、日志与测试代码无需整篇翻译。

计划修改范围为新增轻量 `i18n.lua`，接入 `_meta.lua`、`main.lua`、`progressdialog.lua`、`attachmentmenu.lua`、`annotations.lua`、`annotationpolicy.lua` 的插件可见文字，以及 `zoteroapi.lua`、`librarycache.lua`、`localfiles.lua` 中需要展示的错误说明。错误模板在构造处或展示边界翻译，具体接入点保持现有返回值和重试逻辑；不得直接替换内部哨兵值。

验收按本次影响范围进行：

1. 检查全部列出的界面入口和插件自写失败提示，核对语言分支、中文标点、动态阶段名及占位符（`%d`、`%s`、`%%`、换行）。不使用 `%1$s` 等位置占位符。

2. 复用现有附件、批注、删除和同步行为测试，必要时补充能检验集中翻译入口、语言切换及嵌套错误的少量行为验证。英文和其他语言的回退行为也要验证。

3. 完成项目现有离线测试及与菜单匹配/批注保护有关的必要集成检查，确认重试、增量同步、只读保护与本地删除行为不变。

4. 在目标 Kindle/KOReader 环境检查窄屏菜单、输入框占位、固定进度框、批注标题、长失败提示的换行和裁切。没有设备验证时明确记录该项待验收。

本轮仅核对源码与文案，没有实施翻译，也没有宣称通过运行或真机排版测试。待用户批准本方案后再落实代码。

## 12. 再次复检结论

本次按用户要求，由 AGY 沿界面与错误传播路径复检，Codex 对九个主源码文件做字符串覆盖对照并核验新增漏项。`Synchronize`（`main.lua:445`）已在本方案第 4 节的主菜单表中列为“同步”；之前面向用户的精选表漏列了它。

新增补项为 `zoteroapi.lua:547` 的删除记录异常提示，以及 `annotations.lua:269` 的错误省略计数。后者不是英文单词，但此前未纳入界面文案清单，需要改为含义明确的中文格式。

用户最新确定：`All Items` 保留英文；`Zotero Annotation` 和源码标签 `Zotero key` 保留英文原样。方案正文、术语表和流程示例均按此更新。

当前源码中直接写出的菜单、表单、输入提示、进度、结果、附件详情、批注保护文字与可能展示的插件自写错误，已逐项列入或归类。B/KiB/MiB、PDF/EPUB、API/DOI/WebDAV、品牌名、协议字段、内部控制值与纯日志按既定边界保留。外部库或系统动态生成的诊断，以及目标 KOReader 原生语言包覆盖情况，需要在后续运行验证时核验，不能由静态复检穷尽。


## 13. Codex 独立复检与 AGY 商讨后的合并结论

Codex 另做一轮独立检查：对九个主源码文件扫描 Lua 短字符串与长字符串、排除注释，再核对英文自然文本/常用标签候选和各个界面出口。343 个候选出现次数包括重复键、现有中文表的英文原文、协议和日志，不代表待翻译数量。AGY 随后核对这份候选清单及 Codex 的路径分析，双方合并以下结果：

- 原文漏项两处已补齐：删除记录异常（`zoteroapi.lua:547`）和错误省略计数（`annotations.lua:269`）。省略计数确定使用“……（共 %d 条错误）”。
- 补充空列表的中文上下文：“All Items”为空（`query == ""`）显示“暂无可阅读附件”；关键词搜索无结果显示“未找到匹配的附件”。附件子列表和分类视图另沿用各自的空状态。
- 搜索说明确定为“按标题、作者信息或 DOI 搜索 PDF/EPUB 附件。”；作者信息来自显示标签中的 `creatorSummary`，不改变检索逻辑。独立附件当前可按其标题或文件名匹配，保留该行为。
- 纠正可见性分类：`fetchCollectionSize` 的数量获取错误，以及只在测试中调用的 `setLibraryVersion` 的 `Invalid library version` 断言，不算当前界面漏项。本轮不为未调用接口扩大实施范围。
- `sink timeout` 在最终提示中可解释为“接收数据超时（sink timeout）”；内部重试比较、unzip 损坏检测词和纯日志保持原样。

在上述补项及场景修正之外，两轮源码静态复检未发现新的直接硬编码英文界面整句。目标 KOReader 原生按钮语言包和动态外部诊断仍按第 12 节边界在后续运行验证中检查。本节记录批准实施前的复检结论；入口命名已按用户后续决定更新。

## 14. 代码落实与验证记录（2026-10-10）

- 用户已批准落实，由 Codex 操刀，AGY 仅负责只读审核。
- 新增 `i18n.lua`，集中简体中文词典、空列表场景与界面错误格式化。原附件/批注词典合并到此入口；元数据、菜单、设置、搜索、结果和进度均接入。
- 底层错误保持英文原值，在 `main.lua` 与 `Annotations.summary()` 的展示出口翻译；`LIBRARY_CHANGED`、网络重试条件和协议字段不变。API 模块仅接入缺失作者/题名的显示回退。
- 进度阶段保存原文，在显示时按当前语言翻译；电子墨水屏刷新节奏与进度统计不变。`annotationpolicy.lua` 的 KOReader 原生菜单识别继续使用原生 gettext，专有名称保留。
- 新增 `README.zh-CN.md`，覆盖安装、账户、WebDAV、日常阅读与批注、缓存升级；英文 README 提供入口。
- 最终完成 165/165 项离线测试，包含新增语言回退、进度加载顺序、空视图、嵌套错误、同步哨兵、数据保留、同步统计和错误总数检查。静态对照未发现新增的插件直接界面漏项。
- 集成检查全部通过：KOReader 源码接口 29 项、批注只读策略 81 项（含中文原生菜单匹配）、本地删除/DocSettings 57 项、真实 JSON 11 项，共 178 项。宿主为 Pandoc 内嵌 Lua；Lua 5.1/LuaJIT 兼容性经过源码审查，未在相应解释器上实跑。
- AGY 只读审核结论为 `approve`，没有需要修复的发现。审核结果为 `.agy-staff/jobs/review-mv2b6ofy-32a223ea.result.md`。审核期间工作树变动提示涉及 Codex 新增的中文集成检查；已核对差异，内容与 Codex 的修改一致。
- `git diff --check` 通过。此次未改变同步、下载、只读保护或本地删除逻辑。
- 尚未进行 Kindle 真机中文排版、字体或屏幕刷新验证。

## 15. All Items 命名修订（2026-10-10）

用户将 `All Items` 调整为保留英文。`main.lua` 的顶层入口及空查询视图标题直接使用原文，避免 KOReader 宿主语言包重新翻译它；删除中文词典中的旧映射。空列表提示等其他中文文案继续生效。中文指南、术语表和流程示例已同步更新。安装包修订标识为 `2026-10-10-zh-CN-r2`。

修订后 165/165 项离线测试通过，包含宿主 gettext 会翻译 `All Items` 时仍保持英文的界面断言。AGY 只读复审结论为 `approve`，记录为 `.agy-staff/jobs/review-mv2hjf62-6bea1ebe.result.md`。
