# Self-hosting Voicepad

Voicepad is a single-user, experimental dictation server. Run one instance with one worker. It accepts one active transcription at a time; a second receives a busy response. It is not designed for shared hosting or multi-tenant isolation.

## Trust boundary first

**Voicepad has no application user authentication or separate administrator role.** Every permitted network peer can read/write profiles, use the connected account's quota, start sign-in, test refresh, or disconnect the account. Same-origin checks, trusted Host checks, and custom mutation headers help against cross-site browser requests; they do not authenticate a caller.

Keep the published port on loopback. If you allow remote access, a trusted private network and restrictive Tailscale ACLs or equivalent network policy are mandatory. Only permit people/devices you would trust with administration and account usage. Do not publish this server through a router port-forward, public reverse proxy, Tailscale Funnel, or public tunnel. This deployment is **not safe for public internet exposure**.

## Requirements

- Git and Bash.
- Docker Engine on Linux, or Docker Desktop on macOS, with Compose v2 (`docker compose`).
- A provider account that can complete the experimental Codex device flow. Availability is not guaranteed by a subscription or by this project.
- For remote browser recording: HTTPS. Plain HTTP on another machine's LAN address does not satisfy browser microphone requirements; localhost is the local-development exception.

## Install locally

```sh
git clone https://github.com/Souptik2001/voicepad.git
cd voicepad
bash scripts/setup.sh
docker compose up --build -d
```

Open http://localhost:8791/admin, connect Codex, then open http://localhost:8791/ to record. Docker installs ffmpeg in the image; you do not need a host Python or Node installation for this path.

### Configuration

`.env` is optional to Compose; `.env.example` documents its inputs. The setup script creates an initial `.env` if absent, sets `VOICEPAD_UID`/`VOICEPAD_GID` from `id`, and prepares the private state directory owned by the invoking user. It should be run as your normal user, not with `sudo`. On macOS, Docker Desktop handles the host-to-container bind mount; keep the project/state directory in a location Docker Desktop can share.

| Variable | Default | Meaning |
| --- | --- | --- |
| `VOICEPAD_PORT` | `8791` | Host loopback port; container port stays `8791` |
| `VOICEPAD_DATA_DIR` | `./data` | Host directory mounted read/write at `/data` |
| `VOICEPAD_PUBLIC_ORIGIN` | `http://localhost:8791` | Exact browser origin, with scheme/host/optional port, no path or trailing slash |
| `VOICEPAD_UID` / `VOICEPAD_GID` | `1000` / `1000` | Container runtime and tmpfs owner; setup records the invoking user's IDs in a new `.env` |

`VOICEPAD_STATE_DIR=/data` is the container's internal state location. Compose builds the local image `voicepad:local` and publishes `127.0.0.1:${VOICEPAD_PORT:-8791}:8791`.

The bind mount has `create_host_path: false`: the directory must exist before startup. Setup creates it; do not work around a missing/unwritable directory by making it world-writable or running the application as root. For a custom `VOICEPAD_DATA_DIR`, prepare that directory with mode `0700` and ownership matching the configured UID/GID. Preserve existing state when changing paths. If `.env` already exists, review its UID/GID and path values rather than assuming setup replaced them.

If you change the host port, also change `VOICEPAD_PUBLIC_ORIGIN` to match the URL you actually use. For example, port `8891` on this machine needs `http://localhost:8891`. Editing `.env` requires container recreation, not merely `docker compose restart`:

```sh
docker compose up -d --force-recreate
```

The default container has a read-only root filesystem, non-root runtime user, dropped capabilities, `no-new-privileges`, a 64 MiB noexec/nosuid tmpfs, and limits of 512 MiB memory, 2 CPUs, and 64 PIDs. Only `/data` is a persistent writable application mount. These hardening measures are not a substitute for access control.

## Connect the provider

1. Open `/admin` and choose **Connect Codex**.
2. Follow the official `https://auth.openai.com/codex/device` link and enter Voicepad's displayed device code there.
3. Sign in and approve on OpenAI's site. Do not enter an OpenAI password or token in Voicepad.
4. Wait for connected status. If OpenAI requires it, enable device-code login in your ChatGPT security settings and begin a fresh login.

Pending login expires after 15 minutes and is discarded on server restart. A completed grant persists in `oauth.json`; Voicepad does not import or modify CLI or other applications' credentials. Refresh runs automatically. **Test token refresh** performs a real refresh-token rotation; it is not an offline simulation. A rejected or revoked grant requires reconnecting.

**Disconnect** removes Voicepad's local grant and pending login. It does not promise to revoke all OpenAI sessions. Manage provider-side grants/security separately when necessary.

The two provider endpoints are experimental internal OpenAI endpoints, not a supported public API contract. Voicepad never falls back to a paid API key. That does not establish free/unlimited usage, a particular allowance, or permission to redistribute/resell access. Check the provider's current terms yourself.

## Private HTTPS with Tailscale

Keep Compose bound to loopback. Install/connect Tailscale on the server and intended clients, configure restrictive ACLs, and inspect any existing Serve routes before adding Voicepad:

```sh
tailscale serve status
tailscale serve --bg http://127.0.0.1:8791
tailscale serve status
```

Serve may prompt you to enable HTTPS for your tailnet. The command above serves Voicepad at the **root** of the displayed private HTTPS URL. Do not overwrite another application's existing root handler; use a deliberate separate routing arrangement instead. Do not enable Funnel.

Copy the displayed HTTPS origin into `.env`, for example:

```dotenv
VOICEPAD_PUBLIC_ORIGIN=https://voicepad.your-tailnet.ts.net
```

Use the actual origin, not the example hostname, then apply it:

```sh
docker compose up -d --force-recreate
```

Open the HTTPS URL from an allowed device, test `/admin`, assets, microphone permission, and a nonsensitive recording. Keep ACLs restricted: Tailscale encryption alone does not limit which tailnet peers may administer Voicepad. Local browser requests with `Origin: http://localhost:8791` will no longer match after switching to the HTTPS origin; use your configured HTTPS address for the UI.

For a nondefault host port, change the Serve target too. A successful loopback health check does not prove remote HTTPS routing or microphone capture works.

### Optional path prefixes

The default is `/`, with `/admin`, `/profiles`, and `/usage` below it. There is no default `/voicepad/` mount. If you deliberately use a prefix, the reverse proxy must strip it before forwarding: public `/voicepad/api/status` must reach backend `/api/status`. Preserve the public Host and test all assets/API routes. Use a trailing slash for the recorder base URL, such as `https://voicepad.your-tailnet.ts.net/voicepad/`; use that full base in the native client too. `VOICEPAD_PUBLIC_ORIGIN` still contains only the origin, never `/voicepad`.

## Check the deployment

The verifier uses Python's standard library and is run from the repository root. Always supply `--base` explicitly, including its trailing slash:

```sh
python3 verify_deployment.py --base http://localhost:8791/
# Or, from an allowed tailnet device:
python3 verify_deployment.py --base https://voicepad.your-tailnet.ts.net/
```

By default it checks HTTP pages/assets, public status, and rejection of mutations without the custom header. It does **not** perform a real provider refresh or transcription, and does not establish recognition quality.

After completing your own login, you can explicitly exercise the provider:

```sh
python3 verify_deployment.py --base https://voicepad.your-tailnet.ts.net/ \
  --require-connected --refresh --transcribe ./spoken-test.wav
```

Use a short, nonsensitive spoken WAV. This rotates real credentials, uploads audio, consumes unknown provider allowance, and prints the returned transcript. Do not publish its output without review. A mocked test suite or `/healthz` response is not proof of live provider availability.

## Persistent data and backups

The host state directory contains:

| File | Contents |
| --- | --- |
| `oauth.json` | OAuth access/refresh tokens, account identifier, expiry/refresh/reconnect metadata |
| `profiles.json` | Profile names and instructions |
| `metrics.json` | Numeric audio/request aggregates, not transcripts |
| `formatting-metrics.json` | Separate text-formatting counters and reported tokens |

State files are written atomically with mode `0600`; protect the directory with mode `0700`. They are not encrypted by Voicepad. Restrict host access and encrypt backups. Never commit `.env`, state files, recordings, or credential-bearing logs.

Stop the container before a consistent backup or restore. Copy the entire configured state directory to private backup storage, preserving modes/ownership. Restore it while stopped, verify ownership against `VOICEPAD_UID`/`VOICEPAD_GID`, then start the container. Do not run multiple instances against one state directory: locks and aggregation are process-local.

Recordings/transcripts are not server history. Default server decode files are transient tmpfs files. Client and provider retention differ; see [architecture and retention](architecture.md#data-and-retention). Metrics are local estimates, not provider billing records; a missing token/cost field means unknown, not free.

## Update and stop

Before updating, back up state and review changes. After updating your checkout:

```sh
docker compose up --build -d
python3 verify_deployment.py --base http://localhost:8791/
```

Use your configured HTTPS base instead if that is the intended access path. Stop without deleting state:

```sh
docker compose down
```

Compose shutdown does not remove the host bind directory or Tailscale's Serve route. If removing a Serve handler, remove only the handler you created; do not reset unrelated routes. State deletion and provider-side revocation are separate, explicit actions.

## Troubleshooting

- **Bind mount missing / permission denied:** rerun setup as your normal user, inspect the configured directory and numeric UID/GID, and ensure Docker Desktop can share the path. Do not use `chmod 777`.
- **Origin rejected / invalid Host:** compare the actual browser origin with `VOICEPAD_PUBLIC_ORIGIN`; remove any path/trailing slash, include the correct port, and recreate the container. Do not disable the checks.
- **Microphone unavailable:** use localhost or private HTTPS, grant browser permissions, and check MediaRecorder support. Browser-selected codecs differ; test your actual browser/device. File upload can help isolate capture from decoding.
- **Busy / rate limited:** wait for the active upload to finish. Do not add workers to bypass the single-process design. A provider 429 is distinct from a local busy/rate rejection.
- **Reconnect required / blocked:** start a fresh Codex connection, check device-login settings, and recognize that internal endpoint availability can change. No paid fallback is used.
- **Metrics/profiles storage unhealthy:** preserve the original files and investigate permissions or corruption. Do not silently reset or overwrite data to make a warning disappear.

Use `docker compose logs --tail=100 voicepad` for diagnostics, but inspect and redact output before sharing. For vulnerabilities, follow [SECURITY.md](../SECURITY.md), not a public bug report.
