# Contributing to Voicepad

Small, focused fixes, tests, and documentation improvements are welcome. Open an issue before a large feature or architectural change. Describe the user problem and constraints, not just the proposed implementation.

Voicepad is a personal self-hosted tool, not a hosted service or multi-tenant platform. Its OpenAI integration is experimental and uses internal endpoints. Do not add a silent paid API fallback, import another application's credentials, weaken origin checks, or publish provider tokens in fixtures.

## Development setup

You need **Python 3.11**, **ffmpeg** on PATH, and **Node.js 22**. Mac-native builds additionally require macOS 13+ and Apple developer tools with Swift 5.9+. Docker/Compose is useful for deployment testing, but not required for the Python/JavaScript suites.

```sh
git clone https://github.com/Souptik2001/voicepad.git
cd voicepad
python3.11 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
```

Use the checked-in requirements, including the pinned development test dependencies. There is no npm install, frontend bundler, or separate marketing-site build: the server serves `static/` directly.

### Run a local development server

Keep development state separate from any real deployment. In your activated virtual environment:

```sh
mkdir -p .dev-data
chmod 700 .dev-data
VOICEPAD_STATE_DIR="$PWD/.dev-data" \
  VOICEPAD_PUBLIC_ORIGIN=http://localhost:8791 \
  uvicorn app:app --host 127.0.0.1 --port 8791 --no-access-log
```

Do not commit this directory, recordings, `.env`, or credentials. Check your proposed changes for private data before submitting. The server is intentionally unauthenticated, including `/admin`: keep it on loopback. Provider authorization is optional for local UI work; actual dictation requires your own independent device login.

## Tests

From the repository root with development dependencies installed:

```sh
python -m unittest discover -s tests -p 'test_*.py'
node --test tests/*.test.mjs
```

The Python tests require ffmpeg for synthetic audio. Provider behavior is injected/mocked in the unit tests; the standard suites do not establish real provider availability, account authorization, quota, recognition quality, or browser microphone behavior.

Run portable Mac-core tests separately:

```sh
cd clients/macos
swift test
```

On Linux this exercises portable code, not macOS-only AppKit, AVFoundation, Carbon, or Accessibility implementations. A passing portable suite is not a successful native build or permission test.

### Mac application build

On a Mac, from `clients/macos`:

```sh
VOICEPAD_SERVER_URL='https://voicepad.your-tailnet.ts.net/' bash scripts/build.sh
```

Use your own private base URL, including its trailing slash. Without an override, the default is `http://localhost:8791/`. The script compiles with `swiftc`, bundles `dist/Voicepad.app`, and applies a local ad-hoc signature. It does not produce an official Developer ID-signed or notarized distribution. Test from the installed Applications copy and verify microphone permission, shortcuts, profile choice, Copy, and actual text-field integration. See the [Mac README](clients/macos/README.md).

### Deployment checks

With a local instance running, from the repository root:

```sh
python verify_deployment.py --base http://localhost:8791/
```

Always provide the intended base explicitly, with a trailing slash. Default verification checks pages, status, assets, and mutation guards without real refresh/transcription calls. For deliberate live acceptance only, after completing your own login:

```sh
python verify_deployment.py --base http://localhost:8791/ \
  --require-connected --refresh --transcribe ./spoken-test.wav
```

This rotates credentials, sends the WAV to OpenAI, consumes unknown allowance, and prints transcript text. Use a short nonsensitive recording. Do not include raw provider responses, tokens, account metadata, or private audio in public reports. Test English, mixed-language speech, and noise separately; do not infer real-user accuracy from synthetic speech.

## Pull requests

- Keep scope focused and explain the behavior change and why it is needed.
- Include regression tests for fixes; cover error, cancellation, and retry paths where relevant.
- Preserve the one-worker/one-active-transcription model unless the change explicitly redesigns state coordination.
- Keep audio/transcripts out of persistent history, logs, and metrics. Treat profile instructions and OAuth state as sensitive.
- State exactly what you ran, what passed, and what remains untested. Distinguish mocked tests, deployment checks, real provider requests, and real Mac/browser acceptance.
- For UI/native changes, include sanitized screenshots or a concise reproduction without private text or hostnames.
- Update documentation when configuration, privacy, limits, or user-visible behavior changes.

No local test or badge is a substitute for checking the actual CI result on your pull request. Do not describe an initial or pending CI run as passed.

## Bugs, ideas, and security

Use the repository's [bug](https://github.com/Souptik2001/voicepad/issues/new?template=bug_report.yml) or [feature](https://github.com/Souptik2001/voicepad/issues/new?template=feature_request.yml) form. Include versions, reproduction steps, and sanitized evidence. Internal-provider changes may block a previously working setup; do not assume every failure is a local configuration issue.

**Do not disclose vulnerabilities in public issues.** Follow [SECURITY.md](SECURITY.md) for a private reporting path.

## License

Contributions are provided under the repository's [MIT license](LICENSE). Contribute only material you have the right to share. Source licensing does not grant provider-service access or override third-party terms.
