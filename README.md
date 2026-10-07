# Zotero for KOReader

This addon for [KOReader](https://github.com/koreader/koreader) allows you to view your Zotero collections.

> [!NOTE]
> **Beta version**! Please report bugs, pull requests are welcome.

<div align="center"><img width="600" alt="Screenshot of this plugin displaying a list of papers alongside a search button" src="https://raw.githubusercontent.com/stelzch/screencasts/main/zotero-koplugin-screenshot.png"></div>

## Features
* Synchronize a personal library via Zotero Web API v3, including trash and permanent deletions
* Display collections, navigate to sub-collections
* Download & open stored PDF and EPUB attachments (`imported_file` and `imported_url`)
* Supports Zotero File Storage and WebDAV storage with Basic authentication
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

Protocol details and official source links are recorded in [Zotero API audit](docs/zotero-api-audit.md).

## Development tests

From the repository root, run:

```sh
lua tests/run.lua
# or: luajit tests/run.lua
```

The offline suite uses KOReader/HTTP/JSON/crypto test doubles, real temporary files and real `unzip` operations. It requires no account credentials or network access. JSON and digest test doubles exercise protocol decisions, not the correctness of those external libraries. KOReader device integration and live Zotero/WebDAV interoperability still need separate validation.
