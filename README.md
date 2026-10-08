# Zotero for KOReader

This addon for [KOReader](https://github.com/koreader/koreader) allows you to view your Zotero collections.

> [!NOTE]
> **Beta version**! Please report bugs, pull requests are welcome.

<div align="center"><img width="600" alt="Screenshot of this plugin displaying a list of papers alongside a search button" src="https://raw.githubusercontent.com/stelzch/screencasts/main/zotero-koplugin-screenshot.png"></div>

## 此 fork 的主要更新

基于 [源仓库](https://github.com/stelzch/zotero.koplugin)，主要更新：

- **单向 PDF 批注同步**：导入 Zotero 云端高亮、下划线、区域批注及颜色、文字、评论，支持云端修改与删除；点按区域可查看评论。
- **手动更新与离线查看**：Synchronize / Resync 更新已下载 PDF 的批注；Browse 长按附件可单独更新。重开后应用，最近阅读和文件管理器也能离线显示缓存。
- **释放本机空间**：Browse 长按 PDF → 删除本地文件，清理 PDF、批注、书签和阅读进度；云端保留，可重新下载。
- **保留本地数据**：独立批注缓存，保留本地批注、书签和阅读进度；不上传批注，不改写 PDF。
- **同步与下载修复**：库版本一致性、增量删除、Zotero Storage / WebDAV 文件校验、网络重试与截断续传；失败保留旧缓存。
- **浏览与性能优化**：同文献多附件分组、下载状态与长按详情、精简大库缓存，以及适合电子墨水屏的同步和下载进度。

## Features
* Synchronize a personal library via Zotero Web API v3, including trash and permanent deletions
* Display collections, navigate to sub-collections
* Download & open stored PDF and EPUB attachments (`imported_file` and `imported_url`)
* Show downloaded attachments and outdated local copies directly in the browser
* Group multiple attachments of one publication, with file names and full details on long-press
* Supports Zotero File Storage and WebDAV storage with Basic authentication
* Show download bytes and synchronization stages/counts with e-ink-friendly progress updates
* View Zotero PDF highlights, underlines and area annotations offline
* Search entries by the title of the publication, name of the first author or DOI.
## Installation Guide
1. Copy the files in this repository to `<KOReader>/plugins/zotero.koplugin`
2. Obtain a dedicated API key in your [Zotero Settings](https://www.zotero.org/settings/keys). Enable access to your personal library and, for Zotero File Storage downloads, its files. Note the userID and the private key.
3. Set your credentials for Zotero either directly in KOReader or edit the configuration file as described [below](#manual-configuration).

In KOReader, the Zotero plugin will be visible in the search tab (magnifying glass icon) inside the top menu.

### Differences to previous  versions
In previous versions, you had to copy your entire Zotero directory to your device.
The new version however works with the Zotero Web API and downloads attachments ad-hoc.
If you are not interested in syncing your collection and would rather access your entire collection offline, you can take a look at version [0.1](https://github.com/stelzch/zotero.koplugin/releases/tag/0.1).

## Configuration

### WebDAV support
If you do not want to pay Zotero for more storage, you can also store the attachments in a WebDAV folder like [Nextcloud](https://nextcloud.com).
You can read more about how to set up WebDAV in the [Zotero manual](https://www.zotero.org/support/sync).

The WebDAV URL should point to the directory named `zotero`, for example `https://your-instance.tld/remote.php/dav/files/your-username/zotero`. Configure the same account used for Zotero file sync; an app password can be used where the server supports it. This plugin supports Basic authentication, including over HTTPS. Digest-only servers are currently unsupported.

Zotero's current plain ZIP entry names and older `%ZB64` entry names are both supported. The plugin reads the attachment's checksum from the Web API and verifies the extracted main file; it does not upload files or update WebDAV `.prop` metadata. The device needs an `unzip` command supporting `-p`.

### Manual configuration

If you do not want to type in the account credentials on your E-Reader, you can also edit the settings file directly.
Edit `<KOReader data directory>/zotero/meta.lua` and supply the needed values. The data directory varies by device/platform.
```lua
-- we can read Lua syntax here!
return {
    ["api_key"] = "", -- API secret key
    ["user_id"] = "", -- API user ID, should be an integer number
    ["webdav_enabled"] = false,
    ["webdav_url"] = "", -- URL to WebDAV zotero directory
    ["webdav_user"] = "",
    ["webdav_password"] = "",
}
```

## Cache and upgrades

After upgrading from the old implementation, run **Synchronize** once. The plugin rebuilds metadata using a full sync, then uses incremental updates. Metadata and its version are saved together in `zotero/library.json`; each PDF/EPUB has an independent directory at `zotero/storage/<userID>/<attachmentKey>/`.

Old `items.json`, `collections.json`, downloaded documents and their KOReader sidecars are left in place. Old downloads are not reused automatically because their shared directories/version files cannot reliably identify the cached attachment; the first open downloads and verifies a new copy. Existing reading progress stays with the old path, so it is not transferred automatically to that copy. An explicit full resync retains the last good metadata snapshot until the replacement sync succeeds.

Changing the user ID or API key invalidates the current metadata snapshot and starts a full sync for the configured account. Linked files/URLs, group libraries, local API access and annotation uploads are currently unsupported. This is a read-only plugin.

The local metadata cache keeps the fields used for browsing, searching and downloading. Note HTML, annotation text, abstracts and unused API links are discarded locally; object keys, versions, collection parents and attachment checksums remain available. Zotero itself is unchanged. Existing large snapshots are converted one record at a time on their first load, and already loaded metadata is reused across reader initialization. A cold **Browse** displays a loading message before reading the cache.

### One-way PDF annotation sync

**Synchronize** and **Resync entire collection** update annotations for downloaded PDFs only. For one PDF, use **Browse → long-press attachment → Refresh annotations**. **Maintenance → Refetch downloaded PDF annotations** forces a refresh of all downloaded PDFs. Close and reopen the PDF to apply updates.

The first plugin open fetches a missing annotation cache. Later opens from Browse, Recent books and the file manager use it offline; reopening alone does not fetch cloud changes. Independent local annotations, bookmarks and reading progress are preserved. Local edits or deletions of imported entries reset on reopen. No annotations are uploaded or written into the PDF.

**Browse → long-press PDF → Delete local file** removes the local PDF, annotation cache, bookmarks and reading progress after confirmation. Close an open PDF first. Its Zotero entry remains available for downloading again; cloud data is kept.

Target: **Kindle Oasis 3 / official KOReader v2026.03 and v2026.07.2**, standard PDF pages. Highlights, underlines and area annotations include colors, text and comments; areas show a border and a comment on tap. Reflow hides imported overlays. EPUB annotations, notes, ink, unusual CropBoxes and intrinsic page rotation are unsupported. See [批注同步说明与验证记录](docs/annotation-sync.md) for details and device validation status.

### Download and synchronization progress

Downloads show the bytes actually received, followed by extraction, verification and saving when needed. The transfer counter starts again for each redirect response; WebDAV counts the ZIP bytes received. No download percentage or ETA is shown because a reliable total size is not available while streaming.

Synchronization shows the current stage (account, items, collections, deletions, saving) and the number of objects processed. If Zotero supplies `Total-Results`, the current items/collections stage also shows its total and percentage; this is the current query's progress, including incremental updates, rather than a percentage for the whole sync. Counts restart if a changed library requires a retry.

The sync result stays visible until dismissed, even in KOReader's silent mode. Failure messages identify the account check or the failed items/collections page. Successful results report cached library objects, collections and visible PDF/EPUB attachments separately. **Browse** lists collections and PDF/EPUB attachments; ordinary bibliographic records supply attachment labels but are not separate entries. A successful sync can therefore have library objects while **All Items** shows no results. Metadata synchronization uses `api.zotero.org`; WebDAV is only used to download attachments.

The browser starts with top-level collections and an **All Items** shortcut. Opening a collection shows its immediate subcollections and attachments; the title identifies the current collection. **All Items** shows all visible PDF/EPUB attachments and has its own title. Returning restores the previous view, including after a screen resize, and reopening **Browse** starts at the root.

Publications with several visible attachments appear once, with a file count and the number of downloaded files on the right. Tap to choose an attachment by its title, filename and PDF/EPUB format; a publication with one attachment still opens directly. Collections, **All Items** and search results use this grouping. Separate Zotero parent records remain separate even if their titles match. Attachments with identical names have stable numbered entries; long-press shows the complete document title, attachment title, filename, status, local size, file modification time (when available), DOI and attachment key. The details view also has an **Open** button. Naming attachments “Main text”, “Supplementary material” or their version in Zotero makes the choice clearer; the plugin does not infer their role or delete duplicates.

**Downloaded** means the nonempty local file and its cache receipt pass the same checksum/version metadata check used when opening it. **Update available** means a local file exists but cannot be reused for the current attachment metadata. Files with no usable local copy show only their format. Status is checked when rows are rendered, using file attributes and the small cache receipt, without network requests or hashing whole PDFs. Newly downloaded or removed files are reflected when the list is displayed again. The new attachment labels include Simplified Chinese translations for KOReader's Chinese interface.

Metadata requests use KOReader's 10-second socket blocking timeout and file downloads use its 15-second blocking timeout. Neither has a fixed overall duration limit: a large metadata page or a slow PDF/EPUB or WebDAV ZIP can continue while data arrives. Transient metadata timeouts, closed connections, short responses and HTTP 502/504 responses are retried up to three attempts for the same page. Earlier pages are not fetched again for a connection retry, and partial responses are never merged into the snapshot. A file socket timeout reports how many bytes were received; failed partial downloads are removed and existing cached files are preserved.

Downloads check the received length against `Content-Length` before extraction. If a short response supplies a strong ETag, the plugin makes up to three continuation requests using `Range` and `If-Range`, validating the returned range and ETag before appending. A full response replaces the partial copy if the server ignores the range. Incomplete or inconsistent responses fail with a specific message and retain the existing cached attachment.

WebDAV extraction errors include the `unzip` diagnostic. A corrupt downloaded ZIP is downloaded again once; missing filenames and unsupported extraction commands are reported without an automatic retry. The latest failed extraction saves `zotero/download-error.log` and `zotero/.zotero-failed-download.zip`, even if the retry succeeds. These files contain the diagnostic and attachment data, and can be used to investigate a device-specific failure. A later extraction failure replaces them.

Progress updates use KOReader's regional `ui` refresh mode at most once every two seconds, including stage changes. Unchanged text causes no refresh, and fast operations may finish before an intermediate update is shown. There is no animated spinner: while waiting for the server, the last count remains visible until more data arrives or the request times out. The dialog stays open until the operation finishes or fails. This cadence is a conservative choice for Kindle e-ink screens; physical refresh and ghosting still need checking on the target device. Refresh handling follows [KOReader's UIManager](https://github.com/koreader/koreader/blob/master/frontend/ui/uimanager.lua).

Protocol details and official source links are recorded in [Zotero API audit](docs/zotero-api-audit.md).

## Development tests

From the repository root, run:

```sh
lua tests/run.lua
# or: luajit tests/run.lua
# or, with Pandoc's embedded Lua: pandoc lua tests/run.lua

# Optional checks with a real JSON parser and KOReader v2026.03 Lua modules:
pandoc lua tests/json-integration.lua
pandoc lua tests/koreader-integration.lua /path/to/koreader/frontend
pandoc lua tests/localfiles-integration.lua /path/to/koreader/frontend/docsettings.lua
```

The offline suite uses KOReader/HTTP/JSON/crypto test doubles, real temporary files and real `unzip` operations. It requires no account credentials or network access. JSON and digest test doubles exercise protocol decisions, not the correctness of those external libraries. Live Zotero and WebDAV checks are recorded in the API audit; the computer transport adapters do not validate Kindle's LuaSocket/TLS or screen/input behavior.
