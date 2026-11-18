# Voicepad

Personal, self-hosted dictation for the web and macOS. Record a thought, get text back, and optionally format it with your own instructions.

Voicepad runs a small Python server with a browser recorder, account administration, nine custom dictation profiles, and usage metrics. The native Mac menu-bar client adds global recording shortcuts, profile selection while speaking, and guarded paste into the current text field. There is **no native iOS app or keyboard yet**; compatible mobile browsers can use the web recorder.

> **Experimental provider integration.** Voicepad uses OpenAI's internal `/backend-api/transcribe` and `/backend-api/codex/responses` endpoints through an independent Codex OAuth login. These are not stable public APIs. Access, models, quotas, and behavior can change without notice. There is no paid API fallback, and no promise of free or unlimited subscription use or commercial-use rights. Voicepad is not affiliated with or endorsed by OpenAI.

## What it does

- **Web dictation:** click Start/Stop, hold Space outside editable controls, or upload a supported audio file. Microphone capture starts only on an explicit action.
- **Bounded recordings:** up to **10 minutes / 25 MiB** per upload. The web UI labels the size limit “25 MB.”
- **Nine numbered profiles plus Raw:** manage names and instructions on the website; select a profile in the Mac client. Empty instructions skip formatting. The web recorder currently uses Raw.
- **Recoverable formatting:** an optional text-only model call applies profile instructions; if it fails, the raw transcript is returned with a warning. Review generative edits before using important text.
- **Independent account connection:** device-code sign-in and automatic refresh, without importing another app's OAuth credentials.
- **Local usage metrics:** request counts, audio duration, processing time, and separately reported formatting tokens—not a subscription quota or billing dashboard.

One server process, one worker, one active transcription. This is a personal tool, not a multi-tenant service.

## Quick start

You need Git, Docker with Compose v2, and Bash. Linux Docker Engine and macOS Docker Desktop are supported deployment paths.

```sh
git clone https://github.com/Souptik2001/voicepad.git
cd voicepad
bash scripts/setup.sh
docker compose up --build -d
```

Open **http://localhost:8791/admin** and choose **Connect Codex**. Follow the displayed link to `https://auth.openai.com/codex/device`, enter the displayed device code there, and complete authorization on OpenAI's site. If device authentication is disabled, enable device-code login in your ChatGPT security settings and start again. Never paste passwords, tokens, or two-factor codes into Voicepad or a GitHub issue.

Once connected, open **http://localhost:8791/**, grant microphone permission, and try a nonsensitive sentence. Other pages:

| Page | Purpose |
| --- | --- |
| `/admin` | Connect, refresh, or disconnect Voicepad's account grant |
| `/profiles` | Edit nine fixed profile slots |
| `/usage` | Inspect local aggregate metrics |
| `/healthz` | Basic HTTP health check; not a provider readiness test |

The setup script creates a private local state directory and an initial `.env` from `.env.example`, including your host UID/GID. Compose defaults to `127.0.0.1:8791`, not a public interface. See [self-hosting](docs/self-hosting.md) for configuration, HTTPS, backups, and troubleshooting.

### Access from another device

**There is no application user authentication.** Every peer allowed to reach Voicepad can read and change profiles, use dictation and account quota, and operate administration—including disconnecting the account. Origin checks are not a login system. Keep the default loopback binding, or use a trusted private network with restrictive access rules. **Do not expose this service to the public internet.**

For private remote access, use Tailscale Serve with ACLs restricted to your intended devices:

```sh
tailscale serve --bg http://127.0.0.1:8791
```

Copy the HTTPS origin shown by Serve into `.env` as `VOICEPAD_PUBLIC_ORIGIN` (scheme, host, and port if present; **no path or trailing slash**), then recreate the container:

```sh
docker compose up -d --force-recreate
```

Browse that HTTPS URL. Remote browser microphone access requires HTTPS; localhost is the development exception. The default setup serves at `/`, not `/voicepad/`. See [private HTTPS setup](docs/self-hosting.md#private-https-with-tailscale) before changing existing Serve routes.

## Mac client

Build from source on macOS 13+ with Apple developer tools providing Swift 5.9+:

```sh
git clone https://github.com/Souptik2001/voicepad.git
cd voicepad/clients/macos
VOICEPAD_SERVER_URL='https://voicepad.your-tailnet.ts.net/' bash scripts/build.sh
```

Use your own private server URL. The build default is `http://localhost:8791/`; a path-prefixed URL is optional only with a correctly configured prefix-stripping proxy. The script compiles directly with `swiftc` and produces `dist/Voicepad.app` for the current Mac's CPU, with a local ad-hoc signature—not an official signed or notarized release. Install the built app in Applications and grant microphone access. Input Monitoring enables double-Command detection; Accessibility enables guarded paste and global profile-number selection. Copy works without Accessibility.

The default shortcut is double-tap the same Command key to start, then double-tap again to stop. Hold-to-record alternatives and menu controls are also available. See the [Mac client documentation](clients/macos/README.md) for permissions, paste safeguards, and real-device acceptance checks. Portable core tests do not prove that an Apple SDK build or editor integration works.

## Privacy and limits

Audio leaves your machine: the client sends it to your server, which sends normalized audio to OpenAI. Custom formatting also sends transcript text and profile instructions to OpenAI. Observed transcription responses reported `asset_ttl: "30d"`; that is a provider-reported audio asset lifetime, **not** a complete retention or deletion guarantee. Formatting requests use `store:false`, which is also not a blanket provider-retention guarantee.

The server does not keep recording or transcript history. Temporary audio is removed after processing; the default container uses tmpfs for it. Browser capture uses transient browser-managed data, and its codec/temporary-storage behavior can vary by browser. The Mac client records to temporary storage, removes the recording file after reading it, and retains failed-upload audio in RAM for explicit Retry for at most two minutes. Its last transcript remains in app memory for Copy, not a persistent history; copied or pasted content is then subject to the destination app and clipboard tools.

OAuth credentials/account metadata, profile names/instructions, and numeric metrics **are persistent** server state. Protect the state directory and backups. Transcription model identity, audio token usage, remaining subscription allowance, and actual cost are not reported; unknown does not mean zero. Read the [security policy](SECURITY.md) and [data-flow details](docs/architecture.md#data-and-retention).

## Development and contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for Python 3.11, ffmpeg, Node.js 22, and Swift setup, test commands, and deployment checks. Unit tests do not contact the real provider by default. There is no separate marketing-site build.

- [Self-hosting](docs/self-hosting.md)
- [Architecture](docs/architecture.md)
- [Report a bug](https://github.com/Souptik2001/voicepad/issues/new?template=bug_report.yml)
- [Request a feature](https://github.com/Souptik2001/voicepad/issues/new?template=feature_request.yml)
- [Report a vulnerability privately](SECURITY.md#reporting-a-vulnerability)

## License

[MIT](LICENSE), copyright 2026 Voicepad contributors. This license covers the source code; it does not override provider terms, licenses, subscription restrictions, or rights in third-party services and trademarks.
