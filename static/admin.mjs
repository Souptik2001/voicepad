import { createApi, clearLegacyAccess } from './core.mjs';

const DEVICE_URL = 'https://auth.openai.com/codex/device';

export function mountAdmin(doc, env) {
  clearLegacyAccess(env);
  const $ = id => doc.getElementById(id);
  const api = createApi({ fetch: (...args) => env.fetch(...args) });
  let status = { connected: false, auth_state: 'disconnected', login: { state: 'idle' } };
  let timer = null, generation = 0, destroyed = false, busy = true;
  const clearPoll = () => { if (timer !== null) env.clearTimeout(timer); timer = null; };
  const showError = message => { $('admin-error').textContent = message || ''; $('admin-error').hidden = !message; };
  const render = () => {
    const pending = status.login?.state === 'pending';
    $('auth-state').textContent = status.auth_state === 'connected' ? 'Connected' : status.auth_state === 'reconnect_required' ? 'Reconnect required' : 'Disconnected';
    $('credential-expiry').textContent = status.credential_expires_at || 'Not reported';
    $('auto-refresh').textContent = status.connected && status.auto_refresh ? 'Enabled' : 'Enabled after connection';
    $('last-refresh').textContent = status.last_refresh_at || 'Not refreshed yet';
    $('last-error').textContent = status.last_error || 'None';
    $('refresh-retry').textContent = status.refresh_retry_at || 'Not scheduled';
    $('connect').disabled = busy || pending || status.connected;
    $('refresh').disabled = busy || !status.connected || pending;
    $('disconnect').disabled = busy || !status.connected;
    $('cancel-login').hidden = !pending;
    $('cancel-login').disabled = busy;
    $('login-code-panel').hidden = !pending;
    $('user-code').textContent = pending ? status.login.user_code || '' : '';
    $('login-expires').textContent = pending ? status.login.expires_at || 'Not reported' : '';
    $('verification-link').setAttribute('href', DEVICE_URL);
    $('login-state').textContent = pending ? 'Waiting for you to complete sign-in on OpenAI…' : status.login?.state === 'expired' ? 'This login code expired. Start a new sign-in.' : status.login?.state === 'connected' ? 'Codex connected.' : 'Sign in with your own Codex account, independently of Hermes.';
    showError(status.login?.error);
  };
  const schedule = () => {
    clearPoll();
    if (!destroyed && status.login?.state === 'pending') timer = env.setTimeout(() => { timer = null; load(); }, 3000);
  };
  const load = async () => {
    const current = ++generation;
    try {
      const result = await api.adminStatus();
      if (destroyed || current !== generation) return;
      status = result; busy = false; render(); schedule();
    } catch (error) {
      if (destroyed || current !== generation) return;
      busy = false; render(); showError(error.message); schedule();
    }
  };
  $('connect').addEventListener('click', async () => {
    if (busy || status.connected || status.login?.state === 'pending' || destroyed) return;
    const current = ++generation;
    busy = true; clearPoll(); render();
    try {
      const login = await api.login();
      if (destroyed || current !== generation) return;
      status = { ...status, login }; busy = false; render(); schedule();
    } catch (error) {
      if (destroyed || current !== generation) return;
      busy = false; render(); showError(error.message);
    }
  });
  $('cancel-login').addEventListener('click', async () => {
    if (busy || destroyed || status.login?.state !== 'pending') return;
    const current = ++generation;
    busy = true; clearPoll(); render();
    try {
      const result = await api.cancelLogin();
      if (destroyed || current !== generation) return;
      status = result; busy = false; render(); schedule();
    } catch (error) {
      if (destroyed || current !== generation) return;
      busy = false; render(); showError(error.message); schedule();
    }
  });
  $('disconnect').addEventListener('click', async () => {
    if (busy || destroyed || !status.connected) return;
    if (!env.confirm('Disconnect this Codex grant locally? This does not revoke access at OpenAI or sign out other apps.')) return;
    const current = ++generation;
    busy = true; clearPoll(); render();
    try {
      const result = await api.disconnect();
      if (destroyed || current !== generation) return;
      status = result; busy = false; render(); schedule();
    } catch (error) {
      if (destroyed || current !== generation) return;
      busy = false; render(); showError(error.message); schedule();
    }
  });
  $('refresh').addEventListener('click', async () => {
    if (busy || destroyed || !status.connected || status.login?.state === 'pending') return;
    const current = ++generation;
    busy = true; clearPoll(); render();
    try {
      const result = await api.refresh();
      if (destroyed || current !== generation) return;
      status = result; busy = false; render(); schedule();
    } catch (error) {
      if (destroyed || current !== generation) return;
      try {
        const result = await api.adminStatus();
        if (destroyed || current !== generation) return;
        status = result;
      } catch {}
      if (destroyed || current !== generation) return;
      busy = false; render(); showError(error.message); schedule();
    }
  });
  const destroy = () => { destroyed = true; generation++; clearPoll(); };
  env.addEventListener('pagehide', destroy);
  render(); load();
  return { destroy };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') mountAdmin(document, window);
