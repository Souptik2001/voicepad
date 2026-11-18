# Voicepad for Mac 0.6.2 (build 15)

Native menu-bar dictation client for a self-hosted Voicepad server. This directory contains source, not a precompiled or notarized application. See [VERIFICATION.md](VERIFICATION.md) for tested boundaries and outstanding real-Mac checks.

## Prerequisites

- macOS 13 Ventura or newer, Apple Silicon or Intel.
- Xcode or compatible Command Line Tools with Swift 5.9+, the macOS SDK, `xcrun`, `plutil`, and `codesign`. Complete any Xcode license/component setup before building.
- Python 3 (`python3 --version`), available with current Xcode Command Line Tools or a separate Python installation. Bundle configuration uses only its standard library; no pip packages are needed.
- A running Voicepad server reachable from the Mac. Start with the repository's server setup instructions. Connect your own provider account in the server's administration page if required by that provider.

There are no third-party Swift package dependencies. Local ad-hoc builds do not require a paid Apple Developer Program membership; distribution to other Macs is a separate signing/notarization concern.

## Build

From a checkout:

```sh
git clone https://github.com/Souptik2001/voicepad.git
cd voicepad/clients/macos
VOICEPAD_SERVER_URL='https://your-host/' bash scripts/build.sh
```

For a server running on the same Mac at port 8791, omit the environment variable:

```sh
bash scripts/build.sh
```

The default is **`http://localhost:8791/`**, never an Internet service. For a reverse-proxy subpath, use `VOICEPAD_SERVER_URL='https://your-host/voicepad/'`.

`VOICEPAD_SERVER_URL` is **build-time configuration**, not a runtime environment setting or preference UI. The script validates it before compilation, normalizes a missing trailing slash, and writes `VoicepadServerURL` into the staged app's `Info.plist` using Python's `plistlib`. It does not modify the source plist. Rebuild to change servers. The same bundle setting supplies API requests and the **Open Dashboard** / **Open Admin** menu actions.

URLs must be absolute HTTPS URLs, except HTTP is permitted for `localhost`, canonical `127.x.x.x` loopback addresses, and `[::1]`. Remote LAN servers also require HTTPS. Credentials/userinfo, query strings, fragments (including empty `?`/`#`), whitespace, backslashes, invalid ports and malformed percent escapes are rejected. Use ASCII hostnames (punycode for international names) and percent-encoded paths. Subpaths are preserved. An explicitly empty environment value is invalid, not a request to use the default. An absent bundle key defaults to loopback; an invalid present key fails closed.

The script compiles directly with `swiftc`, statically links the core, assembles **`dist/Voicepad.app`**, then applies and verifies a **local ad-hoc signature**. It builds only the current Mac architecture, not a universal binary. Nothing is installed automatically. A previous app is preserved if compilation or configuration fails; successful replacement moves the prior build aside. Fake-tool packaging tests prove orchestration, not Apple compilation or signing.

## Install and use

1. Quit any running Voicepad and drag `dist/Voicepad.app` into Applications. Open that copy; look for **VP** in the menu bar.
2. Use **Open Dashboard** / **Open Admin / Sign In** to inspect your configured server. The client embeds no provider credentials and does not authenticate to an Internet-facing proxy for you.
3. Allow microphone access when recording. Use **Enable Double-Command Detection…** to explicitly request Input Monitoring, then double-tap the same Command key to start and double-tap again to stop. Alternatively choose a hold-to-record Carbon shortcut or use the menu.
4. Accessibility is optional for automatic insertion and global profile number selection. Without it, click the nonactivating profile chips and use Copy. Grant permissions to the installed app, not a temporary build path.
5. If macOS blocks an ad-hoc build, inspect the per-app Privacy & Security warning and use **Open Anyway** only if you trust the source. Never disable Gatekeeper globally. Managed Macs may disallow this exception. Rebuilding can require regranting permissions.

### Audio feedback and quicker dismissal

Sound Effects are enabled by default; toggle **VP → Sound Effects** to mute them (saved on this Mac). Original, quiet upward/downward whoops mark start/stop and a soft completion cue plays only after confirmed insertion. Sounds are generated in memory; no downloads or added microphone session. The start cue precedes capture by roughly 0.2 seconds so it is not intentionally recorded; wait for Listening before speaking. Cancel/sleep/quit stop playback and invalidate delayed starts. Actual device audio latency and acoustic echo require a Mac check.

The HUD clears when pasting starts rather than covering the editor through clipboard cleanup. The neutral unconfirmed-paste notice dismisses after 0.65 seconds; detailed status and Copy Last Transcript remain in the menu. Formatting warnings and blocked-paste recovery windows remain visible so errors are not silently dismissed. The two-second clipboard safety grace is unchanged.

### Profiles and insertion safety

Manage up to nine named instruction profiles in the website's fixed slots 1–9. While recording, click a chip or use an unmodified populated slot digit; **0 Raw** is always available. Only handled profile digits are consumed while listening; unrelated keys and shortcuts pass through. Without suppression permission, the HUD reports click-only selection. Profile chips retain 32-point height and inset title drawing; no unsupported `NSButton.contentInsets` API is used.

Recording starts without waiting for the fresh profile lookup. A failed, malformed, stale or timed-out catalog clears stale selection to Raw. Selection at **Stop** controls the upload and is frozen for explicit Retry. Retry retains the slot, not a snapshot of server-side instructions. Formatting failure returns raw text with a warning alongside actual insertion status.

Automatic insertion verifies the original app and editable nonsecure field are still focused. It never reactivates another app, sends Enter/Send, or automatically retries an uncertain paste. Clipboard restoration is best-effort and preserves a newer copy. A **Paste sent** notice is not proof of delivery; check the field before recovering through **Copy Last Transcript**. Explicit Copy replaces the clipboard.

Recordings are bounded to **10 minutes / 25 MiB** (AAC capture stops at 599.8 seconds to allow encoder padding). Upload requests allow 330 seconds and the session resource cap is 360 seconds. Profiles retain a five-second lookup deadline. Transport is ephemeral, does not store credentials/cookies, and rejects redirects, including same-host redirects. Configure the final server route rather than relying on a redirect.

## Privacy and hosting boundary

Audio goes to the server selected at build time and from there to its configured provider. The default loopback URL does not make a server available; you must run one. Protect remote deployments with a trusted private network or appropriate authenticated access controls. HTTPS encrypts transport; it is not authorization. Do not expose an unprotected no-key server to the public Internet or embed secrets in the URL.

Provider account tokens stay on the server. Experimental first-party/subscription provider integrations can change or stop working and do not imply permission to resell or share subscription access. Each operator must check current provider terms and their own authorization. The app makes no model, quota, accuracy or retention guarantee. Treat failed audio retained for explicit Retry as sensitive; discard it when no longer needed. Test with nonsensitive recordings first.

## Developer checks

On macOS, from `clients/macos`:

```sh
swift test --jobs 2
python3 -m unittest discover -s tests -v
bash scripts/build.sh
```

`open Package.swift` opens the package in Xcode. The build script is the authoritative `.app` packaging path; a bare `.build` executable is not a microphone/permissions acceptance test.

Portable tests on Linux with Docker:

```sh
python3 -m unittest discover -s tests -v
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/build/home \
  --tmpfs /build:rw,exec,mode=1777,size=1g \
  -v "$PWD:/source:ro" -w /source swift:6.0.2-jammy \
  swift test --scratch-path /build/package --jobs 2
```

These exercise portable Swift logic and packaging behavior. They do **not** typecheck AppKit/AVFoundation/Carbon/Accessibility against an Apple SDK or verify microphone capture, permissions, actual signing, HUD rendering, global keys or editor insertion. Those require the real-Mac acceptance checks in VERIFICATION.md.
