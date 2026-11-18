import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const profiles = await import('../static/profiles.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
const flush = () => new Promise(resolve => setImmediate(resolve));
const profile = (slot = 1, name = 'Official', instructions = 'Use a formal tone.') => ({ slot, name, instructions });
const response = (items = [profile()]) => ({ ok: true, status: 200, json: async () => ({ profiles: items }) });
class Element {
  constructor(tagName = 'DIV') {
    this.tagName = tagName; this.listeners = new Map(); this.attrs = {}; this.children = [];
    this.textContent = ''; this.value = ''; this.hidden = false; this.disabled = false;
  }
  addEventListener(name, fn) { if (!this.listeners.has(name)) this.listeners.set(name, new Set()); this.listeners.get(name).add(fn); }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  dispatch(name) { const event = { target: this, preventDefault() {} }; for (const fn of this.listeners.get(name) ?? []) fn(event); }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  set innerHTML(_) { throw Error('Unsafe HTML assignment'); }
}
function harness(items = [profile()]) {
  const elements = new Map();
  const doc = { getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); }, createElement: tag => new Element(tag.toUpperCase()) };
  const env = new Element(); const requests = [];
  Object.assign(env, { AbortController, fetch: async (url, options) => { requests.push({ url, ...options }); return response(items); } });
  return { doc, env, requests, get: id => doc.getElementById(id), slot: slot => doc.getElementById('profile-slots').children[slot - 1], input(id, value) { const el = doc.getElementById(id); el.value = value; el.dispatch('input'); } };
}

test('saves trimmed names and verbatim instructions only after matching server readback', async () => {
  const h = harness([]); const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  h.input('profile-name', '  Personal  '); h.input('profile-instructions', '  Keep my words.\n');
  let resolve;
  h.env.fetch = (url, options) => { h.requests.push({ url, ...options }); return new Promise(done => { resolve = done; }); };
  h.get('profile-form').dispatch('submit');
  assert.equal(h.get('profile-save').disabled, true);
  assert.doesNotMatch(h.get('profiles-status').textContent, /saved/i);
  const request = h.requests.at(-1);
  assert.equal(request.url, './api/profiles/1'); assert.equal(request.method, 'PUT');
  assert.equal(request.headers['X-Requested-With'], 'voicepad');
  assert.equal(request.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(request.body), { name: 'Personal', instructions: '  Keep my words.\n' });
  resolve(response([profile(1, 'Personal', '  Keep my words.\n')])); await flush();
  assert.match(h.get('profiles-status').textContent, /saved/i);
  assert.equal(h.get('profile-name').value, 'Personal');
  assert.equal(h.get('profile-save').disabled, true);
  h.slot(2).dispatch('click'); h.input('profile-name', 'Raw');
  h.get('profile-form').dispatch('submit');
  assert.deepEqual(JSON.parse(h.requests.at(-1).body), { name: 'Raw', instructions: '' });
  resolve(response([profile(1, 'Personal', '  Keep my words.\n'), profile(2, 'Raw', '')])); await flush();
  assert.match(h.slot(2).textContent, /Raw/);
  assert.match(h.get('profile-mode').textContent, /raw.*no extra.*request/i);
  mounted.destroy();
});

test('keeps per-slot drafts on switching and failed saves, then permits retry', async () => {
  const h = harness(); const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  h.input('profile-name', 'Draft'); h.input('profile-instructions', 'Do not lose this.');
  h.slot(2).dispatch('click'); h.input('profile-name', 'Second draft'); h.slot(1).dispatch('click');
  assert.equal(h.get('profile-name').value, 'Draft'); assert.equal(h.get('profile-instructions').value, 'Do not lose this.');
  h.env.fetch = async () => { throw Error('Network offline'); };
  h.get('profile-form').dispatch('submit'); await flush();
  assert.equal(h.get('profile-name').value, 'Draft'); assert.equal(h.get('profile-instructions').value, 'Do not lose this.');
  assert.match(h.get('profiles-error').textContent, /Network offline/);
  assert.doesNotMatch(h.get('profiles-status').textContent, /saved/i);
  assert.equal(h.get('profile-save').disabled, false);
  h.slot(2).dispatch('click'); assert.equal(h.get('profile-name').value, 'Second draft');
  mounted.destroy();
});

test('validates names and instructions before sending and accepts boundary lengths', async () => {
  const h = harness([]); const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  for (const [name, instructions, error] of [['   ', '', /name/i], ['x'.repeat(61), '', /60/], ['Valid', 'x'.repeat(4001), /4000/]]) {
    h.input('profile-name', name); h.input('profile-instructions', instructions);
    h.get('profile-form').dispatch('submit'); await flush();
    assert.equal(h.requests.length, 1); assert.match(h.get('profiles-error').textContent, error);
  }
  const name = 'x'.repeat(60), instructions = 'x'.repeat(4000);
  h.env.fetch = async (_url, options) => { h.requests.push(options); return response([profile(1, name, instructions)]); };
  h.input('profile-name', name); h.input('profile-instructions', instructions); h.get('profile-form').dispatch('submit'); await flush();
  assert.equal(h.requests.length, 2); assert.equal(h.get('profiles-error').hidden, true);
  mounted.destroy();
});

test('rejects malformed snapshots and never treats an unconfirmed save as success', async () => {
  const h = harness(); const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  const invalid = [null, {}, { profiles: null }, { profiles: [profile(10)] }, { profiles: [profile(1), profile(1)] }, { profiles: [profile(1, '')] }, { profiles: [profile(1, 'x'.repeat(61))] }, { profiles: [profile(1, 'Valid', 1)] }, { profiles: [profile(1, 'Valid', 'x'.repeat(4001))] }, { profiles: [profile(1, ' untrimmed ')] }];
  for (const value of invalid) {
    h.env.fetch = async () => ({ ok: true, json: async () => value }); h.get('profiles-refresh').dispatch('click'); await flush();
    assert.match(h.get('profiles-error').textContent, /invalid profiles/i);
    assert.equal(h.get('profile-name').value, 'Official');
    assert.match(h.slot(1).textContent, /Official/);
  }
  h.input('profile-name', 'Not confirmed');
  h.env.fetch = async () => response(); h.get('profile-form').dispatch('submit'); await flush();
  assert.match(h.get('profiles-error').textContent, /did not confirm/i);
  assert.equal(h.get('profile-name').value, 'Not confirmed');
  assert.doesNotMatch(h.get('profiles-status').textContent, /saved/i);
  h.env.fetch = async () => ({ ok: false, status: 422, json: async () => ({ detail: { code: 'invalid_profile', message: 'Name must be at most 60 characters.' } }) });
  h.get('profile-form').dispatch('submit'); await flush();
  assert.match(h.get('profiles-error').textContent, /Name must be at most 60/);
  assert.equal(h.get('profile-name').value, 'Not confirmed');
  h.env.fetch = async () => ({ ok: false, status: 500, json: async () => ({ detail: { message: 'SECRET backend trace' } }) });
  h.get('profile-form').dispatch('submit'); await flush();
  assert.match(h.get('profiles-error').textContent, /500/);
  assert.doesNotMatch(h.get('profiles-error').textContent, /SECRET/);
  mounted.destroy();
});

test('delete requires inline confirmation and matching readback; failures keep saved profile and draft', async () => {
  const h = harness(); const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  h.input('profile-name', 'Unsaved work');
  h.get('profile-delete').dispatch('click');
  assert.equal(h.get('profile-delete-prompt').hidden, false); assert.equal(h.requests.length, 1);
  h.get('profile-delete-cancel').dispatch('click');
  assert.equal(h.get('profile-delete-prompt').hidden, true); assert.equal(h.get('profile-name').value, 'Unsaved work');
  h.get('profile-delete').dispatch('click');
  h.env.fetch = async (url, options) => { h.requests.push({ url, ...options }); return response(); };
  h.get('profile-delete-confirm').dispatch('click'); await flush();
  assert.equal(h.requests.at(-1).method, 'DELETE'); assert.equal(h.requests.at(-1).url, './api/profiles/1');
  assert.equal(h.requests.at(-1).headers['X-Requested-With'], 'voicepad');
  assert.equal(h.requests.at(-1).body, undefined);
  assert.match(h.get('profiles-error').textContent, /did not confirm/i);
  assert.equal(h.get('profile-name').value, 'Unsaved work'); assert.match(h.slot(1).textContent, /Official/);
  assert.doesNotMatch(h.get('profiles-status').textContent, /deleted/i);
  h.env.fetch = async () => response([]);
  h.get('profile-delete-confirm').dispatch('click'); await flush();
  assert.equal(h.get('profile-name').value, ''); assert.equal(h.get('profile-instructions').value, '');
  assert.match(h.slot(1).textContent, /Empty slot/); assert.match(h.get('profiles-status').textContent, /deleted/i);
  assert.equal(h.get('profile-delete-prompt').hidden, true); assert.equal(h.get('profile-delete').disabled, true);
  mounted.destroy();
});

test('serializes pending mutations and preserves other slot drafts across refresh', async () => {
  const h = harness(Array.from({ length: 9 }, (_, i) => profile(i + 1, `Profile ${i + 1}`)));
  const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  h.slot(9).dispatch('click'); h.input('profile-name', 'Ninth draft'); h.slot(1).dispatch('click'); h.input('profile-name', 'First draft');
  let resolve;
  h.env.fetch = (url, options) => { h.requests.push({ url, ...options }); return new Promise(done => { resolve = done; }); };
  h.get('profile-form').dispatch('submit');
  h.get('profile-form').dispatch('submit'); h.get('profiles-refresh').dispatch('click'); h.slot(9).dispatch('click'); h.get('profile-delete').dispatch('click');
  assert.equal(h.requests.length, 2); assert.match(h.get('profile-editor-title').textContent, /01/);
  assert.equal(h.get('profile-name').disabled, true); assert.equal(h.get('profile-instructions').disabled, true);
  resolve(response([profile(1, 'First draft')])); await flush();
  h.get('profiles-refresh').dispatch('click'); resolve(response([profile(1, 'Server update')])); await flush();
  assert.equal(h.get('profile-name').value, 'Server update');
  h.slot(9).dispatch('click'); assert.equal(h.get('profile-name').value, 'Ninth draft');
  assert.equal(h.get('profile-slots').children.length, 9);
  mounted.destroy();
});

test('pagehide aborts pending mutation JSON, ignores late completion and removes every listener', async () => {
  const h = harness(); const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  h.input('profile-name', 'Draft'); let resolveJSON, signal;
  h.env.fetch = async (_url, options) => { signal = options.signal; return { ok: true, json: () => new Promise(done => { resolveJSON = done; }) }; };
  h.get('profile-form').dispatch('submit'); await flush();
  h.env.dispatch('pagehide'); const status = h.get('profiles-status').textContent;
  assert.equal(signal.aborted, true);
  resolveJSON({ profiles: [profile(1, 'Draft')] }); await flush();
  assert.equal(h.get('profile-name').value, 'Draft'); assert.match(h.slot(1).textContent, /Official/);
  assert.equal(h.get('profiles-status').textContent, status);
  assert.equal(h.get('profile-save').disabled, true); assert.equal(h.get('profile-delete').disabled, true);
  for (const el of [h.env, ...h.get('profile-slots').children, ...['profile-form', 'profile-name', 'profile-instructions', 'profiles-refresh', 'profile-delete', 'profile-delete-confirm', 'profile-delete-cancel'].map(h.get)]) {
    assert.ok([...el.listeners.values()].every(listeners => listeners.size === 0));
  }
  mounted.destroy();
});

test('initial failure remains unavailable until successful retry and pagehide ignores late fetch', async () => {
  const h = harness(); h.env.fetch = async () => { throw Error('Offline'); };
  const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  assert.match(h.get('profiles-status').textContent, /unavailable/i); assert.match(h.get('profiles-error').textContent, /Offline/);
  assert.equal(h.get('profile-name').disabled, true); assert.equal(h.get('profile-save').disabled, true);
  h.env.fetch = async () => response([]); h.get('profiles-refresh').dispatch('click'); await flush();
  assert.equal(h.get('profiles-error').hidden, true); assert.equal(h.get('profile-name').disabled, false);
  let resolve, signal; h.env.fetch = (_url, options) => { signal = options.signal; return new Promise(done => { resolve = done; }); };
  h.get('profiles-refresh').dispatch('click'); mounted.destroy();
  assert.equal(signal.aborted, true); resolve(response()); await flush();
  assert.match(h.slot(1).textContent, /Empty/); assert.equal(h.get('profile-name').value, '');
});

test('page assets mount against actual element IDs with local navigation and clear formatting disclosures', async () => {
  const html = await readFile(new URL('../static/profiles.html', import.meta.url), 'utf8');
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  const h = harness(); const get = h.doc.getElementById.bind(h.doc);
  h.doc.getElementById = id => { assert.ok(ids.has(id), `Missing HTML element: ${id}`); return get(id); };
  const mounted = profiles.mountProfiles(h.doc, h.env); await flush();
  h.input('profile-name', 'New'); h.input('profile-instructions', 'Format words');
  assert.match(h.get('profile-counts').textContent, /3 \/ 60.*12 \/ 4000/);
  assert.match(h.get('profile-mode').textContent, /extra Codex.*latency.*quota/);
  mounted.destroy();
  assert.match(html, /src="\.\/profiles\.mjs"/); assert.match(html, /href="\.\/styles\.css"/);
  assert.doesNotMatch(html, /(?:src|href)="(?:https?:)?\/\//);
  assert.match(html, /<label[^>]*for="profile-name"/); assert.match(html, /<label[^>]*for="profile-instructions"/);
  assert.match(html, /<textarea[^>]*id="profile-instructions"/);
  assert.match(html, /empty instructions[\s\S]*no extra text-model request/i);
  assert.match(html, /consumes model quota/i); assert.match(html, /adds latency/i);
  assert.match(html, /Private Tailnet only/); assert.match(html, /no audio or transcripts/i);
  assert.match(html, /drafts[\s\S]*leave/i);
  for (const page of ['index', 'admin']) {
    const source = await readFile(new URL(`../static/${page}.html`, import.meta.url), 'utf8');
    assert.match(source, /href="\.\/profiles"[^>]*>Profiles/);
  }
});

test('loads full instructions and exactly nine fixed selectable slots using safe text', async () => {
  assert.equal(typeof profiles.mountProfiles, 'function');
  const unsafe = '<img src=x onerror=alert(1)>';
  const h = harness([profile(1, unsafe, unsafe)]); const mounted = profiles.mountProfiles(h.doc, h.env);
  assert.equal(h.get('profile-save').disabled, true);
  await flush();
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].url, './api/profiles');
  assert.equal(h.requests[0].method, 'GET');
  assert.equal(h.requests[0].cache, 'no-store');
  assert.equal(h.get('profile-slots').children.length, 9);
  assert.match(h.slot(1).textContent, /1/);
  assert.ok(h.slot(1).textContent.includes(unsafe));
  assert.equal(h.get('profile-name').value, unsafe);
  assert.equal(h.get('profile-instructions').value, unsafe);
  h.slot(9).dispatch('click');
  assert.equal(h.get('profile-name').value, '');
  assert.equal(h.get('profile-instructions').value, '');
  assert.match(h.get('profile-editor-title').textContent, /9/);
  assert.match(h.slot(9).textContent, /Empty/);
  assert.equal(h.get('profile-delete').disabled, true);
  assert.equal(h.slot(9).attrs['aria-pressed'], 'true');
  mounted.destroy();
});
