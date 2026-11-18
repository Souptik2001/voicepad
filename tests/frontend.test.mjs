import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const core = await import('../static/core.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
const app = await import('../static/app.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
const admin = await import('../static/admin.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
const flush = () => new Promise(resolve => setImmediate(resolve));
class Element {
  constructor() { this.listeners = {}; this.value = ''; this.textContent = ''; this.hidden = false; this.disabled = false; this.style = { setProperty() {} }; this.attrs = {}; this.tagName = 'DIV'; }
  addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); }
  dispatch(name, event = {}) { for (const fn of this.listeners[name] ?? []) fn({ target: this, preventDefault() {}, ...event }); }
  setAttribute(name, value) { this.attrs[name] = value; }
  focus() { this.focused = true; }
  closest() { return this.tagName === 'DIV' ? null : this; }
}
function uiHarness() {
  const elements = new Map();
  const doc = new Element();
  doc.getElementById = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
  const env = new Element();
  let mediaCalls = 0;
  const storage = new Map();
  Object.assign(env, { document: doc, isSecureContext: true, location: { hash: '', search: '', pathname: '/voicepad/' }, history: { replaceState() {} }, sessionStorage: { getItem: k => storage.get(k), setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) }, navigator: { mediaDevices: { getUserMedia: async () => { mediaCalls++; throw Error('Permission denied'); } }, clipboard: { writeText: async text => { env.copied = text; } } }, MediaRecorder: class {}, performance: { now: () => 0 }, setInterval, clearInterval, AbortController, fetch: async () => ({ ok: true, status: 200, json: async () => ({ credential_available: true, auth_state: 'connected', provider: 'codex-subscription', quota: 'Not reported by provider', audio_retention: 'Provider response reported 30-day asset lifetime.', credential_expires_at: null }) }) });
  return { doc, env, get: doc.getElementById, mediaCalls: () => mediaCalls, storage };
}

test('UI automatically checks status without a key gate or storage dependency', async () => {
  assert.equal(typeof app.mountVoicepad, 'function');
  const h = uiHarness();
  const requests = [];
  const fetch = h.env.fetch;
  h.env.fetch = (...args) => { requests.push(args); return fetch(...args); };
  Object.defineProperty(h.env, 'sessionStorage', { get() { throw Error('Storage blocked'); } });
  const mounted = app.mountVoicepad(h.doc, h.env);
  assert.equal(h.get('record').disabled, true);
  assert.equal(h.mediaCalls(), 0);
  await flush();
  assert.equal(h.get('record').disabled, false);
  assert.equal(requests[0][0], './api/status');
  assert.equal(h.storage.size, 0);
  assert.equal(h.get('key-form').listeners.submit, undefined);
  h.get('record').dispatch('click');
  await flush();
  assert.equal(h.mediaCalls(), 1);
  assert.match(h.get('error').textContent, /Permission denied/);
  mounted.destroy();
});
test('Space hold-release cancels pending permission and ignores editable fields', async () => {
  const h = uiHarness();
  let resolve;
  const track = { stopped: false, stop() { this.stopped = true; } };
  h.env.navigator.mediaDevices.getUserMedia = () => new Promise(done => { resolve = done; });
  h.env.location.hash = '#key=private';
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  const input = new Element(); input.tagName = 'INPUT';
  h.doc.dispatch('keydown', { code: 'Space', target: input });
  assert.equal(resolve, undefined);
  h.doc.dispatch('keydown', { code: 'Space', repeat: false });
  assert.equal(typeof resolve, 'function');
  h.doc.dispatch('keyup', { code: 'Space' });
  resolve({ getTracks: () => [track] });
  await flush();
  assert.equal(track.stopped, true);
  assert.equal(mounted.session.snapshot().phase, 'idle');
  mounted.destroy();
});

test('file transcript is editable, copyable, clearable and displays only provider metadata', async () => {
  const h = uiHarness();
  h.env.location.hash = '#key=private';
  h.env.fetch = async url => ({ ok: true, status: 200, json: async () => url.endsWith('transcribe') ? { text: 'These are my words.', audio_seconds: 2.3, elapsed_seconds: 0.8, provider: 'codex-subscription', usage: null, provider_audio_retention: '30d', request_id: 'req-test' } : { credential_available: true, auth_state: 'connected', provider: 'codex-subscription', quota: 'Not reported by provider', credential_expires_at: null } });
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  h.get('audio-file').files = [new Blob(['test-audio'], { type: 'audio/wav' })];
  h.get('audio-file').dispatch('change');
  await flush();
  assert.equal(h.get('transcript').value, 'These are my words.');
  assert.match(h.get('last-audio').textContent, /2.3/);
  assert.match(h.get('latency').textContent, /0.8/);
  assert.equal(h.get('provider').textContent, 'codex-subscription');
  assert.match(h.get('quota').textContent, /Not reported/);
  assert.match(h.get('retention').textContent, /30/);
  h.get('transcript').value = 'Edited words';
  h.get('transcript').dispatch('input');
  h.get('copy').dispatch('click');
  await flush();
  assert.equal(h.env.copied, 'Edited words');
  h.get('clear').dispatch('click');
  assert.equal(h.get('transcript').value, '');
  assert.equal(mounted.session.snapshot().text, '');
  mounted.destroy();
});

test('HTTPS warning blocks microphone while pagehide aborts uploads and discards late results', async () => {
  const insecure = uiHarness(); insecure.env.isSecureContext = false;
  insecure.env.location.hash = '#key=private';
  const first = app.mountVoicepad(insecure.doc, insecure.env);
  await flush();
  assert.equal(insecure.get('record').disabled, true);
  assert.match(insecure.get('secure-warning').textContent, /HTTPS/);
  first.destroy();
  const h = uiHarness(); h.env.location.hash = '#key=private';
  let signal, resolve;
  const original = h.env.fetch;
  h.env.fetch = (url, options) => url.endsWith('transcribe') ? new Promise(done => { signal = options.signal; resolve = done; }) : original(url, options);
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  h.get('audio-file').files = [new Blob(['audio'], { type: 'audio/wav' })];
  h.get('audio-file').dispatch('change');
  await flush();
  h.env.dispatch('pagehide');
  assert.equal(signal.aborted, true);
  resolve({ ok: true, status: 200, json: async () => ({ text: 'Must be ignored' }) });
  await flush();
  assert.equal(mounted.session.snapshot().text, '');
});

test('cancelled upload finishing late cannot detach the active upload abort controller', async () => {
  const h = uiHarness(); h.env.location.hash = '#key=private';
  const pending = [];
  const original = h.env.fetch;
  h.env.fetch = (url, options) => url.endsWith('transcribe') ? new Promise(resolve => pending.push({ resolve, signal: options.signal })) : original(url, options);
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  const upload = () => { h.get('audio-file').files = [new Blob(['audio'], { type: 'audio/wav' })]; h.get('audio-file').dispatch('change'); };
  upload();
  h.get('cancel').dispatch('click');
  upload();
  pending[0].resolve({ ok: true, status: 200, json: async () => ({ text: 'Discarded' }) });
  await flush();
  h.env.dispatch('pagehide');
  assert.equal(pending[1].signal.aborted, true);
  pending[1].resolve({ ok: true, status: 200, json: async () => ({ text: 'Discarded too' }) });
  await flush();
  assert.equal(mounted.session.snapshot().text, '');
});

test('browser audio meter measures actual waveform and disconnects its graph', () => {
  assert.equal(typeof app.createAudioMonitor, 'function');
  let disconnected = 0, closed = 0;
  class Context {
    createAnalyser() { return { fftSize: 0, getByteTimeDomainData(data) { data.fill(160); }, disconnect() { disconnected++; } }; }
    createMediaStreamSource() { return { connect() {}, disconnect() { disconnected++; } }; }
    close() { closed++; return Promise.resolve(); }
  }
  const meter = app.createAudioMonitor({}, { AudioContext: Context });
  assert.ok(meter.level() > 0);
  meter.close();
  assert.equal(disconnected, 2);
  assert.equal(closed, 1);
});

test('UI recorder uses supported MIME, updates timer and stops on window blur for Space hold', async () => {
  const h = uiHarness(); h.env.location.hash = '#key=private';
  let recordingOptions, tick;
  let now = 0;
  const track = { stopped: false, stop() { this.stopped = true; } };
  h.env.navigator.mediaDevices.getUserMedia = async () => ({ getTracks: () => [track] });
  h.env.performance.now = () => now;
  h.env.setInterval = fn => { tick = fn; return 1; };
  h.env.clearInterval = () => { tick = null; };
  h.env.MediaRecorder = class {
    static isTypeSupported(type) { return type === 'audio/mp4'; }
    constructor(_stream, options) { recordingOptions = options; this.mimeType = 'audio/mp4'; this.state = 'inactive'; }
    start() { this.state = 'recording'; }
    stop() { this.state = 'inactive'; queueMicrotask(() => this.onstop?.()); }
  };
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  h.doc.dispatch('keydown', { code: 'Space' });
  await flush();
  assert.equal(recordingOptions.mimeType, 'audio/mp4');
  now = 1200; tick();
  assert.equal(h.get('timer').textContent, '00:01');
  assert.equal(h.get('record').attrs['aria-pressed'], 'true');
  h.env.dispatch('blur');
  await flush();
  assert.equal(track.stopped, true);
  assert.equal(tick, null);
  mounted.destroy();
});

test('pagehide discards a late automatic status response', async () => {
  const h = uiHarness();
  let respond;
  h.env.fetch = () => new Promise(resolve => { respond = resolve; });
  const mounted = app.mountVoicepad(h.doc, h.env);
  h.env.dispatch('pagehide');
  respond({ ok: true, status: 200, json: async () => ({ credential_available: true, auth_state: 'connected', provider: 'codex-subscription' }) });
  await flush();
  assert.equal(h.get('record').disabled, true);
  assert.equal(h.get('audio-file').disabled, true);
  mounted.destroy();
});

test('unavailable subscription credentials keep recording locked with an actionable error', async () => {
  const h = uiHarness(); h.env.location.hash = '#key=private';
  h.env.fetch = async () => ({ ok: true, status: 200, json: async () => ({ provider: 'codex-subscription', credential_available: false, quota: 'Not reported by provider' }) });
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  assert.equal(h.get('record').disabled, true);
  assert.equal(h.get('audio-file').disabled, true);
  assert.match(h.get('error').textContent, /Connect Codex in Administration/i);
  h.get('record').dispatch('click');
  assert.equal(h.mediaCalls(), 0);
  mounted.destroy();
});

test('status metadata stays honest and cancel button discards a pending recording request', async () => {
  const h = uiHarness(); h.env.location.hash = '#key=private';
  let resolve;
  h.env.navigator.mediaDevices.getUserMedia = () => new Promise(done => { resolve = done; });
  const mounted = app.mountVoicepad(h.doc, h.env);
  await flush();
  assert.equal(h.get('provider').textContent, 'codex-subscription');
  assert.match(h.get('quota').textContent, /Not reported/);
  assert.match(h.get('retention').textContent, /30-day/);
  assert.match(h.get('credential-expiry').textContent, /Not reported/);
  h.get('record').dispatch('click');
  assert.equal(h.get('cancel').hidden, false);
  h.get('cancel').dispatch('click');
  const track = { stop() { this.stopped = true; } };
  resolve({ getTracks: () => [track] });
  await flush();
  assert.equal(track.stopped, true);
  assert.equal(mounted.session.snapshot().phase, 'idle');
  assert.equal(h.get('cancel').hidden, true);
  mounted.destroy();
});

function adminHarness(initial = {}) {
  const h = uiHarness();
  const timers = new Map(), requests = [];
  let nextTimer = 0;
  h.env.location.pathname = '/voicepad/admin';
  h.env.setTimeout = (fn, delay) => { timers.set(++nextTimer, { fn, delay }); return nextTimer; };
  h.env.clearTimeout = id => timers.delete(id);
  const status = { connected: false, auth_state: 'disconnected', credential_expires_at: null, auto_refresh: true, last_refresh_at: null, last_error: null, login: { state: 'idle' }, ...initial };
  h.env.fetch = async (url, options) => { requests.push({ url, ...options }); return response(status); };
  return { ...h, timers, requests, status, tick() { const [id, timer] = timers.entries().next().value; timers.delete(id); timer.fn(); } };
}
const response = (data, status = 200) => ({ ok: status < 400, status, json: async () => data });

test('admin loads sanitized status without starting login and starts device flow only on click', async () => {
  assert.equal(typeof admin.mountAdmin, 'function');
  const h = adminHarness();
  const mounted = admin.mountAdmin(h.doc, h.env);
  await flush();
  assert.deepEqual(h.requests.map(r => r.url), ['./api/admin/status']);
  assert.equal(h.get('login-code-panel').hidden, true);
  assert.equal(h.get('connect').disabled, false);
  assert.equal(h.timers.size, 0);
  const original = h.env.fetch;
  h.env.fetch = async (url, options) => {
    if (url.endsWith('/login')) { h.requests.push({ url, ...options }); return response({ state: 'pending', verification_url: 'https://auth.openai.com/codex/device', user_code: 'ABCD-EFGH', expires_at: '2026-11-10T12:10:00Z' }); }
    return original(url, options);
  };
  h.get('connect').dispatch('click');
  await flush();
  assert.equal(h.get('login-code-panel').hidden, false);
  assert.equal(h.get('user-code').textContent, 'ABCD-EFGH');
  assert.equal(h.get('verification-link').attrs.href, 'https://auth.openai.com/codex/device');
  assert.equal(h.get('login-expires').textContent, '2026-11-10T12:10:00Z');
  assert.equal(h.requests[1].method, 'POST');
  assert.equal(h.requests[1].body, '{}');
  assert.equal(h.requests[1].headers['X-Requested-With'], 'voicepad');
  assert.equal(h.requests[1].headers.Authorization, undefined);
  assert.equal(h.requests[1].credentials, 'omit');
  assert.equal(h.timers.size, 1);
  assert.equal([...h.timers.values()][0].delay, 3000);
  h.status.connected = true; h.status.auth_state = 'connected'; h.status.login = { state: 'connected' };
  h.tick(); await flush();
  assert.equal(h.get('login-code-panel').hidden, true);
  assert.equal(h.get('auth-state').textContent, 'Connected');
  assert.equal(h.get('auto-refresh').textContent, 'Enabled');
  assert.equal(h.get('refresh').disabled, false);
  assert.equal(h.timers.size, 0);
  mounted.destroy();
});

test('admin cancel invalidates an in-flight poll and pagehide clears pending polling', async () => {
  const h = adminHarness({ login: { state: 'pending', user_code: 'OLD-CODE', verification_url: 'https://auth.openai.com/codex/device' } });
  const mounted = admin.mountAdmin(h.doc, h.env);
  await flush();
  assert.equal(h.timers.size, 1);
  let finishPoll;
  h.env.fetch = (url, options) => {
    h.requests.push({ url, ...options });
    if (url.endsWith('/status')) return new Promise(resolve => { finishPoll = resolve; });
    return Promise.resolve(response({ ...h.status, login: { state: 'idle' } }));
  };
  h.tick();
  h.get('cancel-login').dispatch('click');
  await flush();
  assert.equal(h.requests.at(-1).url, './api/admin/cancel');
  assert.equal(h.requests.at(-1).method, 'POST');
  assert.equal(h.requests.at(-1).headers['X-Requested-With'], 'voicepad');
  assert.equal(h.get('login-code-panel').hidden, true);
  finishPoll(response({ ...h.status, login: { state: 'pending', user_code: 'STALE' } }));
  await flush();
  assert.equal(h.get('user-code').textContent, '');
  assert.equal(h.timers.size, 0);
  mounted.destroy();
  const second = adminHarness({ login: { state: 'pending', user_code: 'PENDING' } });
  admin.mountAdmin(second.doc, second.env);
  await flush();
  assert.equal(second.timers.size, 1);
  second.env.dispatch('pagehide');
  assert.equal(second.timers.size, 0);
});

test('admin disconnect requires explicit confirmation and only removes the local grant', async () => {
  const h = adminHarness({ connected: true, auth_state: 'connected' });
  const mounted = admin.mountAdmin(h.doc, h.env);
  await flush();
  let confirmation;
  h.env.confirm = message => { confirmation = message; return false; };
  h.get('disconnect').dispatch('click'); await flush();
  assert.equal(h.requests.length, 1);
  assert.match(confirmation, /locally/i);
  assert.match(confirmation, /not revoke/i);
  h.env.confirm = () => true;
  h.env.fetch = async (url, options) => { h.requests.push({ url, ...options }); return response({ ...h.status, connected: false, auth_state: 'disconnected' }); };
  h.get('disconnect').dispatch('click'); await flush();
  assert.equal(h.requests.at(-1).url, './api/admin/disconnect');
  assert.equal(h.requests.at(-1).headers['X-Requested-With'], 'voicepad');
  assert.equal(h.get('auth-state').textContent, 'Disconnected');
  assert.equal(h.get('refresh').disabled, true);
  assert.equal(h.get('connect').disabled, false);
  mounted.destroy();
});

test('admin tests automatic token refresh and recovers sanitized status after provider errors', async () => {
  const h = adminHarness({ connected: true, auth_state: 'connected', auto_refresh: true });
  const mounted = admin.mountAdmin(h.doc, h.env);
  await flush();
  h.env.fetch = async (url, options) => { h.requests.push({ url, ...options }); return response({ ...h.status, last_refresh_at: '2026-11-10T12:00:00Z', credential_expires_at: '2026-11-11T12:00:00Z' }); };
  h.get('refresh').dispatch('click'); await flush();
  assert.equal(h.requests.at(-1).url, './api/admin/refresh');
  assert.equal(h.requests.at(-1).body, '{}');
  assert.equal(h.requests.at(-1).headers['X-Requested-With'], 'voicepad');
  assert.equal(h.get('last-refresh').textContent, '2026-11-10T12:00:00Z');
  assert.equal(h.get('credential-expiry').textContent, '2026-11-11T12:00:00Z');
  h.env.fetch = async (url, options) => {
    h.requests.push({ url, ...options });
    return url.endsWith('/refresh') ? response({ error: 'Reconnect required' }, 401) : response({ ...h.status, connected: false, auth_state: 'reconnect_required', last_error: 'Reconnect required', refresh_retry_at: '2026-11-10T12:05:00Z' });
  };
  h.get('refresh').dispatch('click'); await flush();
  assert.equal(h.requests.at(-1).url, './api/admin/status');
  assert.equal(h.get('auth-state').textContent, 'Reconnect required');
  assert.equal(h.get('last-error').textContent, 'Reconnect required');
  assert.equal(h.get('refresh-retry').textContent, '2026-11-10T12:05:00Z');
  assert.equal(h.get('refresh').disabled, true);
  assert.match(h.get('admin-error').textContent, /Reconnect required/);
  mounted.destroy();
});

test('recorder page labels the ten-minute duration and 25 MB upload limits', async () => {
  const html = await readFile(new URL('../static/index.html', import.meta.url), 'utf8');
  assert.match(html, /class="limit">10 min max</);
  assert.match(html, /class="time-cap">\/ 10:00</);
  assert.match(html, /class="file-limit">Up to 10 min · 25 MB</);
});

test('HTML wires relative admin assets and both pages mount against their real element IDs', async () => {
  for (const [file, mount, script] of [['index.html', app.mountVoicepad, './app.mjs'], ['admin.html', admin.mountAdmin, './admin.mjs']]) {
    const html = await readFile(new URL(`../static/${file}`, import.meta.url), 'utf8');
    assert.ok(html.includes(`src="${script}"`));
    assert.ok(html.includes('href="./styles.css"'));
    assert.ok(html.includes('href="./"'));
    assert.doesNotMatch(html, /id="(?:access-key|key-form)"/);
    assert.match(html, /Any permitted Tailnet peer/i);
    const h = file === 'admin.html' ? adminHarness() : uiHarness();
    const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
    const get = h.doc.getElementById;
    h.doc.getElementById = id => ids.has(id) ? get(id) : null;
    const mounted = mount(h.doc, h.env);
    await flush();
    mounted.destroy();
    if (file === 'index.html') assert.ok(html.includes('href="./admin"'));
    else {
      assert.match(html, /Test token refresh/);
      assert.ok(html.includes('https://auth.openai.com/codex/device'));
      assert.doesNotMatch(html, /<input\b/i);
    }
  }
});

test('admin login errors and expired codes are actionable without leaking timers', async () => {
  const h = adminHarness();
  const mounted = admin.mountAdmin(h.doc, h.env);
  await flush();
  h.env.fetch = async () => response({ error: 'OpenAI is unavailable. Try again.' }, 503);
  h.get('connect').dispatch('click'); await flush();
  assert.match(h.get('admin-error').textContent, /OpenAI is unavailable/);
  assert.equal(h.get('connect').disabled, false);
  assert.equal(h.timers.size, 0);
  h.env.fetch = async () => response({ state: 'pending', user_code: 'EXPIRES', verification_url: 'https://evil.example/device' });
  h.get('connect').dispatch('click'); await flush();
  assert.equal(h.get('verification-link').attrs.href, 'https://auth.openai.com/codex/device');
  h.env.fetch = async () => response({ ...h.status, login: { state: 'expired', error: 'Device code expired.' } });
  h.tick(); await flush();
  assert.equal(h.get('login-code-panel').hidden, true);
  assert.match(h.get('login-state').textContent, /expired/);
  assert.match(h.get('admin-error').textContent, /expired/);
  assert.equal(h.timers.size, 0);
  mounted.destroy();
});

test('admin pagehide discards a late login completion and never schedules polling', async () => {
  const h = adminHarness();
  admin.mountAdmin(h.doc, h.env);
  await flush();
  let finish;
  h.env.fetch = () => new Promise(resolve => { finish = resolve; });
  h.get('connect').dispatch('click');
  h.env.dispatch('pagehide');
  finish(response({ state: 'pending', user_code: 'STALE' })); await flush();
  assert.equal(h.get('user-code').textContent, '');
  assert.equal(h.get('login-code-panel').hidden, true);
  assert.equal(h.timers.size, 0);
});

test('legacy links and tab storage are cleared, never read or saved as credentials', () => {
  const h = uiHarness();
  h.env.location.hash = '#key=old-secret'; h.env.location.search = '?key=old-secret';
  h.storage.set('voicepad.key', 'old-secret');
  let cleaned;
  h.env.history.replaceState = (_state, _title, url) => { cleaned = url; };
  h.env.sessionStorage.getItem = () => { throw Error('Must not read old credential'); };
  core.clearLegacyAccess(h.env);
  assert.equal(cleaned, '/voicepad/');
  assert.equal(h.storage.size, 0);
});

test('destroy prevents a late root status response from enabling a detached page', async () => {
  const h = uiHarness();
  let finish;
  h.env.fetch = () => new Promise(resolve => { finish = resolve; });
  const mounted = app.mountVoicepad(h.doc, h.env);
  mounted.destroy();
  finish(response({ credential_available: true, auth_state: 'connected' })); await flush();
  assert.equal(h.get('record').disabled, true);
  assert.equal(h.get('audio-file').disabled, true);
});

function harness(options = {}) {
  let resolveMedia;
  let time = 0;
  const tracks = [{ stopped: false, stop() { this.stopped = true; } }];
  const stream = { getTracks: () => tracks };
  const recorders = [];
  const timers = new Map();
  const uploads = [];
  let mediaCalls = 0, nextTimer = 0, monitorClosed = 0;
  const states = [];
  const deps = {
    getUserMedia: () => { mediaCalls++; return options.pending ? new Promise(resolve => { resolveMedia = resolve; }) : Promise.resolve(stream); },
    createRecorder: () => {
      const recorder = {
        state: 'inactive', mimeType: 'audio/webm',
        start() { this.state = 'recording'; },
        stop() { this.state = 'inactive'; queueMicrotask(() => { this.ondataavailable?.({ data: new Blob(['real-test-audio'], { type: 'audio/webm' }) }); this.onstop?.(); }); },
      };
      recorders.push(recorder);
      return recorder;
    },
    monitor: () => ({ level: () => 0.42, close() { monitorClosed++; } }),
    now: () => time,
    setInterval: fn => { timers.set(++nextTimer, fn); return nextTimer; },
    clearInterval: id => timers.delete(id),
    upload: async blob => { uploads.push(blob); return options.response ?? { text: 'A real response', elapsed_seconds: 0.7, audio_seconds: 1.5, provider: 'codex-subscription', usage: null, provider_audio_retention: '30d' }; },
    onChange: state => states.push(state),
    ...options.deps,
  };
  assert.equal(typeof core.createVoiceSession, 'function', 'createVoiceSession must be implemented');
  const session = core.createVoiceSession(deps);
  return { session, tracks, stream, recorders, timers, uploads, states,
    resolve: () => resolveMedia(stream), mediaCalls: () => mediaCalls,
    monitorClosed: () => monitorClosed, advance: ms => { time += ms; for (const fn of [...timers.values()]) fn(); } };
}

test('recorder start failure stops a partially started recorder and closes its resources', async () => {
  let stopped = 0;
  const h = harness({ deps: { createRecorder: () => ({ state: 'inactive', start() { this.state = 'recording'; throw Error('Recorder startup failed'); }, stop() { stopped++; this.state = 'inactive'; } }) } });
  h.session.edit('Preserve these words');
  await h.session.start();
  assert.equal(stopped, 1);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.monitorClosed(), 1);
  assert.equal(h.timers.size, 0);
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.equal(h.session.snapshot().text, 'Preserve these words');
  assert.match(h.session.snapshot().error, /startup failed/);
});

test('late error from a discarded recorder cannot cancel a newer recording', async () => {
  const h = harness();
  await h.session.start();
  const old = h.recorders[0];
  h.session.cancel();
  await h.session.start();
  old.onerror({ error: new Error('Stale error') });
  assert.equal(h.session.snapshot().phase, 'recording');
  assert.equal(h.session.snapshot().error, '');
  h.session.cancel();
});

test('repeated stop is safe before final recorder event and blocks restart', async () => {
  const h = harness();
  await h.session.start();
  const original = h.recorders[0].stop;
  h.recorders[0].stop = function () {
    assert.equal(this.state, 'recording', 'stop must not be invoked on an inactive recorder');
    original.call(this);
  };
  h.session.stop();
  h.session.stop();
  await h.session.start();
  assert.equal(h.mediaCalls(), 1);
  await flush();
  assert.equal(h.uploads.length, 1);
});

test('MIME choice supports Safari mp4, Chromium webm and browser default', () => {
  assert.equal(typeof core.chooseMimeType, 'function');
  assert.equal(core.chooseMimeType(type => type === 'audio/mp4'), 'audio/mp4');
  assert.equal(core.chooseMimeType(type => type === 'audio/webm;codecs=opus'), 'audio/webm;codecs=opus');
  assert.equal(core.chooseMimeType(() => false), '');
});

test('API transport uses keyless relative raw audio requests and exposes provider errors', async () => {
  const requests = [];
  const api = core.createApi({ fetch: async (url, options) => {
    requests.push({ url, ...options });
    return { ok: requests.length < 3, status: requests.length < 3 ? 200 : 401, json: async () => requests.length < 3 ? { text: 'Provider text' } : { error: 'Reconnect Codex' } };
  } });
  await api.status();
  const blob = new Blob(['audio'], { type: 'audio/mp4' });
  assert.equal((await api.transcribe(blob)).text, 'Provider text');
  assert.equal(requests[0].url, './api/status');
  assert.equal(requests[1].url, './api/transcribe');
  assert.equal(requests[1].body, blob);
  for (const request of requests) {
    assert.equal(request.credentials, 'omit');
    assert.equal(request.cache, 'no-store');
    assert.equal(request.referrerPolicy, 'no-referrer');
    assert.equal(request.headers.Authorization, undefined);
  }
  assert.equal(requests[1].headers['X-Requested-With'], 'voicepad');
  assert.equal(requests[1].headers['Content-Type'], 'audio/mp4');
  await assert.rejects(api.status(), /Reconnect Codex/);
});

test('an unreadable server response is an actionable transport error', async () => {
  const api = core.createApi({ fetch: async () => ({ ok: false, status: 502, json: async () => { throw Error('Not JSON'); } }) });
  await assert.rejects(api.status(), /unreadable response \(502\)/);
});

test('live recording accepts exactly 25 MiB across chunks and rejects the next byte', async () => {
  const h = harness();
  await h.session.start();
  const recorder = h.recorders[0];
  recorder.ondataavailable({ data: new Blob([new Uint8Array(10 * 1024 * 1024)]) });
  recorder.ondataavailable({ data: new Blob([new Uint8Array(15 * 1024 * 1024)]) });
  assert.equal(recorder.state, 'recording');
  assert.equal(h.session.snapshot().error, '');
  assert.equal(h.tracks[0].stopped, false);
  recorder.ondataavailable({ data: new Blob([new Uint8Array(1)]) });
  await flush();
  assert.equal(recorder.state, 'inactive');
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.monitorClosed(), 1);
  assert.equal(h.timers.size, 0);
  assert.equal(h.uploads.length, 0);
  assert.equal(h.session.snapshot().error, 'Audio exceeds the 25 MB limit. Use a shorter clip.');
});

test('recorder errors and oversized live chunks stop immediately without uploading', async () => {
  for (const kind of ['error', 'oversize']) {
    const h = harness();
    await h.session.start();
    if (kind === 'error') h.recorders[0].onerror({ error: new Error('Device disconnected') });
    else h.recorders[0].ondataavailable({ data: new Blob([new Uint8Array(25 * 1024 * 1024 + 1)]) });
    await flush();
    assert.equal(h.tracks[0].stopped, true);
    assert.equal(h.uploads.length, 0);
    assert.equal(h.timers.size, 0);
    assert.equal(h.session.snapshot().phase, 'idle');
    assert.ok(h.session.snapshot().error);
  }
});

test('real file upload accepts exactly 25 MiB and rejects one extra byte without contacting provider', async () => {
  const h = harness();
  const limit = 25 * 1024 * 1024;
  const accepted = new Blob([new Uint8Array(limit)], { type: 'audio/mp4' });
  await h.session.uploadFile(accepted);
  assert.equal(h.uploads.length, 1);
  assert.equal(h.uploads[0], accepted);
  assert.equal(h.session.snapshot().text, 'A real response');
  assert.equal(h.session.snapshot().error, '');
  await h.session.uploadFile(new Blob([accepted, new Uint8Array(1)], { type: 'audio/mp4' }));
  assert.equal(h.uploads.length, 1);
  assert.equal(h.session.snapshot().error, 'Audio exceeds the 25 MB limit. Use a shorter clip.');
  await h.session.uploadFile(new Blob([]));
  assert.equal(h.uploads.length, 1);
  assert.match(h.session.snapshot().error, /No audio captured/);
  assert.equal(h.mediaCalls(), 0);
});

test('recording continues at 120 seconds and a delayed 600 second tick stops and uploads once', async () => {
  const h = harness();
  await h.session.start();
  let stops = 0;
  const stop = h.recorders[0].stop;
  h.recorders[0].stop = function () { stops++; stop.call(this); };
  h.advance(120000);
  await flush();
  assert.equal(h.session.snapshot().phase, 'recording');
  assert.equal(h.session.snapshot().seconds, 120);
  assert.equal(h.session.snapshot().level, 0.42);
  assert.equal(h.tracks[0].stopped, false);
  assert.equal(h.uploads.length, 0);
  h.advance(479700);
  assert.equal(h.recorders[0].state, 'recording');
  // Simulate a delayed browser timer: the next callback arrives at the cap.
  h.advance(300);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.monitorClosed(), 1);
  assert.equal(h.timers.size, 0);
  assert.equal(h.session.snapshot().seconds, 600);
  h.session.stop();
  await flush();
  h.advance(1000);
  assert.equal(stops, 1);
  assert.equal(h.uploads.length, 1);
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.equal(h.session.snapshot().text, 'A real response');
});

test('automatic stop reserves 200 milliseconds for encoder padding and blocks duplicate stops', async () => {
  const h = harness();
  await h.session.start();
  let stops = 0;
  const stop = h.recorders[0].stop;
  h.recorders[0].stop = function () { stops++; stop.call(this); };
  h.advance(599700);
  assert.equal(h.session.snapshot().phase, 'recording');
  assert.equal(h.tracks[0].stopped, false);
  h.advance(100);
  assert.equal(h.recorders[0].state, 'inactive');
  assert.equal(h.session.snapshot().phase, 'stopping');
  assert.equal(h.session.snapshot().seconds, 599.8);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.monitorClosed(), 1);
  assert.equal(h.timers.size, 0);
  h.session.stop();
  await h.session.start();
  await flush();
  h.advance(200);
  assert.equal(h.mediaCalls(), 1);
  assert.equal(stops, 1);
  assert.equal(h.uploads.length, 1);
  assert.equal(h.session.snapshot().phase, 'idle');
});

test('permission and recorder failures become visible errors without leaking resources', async () => {
  for (const stage of ['getUserMedia', 'createRecorder']) {
    const h = harness({ deps: { [stage]: () => { throw new Error('Microphone denied'); } } });
    await h.session.start();
    assert.equal(h.session.snapshot().error, 'Microphone denied');
    assert.equal(h.session.snapshot().phase, 'idle');
    assert.equal(h.timers.size, 0);
    if (stage === 'createRecorder') assert.equal(h.tracks[0].stopped, true);
  }
});

test('cancel while recording discards audio, closes resources, and ignores late completion', async () => {
  const h = harness();
  await h.session.start();
  h.session.cancel();
  await flush();
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.equal(h.uploads.length, 0);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.monitorClosed(), 1);
  assert.equal(h.timers.size, 0);
});

test('a malformed transcription response preserves existing text and shows an error', async () => {
  const h = harness({ response: { elapsed_seconds: 0.2, provider: 'codex-subscription' } });
  h.session.edit('Keep my previous words');
  await h.session.uploadFile(new Blob(['audio'], { type: 'audio/mp4' }));
  assert.equal(h.session.snapshot().text, 'Keep my previous words');
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.match(h.session.snapshot().error, /valid transcript/i);
  assert.equal(h.session.snapshot().result, null);
});

test('upload failure keeps edited transcript and releases all recording resources', async () => {
  const h = harness({ deps: { upload: async () => { throw new Error('Provider unavailable'); } } });
  h.session.edit('Keep my previous words');
  await h.session.start();
  h.session.stop();
  await flush();
  assert.equal(h.session.snapshot().text, 'Keep my previous words');
  assert.equal(h.session.snapshot().error, 'Provider unavailable');
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.timers.size, 0);
  assert.equal(h.monitorClosed(), 1);
});

test('double start acquires only one stream and cannot record during upload', async () => {
  let finish;
  const h = harness({ deps: { upload: () => new Promise(resolve => { finish = resolve; }) } });
  await Promise.all([h.session.start(), h.session.start()]);
  assert.equal(h.mediaCalls(), 1);
  h.session.stop();
  await flush();
  await h.session.start();
  assert.equal(h.mediaCalls(), 1);
  finish({ text: 'Finished' });
  await flush();
  assert.equal(h.session.snapshot().phase, 'idle');
});

test('rapid release during permission request never starts a late microphone', async () => {
  const h = harness({ pending: true });
  const pending = h.session.start();
  h.session.stop();
  h.resolve();
  await pending;
  assert.equal(h.recorders.length, 0);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.equal(h.uploads.length, 0);
});

test('explicit start records and stop releases microphone before uploading', async () => {
  const h = harness();
  assert.equal(h.mediaCalls(), 0);
  await h.session.start();
  assert.equal(h.session.snapshot().phase, 'recording');
  assert.equal(h.mediaCalls(), 1);
  h.advance(1500);
  h.session.stop();
  assert.equal(h.tracks[0].stopped, true);
  await flush();
  assert.equal(h.uploads.length, 1);
  assert.equal(h.session.snapshot().text, 'A real response');
  assert.equal(h.session.snapshot().phase, 'idle');
  assert.equal(h.monitorClosed(), 1);
  assert.equal(h.timers.size, 0);
});
