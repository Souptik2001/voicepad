import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const usage = await import('../static/usage.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
test('daily table renders newest 30 UTC dates with measured values and no-success dashes', async () => {
  const days = Array.from({ length: 31 }, (_, i) => ({ date: `2026-10-${String(i + 1).padStart(2, '0')}`, ...summary({ successful: 0, successful_audio_seconds: 0, successful_processing_seconds: 0, max_processing_seconds: 0, last_request_at: null }) }));
  days[30] = { date: '2026-10-31', ...summary() };
  const h = harness(payload({ days })); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  const rows = h.get('usage-days').children;
  assert.equal(rows.length, 30);
  assert.deepEqual(rows[0].children.map(cell => cell.textContent), ['2026-10-31', '3', '2', '1', '4', '3.0 min', '1.5 min', '1.50 s', '2.00 s']);
  assert.equal(rows[29].children[0].textContent, '2026-10-02');
  assert.equal(rows[1].children[7].textContent, '—');
  assert.equal(rows[1].children[8].textContent, '—');
  assert.equal(h.get('days-empty').hidden, true);
  mounted.destroy();
});

test('manual refresh preserves stale numbers on HTTP error and recovers without polling', async () => {
  const h = harness(); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  const pending = []; let calls = 0;
  h.env.fetch = () => { calls++; return new Promise(resolve => pending.push(resolve)); };
  h.get('usage-refresh').dispatch('click');
  h.get('usage-refresh').dispatch('click');
  assert.equal(calls, 1);
  assert.equal(h.get('usage-refresh').disabled, true);
  assert.match(h.get('usage-status').textContent, /Refreshing/);
  pending[0]({ ok: false, status: 503, json: async () => { throw Error('Should not read error body'); } }); await flush();
  assert.equal(h.get('requests').textContent, '3');
  assert.equal(h.get('usage-error').hidden, false);
  assert.match(h.get('usage-error').textContent, /503/);
  assert.match(h.get('usage-status').textContent, /Stale/);
  h.get('period-all').dispatch('click');
  assert.match(h.get('usage-status').textContent, /Stale/);
  assert.equal(h.get('requests').textContent, '8');
  assert.equal(h.get('usage-refresh').disabled, false);
  h.get('usage-refresh').dispatch('click');
  pending[1](response(payload({ totals: summary({ requests: 10 }) }))); await flush();
  assert.equal(h.get('requests').textContent, '10');
  assert.equal(h.get('usage-error').hidden, true);
  assert.match(h.get('usage-status').textContent, /Up to date/);
  assert.equal(calls, 2);
  mounted.destroy();
});

test('pagehide aborts pending JSON and ignores late responses and all later actions', async () => {
  const h = harness(); let resolveJSON, signal;
  h.env.fetch = async (_url, options) => { signal = options.signal; return { ok: true, json: () => new Promise(resolve => { resolveJSON = resolve; }) }; };
  const mounted = usage.mountUsage(h.doc, h.env); await flush();
  h.env.dispatch('pagehide');
  assert.equal(signal.aborted, true);
  const before = h.get('usage-status').textContent;
  resolveJSON(payload()); await flush();
  assert.equal(h.get('requests').textContent, '—');
  assert.equal(h.get('usage-status').textContent, before);
  assert.equal(h.get('usage-refresh').disabled, true);
  h.get('period-all').dispatch('click');
  assert.equal(h.get('period-all').attrs['aria-pressed'], 'false');
  mounted.destroy();
  assert.equal(h.env.listeners.get('pagehide').size, 0);
  assert.equal(h.get('usage-refresh').listeners.get('click').size, 0);
});

test('initial network failure is unavailable, never zero, and a manual retry succeeds', async () => {
  const h = harness(); h.env.fetch = async () => { throw Error('Network offline'); };
  const mounted = usage.mountUsage(h.doc, h.env); await flush();
  assert.equal(h.get('requests').textContent, '—');
  assert.equal(h.get('submitted-audio').textContent, '—');
  assert.match(h.get('usage-status').textContent, /unavailable/i);
  assert.match(h.get('usage-error').textContent, /Network offline/);
  assert.equal(h.get('usage-refresh').disabled, false);
  h.env.fetch = async () => response(payload()); h.get('usage-refresh').dispatch('click'); await flush();
  assert.equal(h.get('requests').textContent, '3');
  mounted.destroy();
});

test('invalid metrics never replace the last valid snapshot', async () => {
  const h = harness(); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  const invalid = [null, {}, payload({ today: summary({ requests: -1 }) }), payload({ today: summary({ successful: '2' }) }), payload({ timezone: 'America/New_York' }), payload({ days: [{ date: '<script>alert(1)</script>', ...summary() }] }), payload({ tracking_since: 'not-a-date' }), payload({ storage: null })];
  for (const data of invalid) {
    h.env.fetch = async () => response(data); h.get('usage-refresh').dispatch('click'); await flush();
    assert.equal(h.get('requests').textContent, '3');
    assert.match(h.get('usage-error').textContent, /invalid metrics/i);
    assert.match(h.get('usage-status').textContent, /Stale/);
  }
  mounted.destroy();
});

test('usage assets wire a mountable page, relative navigation and local responsive styles', async () => {
  const html = await readFile(new URL('../static/usage.html', import.meta.url), 'utf8');
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  const h = harness();
  const get = h.doc.getElementById.bind(h.doc);
  h.doc.getElementById = id => { assert.ok(ids.has(id), `Missing HTML element: ${id}`); return get(id); };
  const mounted = usage.mountUsage(h.doc, h.env); await flush();
  assert.equal(h.get('requests').textContent, '3');
  mounted.destroy();
  assert.match(html, /src="\.\/usage\.mjs"/);
  assert.match(html, /href="\.\/styles\.css"/);
  assert.doesNotMatch(html, /(?:src|href)="(?:https?:)?\/\//);
  for (const page of ['index', 'admin']) {
    const source = await readFile(new URL(`../static/${page}.html`, import.meta.url), 'utf8');
    assert.match(source, /href="\.\/usage"[^>]*>Usage/);
  }
  assert.match(html, /No backfill/i);
  assert.match(html, /metadata only/i);
  assert.match(html, /no audio or transcripts/i);
  assert.match(html, /401/);
  assert.match(html, /not.*recording time/i);
  assert.match(html, /<caption[^>]*>[^<]*UTC/);
});

test('formatting shows its own all-time calls and measured tokens without changing audio or quota', async () => {
  const formatting = {
    tracking_since: '2026-11-11T10:00:00Z', storage_healthy: true, note: 'Formatting metadata saved locally.',
    totals: { calls: 5, successful: 3, failed: 2, input_tokens: 1200, output_tokens: 34, total_tokens: 1234, unreported: 1 },
  };
  const h = harness(payload({ formatting })); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  const expected = {
    'formatting-provider-calls': '5', 'formatting-successful': '3', 'formatting-failed': '2',
    'formatting-input-tokens': '1,200', 'formatting-output-tokens': '34', 'formatting-total-tokens': '1,234',
    'formatting-unreported': '1', 'formatting-tracking-since': '2026-11-11 10:00:00 UTC',
  };
  for (const period of ['period-today', 'period-all', 'period-today']) {
    h.get(period).dispatch('click');
    for (const [id, value] of Object.entries(expected)) assert.equal(h.get(id).textContent, value, id);
    assert.equal(h.get('formatting-title').textContent, 'Formatting · all time');
    for (const id of ['quota-tokens', 'quota-subscription', 'quota-cost']) assert.equal(h.get(id).textContent, 'Unknown');
  }
  assert.equal(h.get('submitted-audio').textContent, '3.0 min');
  assert.equal(h.get('provider-calls').textContent, '4');
  assert.equal(h.get('requests').textContent, '3');
  assert.equal(h.get('formatting-storage-status').textContent, 'Storage healthy · Formatting metadata saved locally.');
  assert.equal(h.requests.length, 1);
  mounted.destroy();
});

test('absent or partial formatting stays available as missing data, never invented zeros', async () => {
  for (const formatting of [undefined, null, {}, { totals: { calls: 0, successful: 0, input_tokens: null, output_tokens: '12', total_tokens: -1, failed: 1.5, unreported: Number.MAX_SAFE_INTEGER + 1 }, tracking_since: 'invalid' }]) {
    const h = harness(payload({ formatting })); const mounted = usage.mountUsage(h.doc, h.env); await flush();
    assert.equal(h.get('requests').textContent, '3');
    assert.equal(h.get('usage-error').hidden, true);
    for (const id of ['failed', 'input-tokens', 'output-tokens', 'total-tokens', 'unreported', 'tracking-since', 'storage-status']) {
      assert.equal(h.get(`formatting-${id}`).textContent, 'Not available', id);
    }
    assert.equal(h.get('formatting-provider-calls').textContent, formatting?.totals ? '0' : 'Not available');
    assert.equal(h.get('formatting-successful').textContent, formatting?.totals ? '0' : 'Not available');
    mounted.destroy();
  }
});

test('formatting storage failure marks measured values incomplete and renders provider notes as text', async () => {
  const formatting = {
    tracking_since: '2026-11-11T10:00:00Z', storage_healthy: false, note: '<img src=x onerror=alert(1)>',
    totals: { calls: 4, successful: 2, failed: 2, input_tokens: 50, output_tokens: 5, total_tokens: 55, unreported: 1 },
  };
  const h = harness(payload({ formatting })); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  for (const [id, value] of [['provider-calls', 4], ['successful', 2], ['failed', 2], ['input-tokens', 50], ['output-tokens', 5], ['total-tokens', 55], ['unreported', 1]]) {
    assert.equal(h.get(`formatting-${id}`).textContent, `${value} · incomplete`);
  }
  assert.equal(h.get('formatting-storage-status').textContent, 'Storage warning · Formatting values may be incomplete. · <img src=x onerror=alert(1)>');
  assert.equal(h.get('formatting-storage-status').attrs['data-healthy'], 'false');
  assert.equal(h.get('submitted-audio').textContent, '3.0 min');
  mounted.destroy();
});

const flush = () => new Promise(resolve => setImmediate(resolve));
class Element {
  constructor(tagName = 'DIV') {
    this.tagName = tagName;
    this.listeners = new Map(); this.attrs = {}; this.children = [];
    this.textContent = ''; this.hidden = false; this.disabled = false;
  }
  addEventListener(name, fn) { if (!this.listeners.has(name)) this.listeners.set(name, new Set()); this.listeners.get(name).add(fn); }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  dispatch(name) { for (const fn of this.listeners.get(name) ?? []) fn({ target: this }); }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  set innerHTML(_) { throw Error('Unsafe HTML assignment'); }
}
const summary = (overrides = {}) => ({
  requests: 3, successful: 2, failed: 1, provider_calls: 4,
  submitted_audio_seconds: 180, successful_audio_seconds: 90,
  successful_processing_seconds: 3, max_processing_seconds: 2,
  last_request_at: '2026-11-11T12:34:56Z', ...overrides,
});
const payload = (overrides = {}) => ({
  tracking_since: '2026-11-10T20:00:00Z', timezone: 'UTC',
  quota: { tokens: null, subscription_percent: null, cost_usd: null, note: 'OpenAI does not report token, subscription quota or cost usage for this endpoint.' },
  totals: summary({ requests: 8, successful: 5, failed: 3, provider_calls: 10, submitted_audio_seconds: 600, successful_audio_seconds: 300, successful_processing_seconds: 20, max_processing_seconds: 7 }),
  today: summary(), days: [{ date: '2026-11-11', ...summary() }],
  retention_days: 366, storage: { healthy: true, note: 'Usage metadata saved locally.' }, ...overrides,
});
const response = data => ({ ok: true, status: 200, json: async () => data });
function harness(data = payload()) {
  const elements = new Map();
  const doc = { getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); }, createElement: name => new Element(name.toUpperCase()) };
  const env = new Element(); const requests = [];
  Object.assign(env, { AbortController, fetch: async (url, options) => { requests.push({ url, ...options }); return response(data); } });
  return { doc, env, requests, get: id => doc.getElementById(id) };
}

test('mount fetches relative metrics once and displays measured today values', async () => {
  assert.equal(typeof usage.mountUsage, 'function');
  const h = harness();
  const mounted = usage.mountUsage(h.doc, h.env);
  assert.equal(h.get('usage-refresh').disabled, true);
  assert.equal(h.get('requests').textContent, '—');
  await flush();
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].url, './api/metrics');
  assert.equal(h.requests[0].method, 'GET');
  assert.equal(h.requests[0].cache, 'no-store');
  assert.equal(h.get('submitted-audio').textContent, '3.0 min');
  assert.equal(h.get('successful-audio').textContent, '1.5 min');
  assert.equal(h.get('requests').textContent, '3');
  assert.equal(h.get('successful').textContent, '2');
  assert.equal(h.get('failed').textContent, '1');
  assert.equal(h.get('provider-calls').textContent, '4');
  assert.equal(h.get('avg-latency').textContent, '1.50 s');
  assert.equal(h.get('max-latency').textContent, '2.00 s');
  assert.equal(h.get('last-request').textContent, '2026-11-11 12:34:56 UTC');
  assert.equal(h.get('usage-refresh').disabled, false);
  mounted.destroy();
});

test('metadata stays explicit about unknown quota, UTC tracking and storage health', async () => {
  const data = payload({ storage: { healthy: false, note: '<img src=x onerror=alert(1)>' } });
  const h = harness(data); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  assert.equal(h.get('tracking-since').textContent, '2026-11-10 20:00:00 UTC');
  assert.equal(h.get('timezone').textContent, 'UTC');
  assert.equal(h.get('quota-note').textContent, data.quota.note);
  for (const id of ['quota-tokens', 'quota-subscription', 'quota-cost']) assert.equal(h.get(id).textContent, 'Unknown');
  assert.equal(h.get('retention-days').textContent, '366 days');
  assert.equal(h.get('storage-status').textContent, 'Storage warning · <img src=x onerror=alert(1)>');
  assert.equal(h.get('storage-status').attrs['data-healthy'], 'false');
  mounted.destroy();
});

test('empty usage shows real zeros, no latency, no requests and an explicit empty daily table', async () => {
  const zero = summary({ requests: 0, successful: 0, failed: 0, provider_calls: 0, submitted_audio_seconds: 0, successful_audio_seconds: 0, successful_processing_seconds: 0, max_processing_seconds: 0, last_request_at: null });
  const h = harness(payload({ today: zero, totals: zero, days: [] }));
  const mounted = usage.mountUsage(h.doc, h.env); await flush();
  assert.equal(h.get('requests').textContent, '0');
  assert.equal(h.get('submitted-audio').textContent, '0.0 min');
  assert.equal(h.get('avg-latency').textContent, '—');
  assert.equal(h.get('max-latency').textContent, '—');
  assert.equal(h.get('last-request').textContent, 'No requests yet');
  assert.equal(h.get('usage-days').children.length, 0);
  assert.equal(h.get('days-empty').hidden, false);
  assert.equal(h.get('days-empty').textContent, 'No requests in the last 30 days. Usage before tracking began is not available.');
  assert.equal(h.get('usage-status').textContent, 'Up to date · no requests in this period.');
  mounted.destroy();
});

test('period controls switch to all-time without another fetch and back to today', async () => {
  const h = harness(); const mounted = usage.mountUsage(h.doc, h.env); await flush();
  h.get('period-all').dispatch('click');
  assert.equal(h.get('requests').textContent, '8');
  assert.equal(h.get('submitted-audio').textContent, '10.0 min');
  assert.equal(h.get('successful-audio').textContent, '5.0 min');
  assert.equal(h.get('avg-latency').textContent, '4.00 s');
  assert.equal(h.get('max-latency').textContent, '7.00 s');
  assert.equal(h.get('period-all').attrs['aria-pressed'], 'true');
  assert.equal(h.get('period-today').attrs['aria-pressed'], 'false');
  assert.equal(h.get('period-label').textContent, 'All time · since tracking began');
  h.get('period-today').dispatch('click');
  assert.equal(h.get('requests').textContent, '3');
  assert.equal(h.get('period-label').textContent, 'Today · UTC');
  assert.equal(h.requests.length, 1);
  mounted.destroy();
});
