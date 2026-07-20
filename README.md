# notion-frameio-sync

macOS menu-bar app that closes the client-review loop for a video studio:

**Dropbox exports → Frame.io → Notion, and comments back again.**

- Watches the studio's Exports folder tree; new deliverables upload to
  Frame.io (V4 API) automatically, organized into per-client/per-project
  folders with version stacks for revisions
- Posts the Frame.io share link back to the project's page in Notion
- Polls uploaded files for **new client comments** and turns each into a task
  in a Notion Tasks database — title, project relation, deep link to the
  player, full comment with author and timecode in the body. Replies and your
  own comments never become tasks; everything is idempotent via a local
  SQLite ledger
- Provisions folder structures for newly activated Notion projects

## Requirements

macOS 14+. A Frame.io (Adobe) OAuth client ID and a Notion integration token —
both live in `~/Library/Application Support/ExportsSyncer/config.json`,
never in this repo.

## Build

```bash
swift build && ./build.sh
```

---

Built by [Index Video Production](https://indexvideoproduction.com) with Claude Code.
