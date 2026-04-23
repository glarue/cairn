# Privacy Policy

_Last updated: 2026-04-23_

`cairn` is a tool for reconciling your iPhone photo library against an [Immich](https://immich.app) server that you run or control. This policy describes what `cairn` does and doesn't do with your data.

## Summary

- **`cairn` does not collect any data about you.** No analytics, no crash reporting, no telemetry, no ads.
- **`cairn` does not operate any servers.** There is no "`cairn` cloud." The iOS app runs on your device; the CLI runs on your computer.
- **`cairn` only talks to your Immich server.** All network traffic goes to the server URL you configure, authenticated with the API key you provide.
- **Your credentials stay on your device.** The Immich server URL and API key live in the iOS Keychain on iPhone, or in a `.env` file on your computer for the CLI.

## What `cairn` accesses

- **Your Photos library.** `cairn` requires **Full Photos access** to enumerate your library and detect deletions. It reads photo metadata (identifiers, creation dates, file size, Live Photo pairing) and downloads photo bytes temporarily in order to compute a SHA1 checksum — the same identifier Immich uses. Photo bytes are hashed in memory and discarded; they are never uploaded anywhere, cached long-term, or copied off-device.
- **PhotoKit persistent changes.** `cairn` subscribes to iOS's `PHPhotoLibrary.fetchPersistentChanges(since:)` so it receives a direct signal when you delete a photo. The change log is provided by iOS; `cairn` stores only a token and the checksums it has resolved.
- **Background App Refresh (optional).** If granted, iOS occasionally wakes `cairn` to process new deletion events. Nothing leaves your device during a background run other than requests to your own Immich server.

## What `cairn` stores on your device

All of this is local to your device. Nothing is synchronized to a cloud account or a third party.

- **Credentials** — your Immich server URL and API key, in the iOS Keychain.
- **SHA1 hash cache** — a local index mapping your iPhone's asset identifiers to their SHA1 checksums, so `cairn` doesn't re-hash every photo on every run.
- **Ever-seen set** — every SHA1 `cairn` has observed on this device. Used to distinguish "you deleted this" from "this was never yours."
- **Confirmed-deleted set** — SHA1s that iOS has reported as deleted, plus the timestamp, used to drive the quarantine window.
- **Deletion journal** — an append-only JSONL file recording every reconcile run (planned, tagged, trashed, restored, failed). For forensics and undo.
- **Exclusion list** — checksums you've explicitly protected from future runs.
- **App settings** — your thresholds, quarantine window, appearance preference, etc.

You can wipe any of this from Settings → Danger zone (Reset index / Clear journal / Sign out of server) or by deleting the app.

## What `cairn` sends over the network

Only requests to your configured Immich server, signed with your API key:

- `POST /api/search/metadata` — list assets and their checksums.
- `GET /api/assets/statistics` — fast count endpoint.
- `POST /api/tags` + `PUT /api/tags/assets` — write run breadcrumbs.
- `DELETE /api/assets` with `force: false` — move asset(s) to your Immich Trash (not permanent deletion).
- `POST /api/trash/restore/assets` — undo.
- `GET /api/thumbnail/<id>` — fetch thumbnails for the candidate review UI.

`cairn` does not contact any other host. There is no "`cairn` backend," no third-party SDK, no analytics endpoint, no remote configuration. Your Immich server is the only thing `cairn` talks to.

## What `cairn` does **not** do

- No analytics or telemetry (no Firebase, Mixpanel, Amplitude, App Center, Sentry, nothing).
- No crash reporting sent to a third party. Apple's standard on-device crash logs are available to you through the iOS Settings app and may be shared with Apple under your system-level privacy settings — `cairn` itself doesn't opt you into anything additional.
- No ads or ad identifiers.
- No tracking across apps or websites.
- No account system.

## Data retention and deletion

- Data stays until you remove it.
- **Uninstalling `cairn`** removes the iOS Keychain entries, the on-device stores, and the journal. (Apple deletes app-sandbox data on uninstall.)
- **Settings → Sign out of server** removes credentials from Keychain but preserves the indexed state for when you sign back in.
- **Settings → Reset index** wipes the SHA1 cache, ever-seen set, and quarantine state. Credentials and exclusions are preserved.
- **Settings → Clear journal** deletes the deletion-journal.jsonl file from disk.

Data stored on your Immich server is governed by your Immich server, not by `cairn`.

## Children

`cairn` is not directed at children under 13. It doesn't collect personal information from anyone, so there's nothing special to say here.

## Changes

If this policy changes in a way that affects you, the change will be called out in [`CHANGELOG.md`](CHANGELOG.md) alongside the release that introduced it, and the "Last updated" date at the top of this file will change.

## Contact

For privacy questions, file a GitHub issue on the `cairn` repository. For security concerns, see [`SECURITY.md`](SECURITY.md) — use private security advisories rather than public issues.
