# Security policy

Voicepad is experimental software for personal self-hosting. There is no security SLA or commitment to maintain older releases. Use the latest source, review updates, and keep the host, Docker, Python dependencies, ffmpeg, browsers, and native toolchain patched.

## Reporting a vulnerability

Do not put vulnerability details, exploit instructions, credentials, private recordings, or transcripts in a public issue.

1. Visit [the repository Security page](https://github.com/Souptik2001/voicepad/security). If GitHub offers **Report a vulnerability**, use that private reporting flow. Availability depends on the repository's settings; this document does not claim it is enabled.
2. If no private reporting option is available, open a **non-sensitive** issue asking maintainers to arrange a private reporting channel. Do not include the vulnerable endpoint, reproduction, or sensitive evidence until a private channel is established.

In a private report, include the affected revision, deployment boundary, expected versus actual behavior, reproduction steps, and impact. Use nonsensitive sample content. Do not send real tokens or passwords; redact them from logs and screenshots.

Please allow time for coordination before public disclosure. No response or fix deadline is guaranteed.

## Deployment boundary

**There is no application user authentication or authorization separation.** All peers allowed to reach Voicepad can read/write profiles, use transcription and the connected account's allowance, and use administrative controls—including sign-in, refresh, and disconnect. It is not multi-tenant software.

- Keep the default `127.0.0.1` port publication.
- Remote access requires a trusted private network and restrictive ACLs or equivalent network policy. Tailscale Serve provides private HTTPS, not application roles. Treat every allowed peer as an administrator.
- Do not expose Voicepad to the public internet through port forwarding, a public reverse proxy/tunnel, or Tailscale Funnel.
- Do not remove Origin/Host validation, cross-site rejection, or custom mutation-header checks to fix routing. These are browser-request safeguards, not user authentication.
- Run one instance/worker. Process-local locks and counters do not coordinate replicas sharing a state directory.

## Sensitive data

The persistent state directory holds OAuth access/refresh credentials and account metadata, profile names/instructions, and numeric usage counters. It is not encrypted by the application. Keep directory mode `0700`, files `0600`, correct ownership, restricted host access, and encrypted private backups. Never commit `.env` or state files, and do not attach them to issues.

The server keeps no recording/transcript history; its default temporary audio storage is tmpfs. Clients also use transient recording data: browser-managed codec/buffering/storage can differ, and the Mac recorder uses a temporary file before loading audio into memory. Failed Mac uploads remain in RAM for explicit Retry for at most two minutes. The Mac last transcript remains in app memory for Copy, not a persistent history. Copy/paste, clipboard managers, destination applications, swap, crashes, and OS behavior are separate retention boundaries; this is not a secure-erasure promise.

Audio is sent to OpenAI's experimental internal transcription endpoint. Optional profile formatting sends transcript text and profile instructions to its internal Codex responses endpoint. Observed audio responses reported `asset_ttl: "30d"`; this is a provider-reported asset lifetime, not a full privacy, retention, or deletion guarantee. Formatting's `store:false` is not a blanket retention guarantee either. Avoid sensitive recordings unless you have independently assessed provider terms and risk.

A separate Codex OAuth grant is created for Voicepad. Disconnect removes its local grant, not every provider session. If credentials are exposed, restrict service access, use provider-side account security/revocation controls, reconnect as appropriate, and treat affected backups as sensitive. Do not assume deleting the local JSON revokes a leaked refresh token.

## Native client permissions

Grant microphone access only to a build you trust. Input Monitoring enables global double-Command detection; Accessibility enables guarded paste and global profile-number suppression. The app is source-built with a local ad-hoc signature, not an official signed/notarized release. Do not disable Gatekeeper globally to run it. Recording and explicit Copy remain available without Accessibility; test insertion behavior in each target app.

## Provider and license limits

OpenAI's `/backend-api/transcribe` and `/backend-api/codex/responses` endpoints are experimental internal interfaces, not a public API compatibility commitment. There is no paid API fallback. The project makes no guarantee of subscription entitlement, free/unlimited use, commercial rights, or continued access and is not affiliated with OpenAI. MIT covers this source code; it does not override provider terms or third-party licenses.
