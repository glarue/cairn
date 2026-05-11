# Support

_Last updated: 2026-05-11_

`cairn` is an iOS app and command-line tool that reconciles your iPhone photo library against an [Immich](https://immich.app) server you run or control. When you delete a photo on your phone, `cairn` moves the matching asset on your Immich server to its Trash.

This page is the support resource for the iOS app.

## Get help

Email **cairn-ios@proton.me** for support, bug reports, or feature requests. Include:

- the build number you're running (Settings → About cairn)
- your iOS version
- a short description of what you tried and what happened

Replies typically come within a few days.

## Common questions

### Where do I get an Immich server?

`cairn` is a companion to a self-hosted Immich server. If you don't already run one, start with the official [Immich getting-started guide](https://immich.app/docs/overview/quick-start). `cairn` is not affiliated with Immich.

### What happens when I delete a photo on my iPhone?

1. iOS reports the deletion to `cairn` through its public PhotoKit change-log API.
2. On the next sync, `cairn` checks whether the photo also exists on your Immich server (matched by SHA1 hash).
3. If it does, the matching asset is moved to your server's Trash — not hard-deleted. You have 30 days to restore it from Immich's own Trash view.

### How do I undo a sync?

Every sync run is tagged on Immich with `cairn/v1/run/<id>`. To undo, open `cairn` → Runs → tap the run → Restore. The assets move back out of Immich's Trash into your active library.

### `cairn` says "Couldn't reach Immich" — what now?

The server is unreachable (offline, wrong URL, VPN dropped, certificate expired). `cairn` doesn't lose any work — your decisions are queued and replayed when the connection returns. If you're sure the server is online, double-check the URL in Settings → Immich server.

### Why does `cairn` need Full Photos access?

To detect deletions and compute SHA1 hashes that match the ones your Immich server stores. `cairn` reads photo bytes only long enough to compute the hash, then discards them — they never leave your device. See the [privacy policy](PRIVACY.html) for the full data flow.

### How do I delete `cairn` and its data?

Uninstalling the app removes all on-device data (credentials, hash cache, journal, settings). Photos on your Immich server are untouched.

## Source code

`cairn` is open source under the MIT license. The repository lives at [github.com/glarue/cairn](https://github.com/glarue/cairn). A GitHub account is not required for support — please email instead.

## Privacy

See the [privacy policy](PRIVACY.html) for what `cairn` does and doesn't do with your data.
