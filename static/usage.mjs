const number = value => Number.isFinite(value) && value >= 0;
const count = value => number(value) ? value.toLocaleString('en-US') : '—';
const minutes = value => number(value) ? `${(value / 60).toFixed(1)} min` : '—';
const seconds = value => number(value) ? `${value.toFixed(2)} s` : '—';
const timestamp = value => {
  const date = new Date(value);
  return value && Number.isFinite(date.getTime()) ? `${date.toISOString().slice(0, 19).replace('T', ' ')} UTC` : 'No requests yet';
};

const validTimestamp = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
const validSummary = value => value && ['requests', 'successful', 'failed', 'provider_calls'].every(key => Number.isSafeInteger(value[key]) && value[key] >= 0) && ['submitted_audio_seconds', 'successful_audio_seconds', 'successful_processing_seconds', 'max_processing_seconds'].every(key => number(value[key])) && (value.last_request_at === null || validTimestamp(value.last_request_at));
function validateMetrics(value) {
  if (!value || value.timezone !== 'UTC' || !validTimestamp(value.tracking_since) || !validSummary(value.today) || !validSummary(value.totals) || !Array.isArray(value.days) || !value.days.every(day => /^\d{4}-\d{2}-\d{2}$/.test(day.date) && validSummary(day)) || !Number.isSafeInteger(value.retention_days) || value.retention_days <= 0 || typeof value.storage?.healthy !== 'boolean' || typeof value.storage.note !== 'string' || typeof value.quota?.note !== 'string') throw Error('The server returned invalid metrics. Refresh to try again.');
  return value;
}

export function mountUsage(doc, env) {
  const $ = id => doc.getElementById(id);
  let data = null, period = 'today', busy = false, errorMessage = '';
  let destroyed = false, generation = 0, controller = null;
  const render = () => {
    const summary = period === 'today' ? data?.today : data?.totals;
    $('period-today').setAttribute('aria-pressed', String(period === 'today'));
    $('period-all').setAttribute('aria-pressed', String(period === 'all'));
    $('period-label').textContent = period === 'today' ? 'Today · UTC' : 'All time · since tracking began';
    $('submitted-audio').textContent = minutes(summary?.submitted_audio_seconds);
    $('successful-audio').textContent = minutes(summary?.successful_audio_seconds);
    for (const [id, key] of [['requests', 'requests'], ['successful', 'successful'], ['failed', 'failed'], ['provider-calls', 'provider_calls']]) $(id).textContent = count(summary?.[key]);
    $('avg-latency').textContent = seconds(summary?.successful > 0 ? summary.successful_processing_seconds / summary.successful : null);
    $('max-latency').textContent = seconds(summary?.successful > 0 ? summary.max_processing_seconds : null);
    $('last-request').textContent = summary ? timestamp(summary.last_request_at) : '—';
    $('tracking-since').textContent = data ? timestamp(data.tracking_since) : 'Loading…';
    $('timezone').textContent = 'UTC';
    for (const id of ['quota-tokens', 'quota-subscription', 'quota-cost']) $(id).textContent = 'Unknown';
    $('quota-note').textContent = data?.quota?.note || 'OpenAI does not report token, subscription quota or cost usage for this endpoint.';
    $('retention-days').textContent = data ? `${count(data.retention_days)} days` : '—';
    $('storage-status').textContent = data ? `${data.storage.healthy ? 'Storage healthy' : 'Storage warning'} · ${data.storage.note}` : 'Checking storage…';
    $('storage-status').setAttribute('data-healthy', String(data?.storage?.healthy === true));
    const formatting = data?.formatting;
    const formattingIncomplete = formatting?.storage_healthy === false;
    $('formatting-title').textContent = 'Formatting · all time';
    for (const [id, key] of [['provider-calls', 'calls'], ['successful', 'successful'], ['failed', 'failed'], ['input-tokens', 'input_tokens'], ['output-tokens', 'output_tokens'], ['total-tokens', 'total_tokens'], ['unreported', 'unreported']]) {
      const value = formatting?.totals?.[key];
      $(`formatting-${id}`).textContent = Number.isSafeInteger(value) && value >= 0 ? `${count(value)}${formattingIncomplete ? ' · incomplete' : ''}` : 'Not available';
    }
    $('formatting-tracking-since').textContent = validTimestamp(formatting?.tracking_since) ? timestamp(formatting.tracking_since) : 'Not available';
    $('formatting-storage-status').textContent = typeof formatting?.storage_healthy === 'boolean' ? `${formattingIncomplete ? 'Storage warning · Formatting values may be incomplete.' : 'Storage healthy'} · ${typeof formatting.note === 'string' ? formatting.note : 'Not available'}` : 'Not available';
    $('formatting-storage-status').setAttribute('data-healthy', String(formatting?.storage_healthy === true));
    const days = [...(data?.days || [])].sort((a, b) => b.date.localeCompare(a.date)).slice(0, 30);
    $('usage-days').replaceChildren(...days.map(day => {
      const row = doc.createElement('tr');
      const values = [day.date, count(day.requests), count(day.successful), count(day.failed), count(day.provider_calls), minutes(day.submitted_audio_seconds), minutes(day.successful_audio_seconds), seconds(day.successful > 0 ? day.successful_processing_seconds / day.successful : null), seconds(day.successful > 0 ? day.max_processing_seconds : null)];
      for (const [index, value] of values.entries()) {
        const cell = doc.createElement(index === 0 ? 'th' : 'td');
        if (index === 0) cell.setAttribute('scope', 'row');
        cell.textContent = value; row.append(cell);
      }
      return row;
    }));
    $('days-empty').hidden = days.length > 0 || !data;
    $('days-empty').textContent = 'No requests in the last 30 days. Usage before tracking began is not available.';
    $('usage-status').textContent = busy ? (data ? 'Refreshing · showing previous numbers…' : 'Loading usage…') : errorMessage ? (data ? 'Stale · showing last successful refresh.' : 'Usage unavailable · refresh to try again.') : data ? (summary.requests === 0 ? 'Up to date · no requests in this period.' : 'Up to date · refresh to check for new usage.') : 'Loading usage…';
    $('usage-error').textContent = errorMessage;
    $('usage-error').hidden = !errorMessage;
    $('usage-refresh').disabled = busy;
  };
  const refresh = async () => {
    if (busy || destroyed) return;
    const current = ++generation;
    controller = new env.AbortController();
    busy = true; errorMessage = ''; render();
    try {
      const result = await env.fetch('./api/metrics', { method: 'GET', cache: 'no-store', signal: controller.signal });
      if (destroyed || current !== generation) return;
      if (!result.ok) throw Error(`Could not load usage (HTTP ${result.status}).`);
      const next = await result.json();
      if (destroyed || current !== generation) return;
      data = validateMetrics(next);
    } catch (error) {
      if (destroyed || current !== generation) return;
      errorMessage = error.message || 'Could not load usage. Refresh to try again.';
    } finally {
      if (!destroyed && current === generation) { controller = null; busy = false; render(); }
    }
  };
  const today = () => { if (!destroyed) { period = 'today'; render(); } };
  const all = () => { if (!destroyed) { period = 'all'; render(); } };
  const destroy = () => {
    if (destroyed) return;
    destroyed = true; generation++; controller?.abort(); controller = null;
    $('usage-refresh').disabled = true;
    $('usage-refresh').removeEventListener('click', refresh);
    $('period-today').removeEventListener('click', today);
    $('period-all').removeEventListener('click', all);
    env.removeEventListener('pagehide', destroy);
  };
  $('usage-refresh').addEventListener('click', refresh);
  $('period-today').addEventListener('click', today);
  $('period-all').addEventListener('click', all);
  env.addEventListener('pagehide', destroy);
  render(); refresh();
  return { destroy };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') mountUsage(document, window);
