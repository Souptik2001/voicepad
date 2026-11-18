# Voicepad for Mac 0.6.2 / build 15 — verification

## Executed on Linux

- **81 portable Swift XCTest cases passed** using the real Swift 6.0.2 compiler/test runner in `swift:6.0.2-jammy`.
- **16 Python checks passed** with `python3 -m unittest discover -s tests -v`.
- `bash -n scripts/build.sh` passed; `Info.plist` and `Voicepad.entitlements` parsed with Python `plistlib`.
- Red/green runs observed failures before implementing the loopback default, bundle configuration lookup, URL-policy/normalization behavior, configured API subpaths, packaging configuration validation, and release metadata.

The Swift command, run from `clients/macos`:

```sh
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/build/home \
  --tmpfs /build:rw,exec,mode=1777,size=1g \
  -v "$PWD:/source:ro" -w /source swift:6.0.2-jammy \
  swift test --scratch-path /build/package --jobs 2
```

## Audio feedback checks (0.6.2)

The data initializer is `NSSound(data:)`, verified against the AppKit NSSound header (`initWithData:`). `byReference` belongs only to file/URL initializers and is prohibited by the wiring regression guard. The prior 0.6.1 Mac build failed at that native API call; Linux tests did not catch it. No actual Mac SDK build is claimed here.

- Four behavioral waveform tests decode generated WAV headers, inspect actual signed PCM levels/envelopes, verify upward/downward sweep direction, success dyad frequencies and distinct deterministic signals. No external assets or user recordings.
- Native wiring guards confirm capture starts after the start cue wait with cancellation/generation revalidation, stop cue follows capture closure, and completion cue is limited to confirmed paste. Playback is local NSSound with a saved Sound Effects menu switch.
- The HUD hides at paste start; neutral notice lasts 0.65 seconds. PasteCoordinator's two-second confirmation/clipboard grace is unchanged. Error/recovery windows are intentionally not auto-dismissed.
- Real speaker/headphone playback, output-device latency, mute behavior and capture of acoustic echo have not been tested on macOS here. Starting microphone waits for the short nominal cue budget, not a hardware playback-completion callback.

## What those checks establish

- Missing bundle configuration defaults to `http://localhost:8791/`; an invalid present value fails closed. Core URL tests execute HTTPS/HTTP-loopback policy, IPv4/IPv6 cases, credentials/query/fragment rejection, malformed inputs, ports, percent escapes and trailing-slash normalization.
- URLProtocol fixtures execute real request construction and decoding. Configured subpaths survive status, profiles and transcription requests. Default initialization remains source-compatible. The credential-free ephemeral session still rejects all redirects.
- Packaging tests execute `build.sh` with **fake Apple compiler/signing tools** and real Python/plistlib configuration. They inspect the resulting staged bundle's URL, preserve the source plist, reject invalid configuration before compilation, retain an existing app on failure, check static-link/compiler arguments and verify version 0.6.0/build 13. They do not prove native compilation or a valid Apple signature.
- Existing portable tests retain recording limits/timeouts, profile catalog/selection/race behavior, clipboard ownership and paste safety, microphone-level presentation, shortcut state and HUD geometry coverage. Python source guards retain the 32-point inset profile-chip implementation and prohibit the known unsupported content-insets call. Source guards and geometry tests do not render AppKit.

## Not verified locally

This host is Linux and has no Apple SDK. No native `.app`, installer, notarized binary or ZIP was produced here. Portable Swift execution does **not** typecheck or link the macOS-only AppKit, AVFoundation, Carbon or Accessibility code. A macOS CI SDK build and the following real-Mac checks are separate gates; no successful CI run is claimed in this document.

## Real-Mac acceptance checklist

Use nonsensitive speech and your own self-hosted server.

- [ ] Run `swift test --jobs 2`, Python checks and `bash scripts/build.sh` on macOS; inspect bundle version and `VoicepadServerURL`, launch the Applications copy and check ad-hoc signing/Gatekeeper behavior.
- [ ] Build once with the local default and once with an HTTPS subpath. Verify status, profiles, audio upload and Dashboard/Admin actions all use the intended server. Redirects must fail rather than forward audio.
- [ ] Verify microphone grant, denial, retry and cancellation during a pending prompt. Sleep, lock and quit must stop capture.
- [ ] Explicitly enable Input Monitoring; test same-key double-Command start/stop. Normal shortcuts, mixed keys, clicks, held/slow taps and Secure Input must not cause accidental capture. Test Carbon fallback without Input Monitoring.
- [ ] Check HUD/profile-chip rendering, long/Unicode names, all nine fixed slots plus Raw, multiple displays, VoiceOver and Reduce Motion/Transparency. Chip clicks must not steal focus.
- [ ] Test profile digits/keypad, absent slots, modified shortcuts and permission revocation. Without Accessibility, click-only feedback and chips must work; unhandled digits must reach the editor.
- [ ] Select a profile at Stop, fail the upload and explicitly Retry: the frozen slot must be reused. Delayed/failed/stale lookups must not change a newer or stopped attempt. Formatting failure must preserve raw text and show its warning alongside delivery status.
- [ ] Verify TextEdit, Notes and browser/editor fields individually: safe paste, changed-target refusal, secure-field refusal, no Enter/Send and no automatic uncertain-paste retry.
- [ ] Test clipboard restoration after confirmed/unconfirmed paste and preservation of a newer copy. Check the actual field before manual recovery with Copy Last Transcript.
- [ ] Test cancellation, offline server, upload/recording limits and clear failures without an automatic billing/provider fallback.

No live server/provider availability, subscription authorization, dictation accuracy, model identity, quota or retention guarantee follows from these tests.
