# Architecture

Voicepad is a personal dictation application: static browser UI and a native Mac client share a single FastAPI backend. It is not a coding agent, local speech model, multi-tenant platform, or hosted dictation service.

```text
Browser recorder / Mac menu-bar client
              |
      loopback or private HTTPS
              |
     FastAPI + ffmpeg (one worker)
       |         |             |
       |         |             +-- /data: OAuth, profiles, numeric metrics
       |         +-- optional text formatting --> OpenAI Codex responses
       +-- normalized audio -------------------> OpenAI transcription

Administration --> independent device OAuth --> auth.openai.com
```

Network reachability is the access boundary. There is no application login or admin role: all allowed peers have administrative capabilities. See [self-hosting](self-hosting.md) and [SECURITY.md](../SECURITY.md).

## Components

| Component | Responsibility |
| --- | --- |
| `app.py` | HTTP routes, browser-origin guards, upload limits, audio normalization, transcription orchestration |
| `oauth.py` | Independent device-code authorization, refresh, local grant persistence, disconnect |
| `profiles.py` | Nine fixed instruction slots, validation, atomic persistence |
| `formatter.py` | Optional text-only formatting, bounded streaming response, raw fallback |
| `metrics.py` | Bounded daily/lifetime audio and request counters |
| `formatting_metrics.py` | Separate formatting calls and provider-reported token counters |
| `static/` | Recorder, administration, profiles, and usage pages; browser-native JavaScript modules |
| `clients/macos/Sources/VoicepadCore/` | Portable API, recording/session, profile, shortcut, and paste coordination logic |
| `clients/macos/Sources/Voicepad/` | AppKit UI, AVFoundation capture, global shortcuts, Accessibility/clipboard integration |
| `verify_deployment.py` | Standalone deployment checks, with real provider actions only when explicitly requested |

There is no frontend dependency bundler or separate marketing-site build. The Mac packaging script compiles directly with `swiftc`; SwiftPM provides separate portable-core tests.

## Request flow

1. An explicit client action starts capture or file upload. Browser capture uses MediaRecorder and an available codec; Mac capture uses AAC in an MP4 container.
2. The client posts audio bytes to `POST /api/transcribe` with a supported Content-Type and `X-Requested-With: voicepad`. An optional `X-Voicepad-Profile: 1` through `9` selects a saved slot. No header means Raw.
3. The server validates the request and snapshots the selected profile before sending audio. Missing/deleted/malformed slots are rejected. Only one transcription is admitted at a time, with an additional local rate limit.
4. ffmpeg decodes to mono 16 kHz signed 16-bit PCM WAV. Uploads are capped at 25 MiB and decoded duration at 1–600 seconds. Clients stop timed capture at 599.8 seconds for encoder padding. A one-second decode guard detects overlong input rather than silently returning a truncated accepted clip.
5. The backend obtains Voicepad's own OAuth credentials and sends normalized audio to `https://chatgpt.com/backend-api/transcribe`. A 401 permits one refresh and one retry; no other provider or billing route is substituted.
6. For a populated profile with nonblank instructions and nonblank transcript, the server sends transcript text and instructions to `https://chatgpt.com/backend-api/codex/responses`. Otherwise it returns raw text directly.
7. The response includes text, server processing/audio duration, optional formatting warning/usage, and provider-reported audio asset lifetime when present. Audio usage is `null` because it is unknown.

Upload and decode each have a 60-second deadline. Each audio-provider attempt has a 125-second wall-clock limit; formatting has a 45-second deadline. These are stage limits, not a promise of a short total round-trip. Client cancellation does not prove that a request already sent to the provider was cancelled there.

## Profiles and formatting

Profiles occupy fixed slots 1–9 and do not renumber after deletion. Names contain 1–60 characters; instructions allow up to 4,000 characters. Raw is separate from the nine slots. The website manages profiles, while its recorder currently stays Raw. The Mac client fetches profiles when capture begins and freezes the chosen slot at Stop for that upload and explicit Retry. A retry retains the slot number, not a historical server instruction snapshot.

Nonblank instructions add a text-only generative call using the model configured in `formatter.py`, currently `gpt-5.6-luna`, low reasoning, `store:false`, no tools, and no prior conversation history. Instructions are developer content and dictation is user content under a formatting-only system instruction. These are experimental endpoint/model identifiers, not public compatibility guarantees.

Only completed, bounded output is accepted. Failed/incomplete formatting returns the original raw transcript with a warning. This avoids losing a successful transcription, but does not make generative formatting fact-preserving: review important names, numbers, and meaning.

## Independent OAuth lifecycle

Voicepad starts a device flow through fixed OpenAI authentication endpoints and the Codex public OAuth client. The user authorizes on OpenAI's site, not by entering a password/token in Voicepad. It does not read, share, or change credentials from another agent or CLI.

Pending device state stays in memory and expires after 15 minutes. Completed grants are atomically stored in `oauth.json`. An async lock serializes login completion, refresh, and disconnect within one process. A background loop checks every 30 seconds; request-time credential acquisition refreshes within five minutes of expiry. Transient failures retain the saved grant with a cooldown; rejected grants persist a reconnect-required state.

Status responses omit tokens, account identifiers, authorization codes, and PKCE verifiers. The user-facing device code is intentionally visible while login is pending. Disconnect removes the local grant and cancels pending login; it is not a claim of provider-wide session revocation.

## Data and retention

| Location | Data and lifetime |
| --- | --- |
| Browser | Transient recording chunks and displayed transcript; no Voicepad persistent transcript history. Browser codec, buffering, and temporary-storage implementation can differ. |
| Mac temporary storage | Recording file during capture; removed after reading or cleanup. Crash/OS behavior is not a secure-erasure guarantee. |
| Mac RAM | Failed-upload audio for explicit Retry for at most two minutes; retry does not extend the retention window. Last transcript remains in app memory for Copy, not persistent history. |
| Server temporary storage | Uploaded source and normalized WAV during processing; temporary files removed afterward. Default Compose puts these in a 64 MiB tmpfs. |
| Server `/data` | OAuth credentials/account metadata, profile names/instructions, and numeric metrics persist across restarts. Files use mode `0600`; private directory mode is `0700`. No application-level encryption. |
| Provider | Audio for transcription; text and profile instructions for optional formatting. Observed audio responses reported `asset_ttl: "30d"`, a provider-reported audio asset lifetime—not a complete retention/deletion policy. `store:false` is not a blanket retention guarantee. |
| Clipboard / destination apps | Explicit Copy or automatic paste makes text available outside Voicepad; clipboard managers, OS features, and destination apps have their own retention behavior. |

Voicepad does not persist audio/transcript history on the server. This is not a claim that sensitive content never reaches disk anywhere: clients, swap/crash handling, provider systems, backups, and external clipboard tools are separate boundaries. Profile instructions may themselves be sensitive; they are deliberately persistent configuration and are sent to the provider when formatting.

### Metrics semantics

`GET /api/metrics` and `/usage` show UTC today, lifetime totals since `tracking_since`, and up to 30 recent daily entries. Audio metrics keep 366 daily buckets plus lifetime aggregates. There are no per-recording rows, transcript text, audio, or account identifiers in the aggregate files.

Request outcomes cover admitted processing; early origin/type/size/busy/rate rejections are excluded. Provider calls count attempted outbound transcription calls, including retries and failed attempts. Submitted duration counts per attempt, successful duration per successful request. Interrupted processing can leave a provider attempt without a final outcome. Processing time measures server work, not recording duration or full client latency.

Formatting tokens are separate and cover only reported text-model usage. Audio tokens, total subscription percentage, cost, and quota remain unknown—not zero. Counters span the service and connected accounts; they are not billing evidence. Storage health is surfaced; corrupt metrics are not silently reset. A metrics storage failure need not fail an otherwise successful transcription.

## Native insertion boundary

The Mac client separates capture, upload, result recovery, paste delivery, and clipboard restoration. Automatic insertion checks that the original app and editable nonsecure field remain focused. It uses clipboard plus Command+V, never presses Enter/Send, and never automatically retries an uncertain paste. Accessibility is optional for recording/Copy, but required for automatic paste and global profile-number suppression. Input Monitoring enables double-Command detection.

Clipboard restoration is best effort and conditional on Voicepad still owning it. A posted paste event is not proof of delivery; the client reports unverified delivery honestly and preserves recovery text in memory for Copy. Test actual editors on macOS: portable Swift tests cannot establish AppKit rendering, permissions, microphone capture, or Accessibility compatibility.

## Runtime constraints

Compose builds `voicepad:local`, defaults to a loopback host port, and runs a non-root process with a read-only root filesystem, writable state bind, limited tmpfs, dropped capabilities, and CPU/memory/PID limits. Setup maps the runtime and tmpfs UID/GID to the invoking user. OAuth locks, busy state, rate limits, and metrics coordination are local to the process. Multiple workers or replicas sharing state are unsupported.

Exact Origin/Host validation, cross-site rejection, custom mutation headers, no-store responses, and a restrictive content security policy reduce browser attack surface. They do not authenticate trusted peers or create tenant separation. The MIT source license does not override OpenAI terms or establish subscription entitlement, commercial-use rights, free/unlimited use, or affiliation.
