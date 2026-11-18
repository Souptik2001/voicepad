const length = value => [...value].length;
function validateProfiles(value) {
  if (!Array.isArray(value?.profiles) || value.profiles.length > 9) throw Error('The server returned invalid profiles. Retry to load.');
  const next = new Map();
  for (const profile of value.profiles) {
    if (!Number.isInteger(profile?.slot) || profile.slot < 1 || profile.slot > 9 || next.has(profile.slot) || typeof profile.name !== 'string' || !profile.name.trim() || profile.name !== profile.name.trim() || length(profile.name) > 60 || typeof profile.instructions !== 'string' || length(profile.instructions) > 4000) throw Error('The server returned invalid profiles. Retry to load.');
    next.set(profile.slot, { slot: profile.slot, name: profile.name, instructions: profile.instructions });
  }
  return next;
}

export function mountProfiles(doc, env) {
  const $ = id => doc.getElementById(id);
  let data = new Map(), selected = 1, loaded = false, busy = false, destroyed = false;
  let controller = null, generation = 0, errorMessage = '', message = '', confirmingDelete = false;
  const drafts = new Map(), listeners = [];
  const listen = (target, name, fn) => { target.addEventListener(name, fn); listeners.push(() => target.removeEventListener(name, fn)); };
  const draft = () => drafts.get(selected) || data.get(selected) || { name: '', instructions: '' };
  const dirty = () => {
    const saved = data.get(selected) || { name: '', instructions: '' }, current = draft();
    return current.name !== saved.name || current.instructions !== saved.instructions;
  };
  const slots = Array.from({ length: 9 }, (_, index) => {
    const slot = index + 1, button = doc.createElement('button');
    button.type = 'button'; button.className = 'profile-slot';
    listen(button, 'click', () => { if (!destroyed && !busy && loaded) { selected = slot; message = ''; errorMessage = ''; confirmingDelete = false; populate(); render(); } });
    return button;
  });
  $('profile-slots').replaceChildren(...slots);
  const populate = () => {
    const value = draft();
    $('profile-name').value = value.name;
    $('profile-instructions').value = value.instructions;
  };
  const render = () => {
    for (const [index, button] of slots.entries()) {
      const slot = index + 1;
      button.textContent = `${slot.toString().padStart(2, '0')} · ${data.get(slot)?.name || (loaded ? 'Empty slot' : 'Loading…')}${drafts.has(slot) ? ' · draft' : ''}`;
      button.setAttribute('aria-pressed', String(selected === slot));
      button.disabled = busy || !loaded || destroyed;
    }
    $('profile-editor-title').textContent = `Slot ${selected.toString().padStart(2, '0')}`;
    $('profile-save').disabled = busy || !loaded || destroyed || !dirty();
    $('profile-delete').disabled = busy || !loaded || destroyed || !data.has(selected);
    $('profile-delete-prompt').hidden = !confirmingDelete;
    $('profile-delete-confirm').disabled = busy || destroyed;
    $('profile-delete-cancel').disabled = busy || destroyed;
    $('profiles-refresh').disabled = busy || destroyed;
    $('profile-name').disabled = busy || !loaded || destroyed;
    $('profile-instructions').disabled = busy || !loaded || destroyed;
    $('profile-counts').textContent = `Name ${length(draft().name.trim())} / 60 · Instructions ${length(draft().instructions)} / 4000`;
    $('profile-mode').textContent = draft().instructions.trim() ? 'Formatting · adds an extra Codex text-model request, latency and model quota usage.' : 'Raw transcription · no extra text-model request. Empty instructions leave your words unchanged.';
    $('profiles-status').textContent = busy ? (message || 'Loading profiles…') : errorMessage ? (loaded ? 'Not confirmed. Your drafts are kept on this page.' : 'Profiles unavailable. Retry to load.') : message || (dirty() ? 'Unsaved draft · kept on this page until you leave.' : loaded ? 'Profiles loaded.' : 'Profiles unavailable. Retry to load.');
    $('profiles-error').textContent = errorMessage;
    $('profiles-error').hidden = !errorMessage;
  };
  const request = async (method = 'GET', body) => {
    if (busy || destroyed) return;
    const current = ++generation, slot = selected;
    controller = new env.AbortController(); busy = true; errorMessage = '';
    message = method === 'PUT' ? 'Saving profile…' : method === 'DELETE' ? 'Deleting profile…' : 'Loading profiles…'; render();
    try {
      const options = { method, cache: 'no-store', signal: controller.signal };
      if (method !== 'GET') options.headers = { 'X-Requested-With': 'voicepad', 'Content-Type': 'application/json' };
      if (body) options.body = JSON.stringify(body);
      const result = await env.fetch(`./api/profiles${method === 'GET' ? '' : `/${slot}`}`, options);
      if (destroyed || generation !== current) return;
      if (!result.ok) {
        let detail;
        if ([400, 422].includes(result.status)) { try { detail = (await result.json())?.detail; } catch {} }
        if (destroyed || generation !== current) return;
        throw Error(typeof detail?.message === 'string' && typeof detail.code === 'string' ? detail.message : `Could not ${method === 'GET' ? 'load' : method === 'DELETE' ? 'delete' : 'save'} profiles (HTTP ${result.status}).`);
      }
      const value = await result.json();
      if (destroyed || generation !== current) return;
      const next = validateProfiles(value);
      if (method === 'PUT' && (next.get(slot)?.name !== body.name || next.get(slot)?.instructions !== body.instructions)) throw Error('The server did not confirm this profile. Your draft is kept; retry or refresh.');
      if (method === 'DELETE' && next.has(slot)) throw Error('The server did not confirm deletion. Your profile and draft are kept.');
      data = next; loaded = true;
      if (method !== 'GET') drafts.delete(slot);
      confirmingDelete = false;
      populate(); message = method === 'PUT' ? `Slot ${slot} saved.` : method === 'DELETE' ? `Slot ${slot} deleted.` : 'Profiles loaded. Existing drafts are kept.';
    } catch (error) {
      if (!destroyed && generation === current) { errorMessage = error.message || 'Could not update profiles. Retry to try again.'; message = ''; }
    } finally {
      if (!destroyed && generation === current) { busy = false; controller = null; render(); }
    }
  };
  const refresh = () => request();
  const input = () => {
    if (destroyed || busy || !loaded) return;
    drafts.set(selected, { name: $('profile-name').value, instructions: $('profile-instructions').value });
    if (!dirty()) drafts.delete(selected);
    message = ''; errorMessage = ''; confirmingDelete = false; render();
  };
  const save = event => {
    event.preventDefault();
    if (destroyed || busy || !loaded || !dirty()) return;
    const value = draft();
    if (!value.name.trim() || length(value.name.trim()) > 60 || length(value.instructions) > 4000) {
      errorMessage = !value.name.trim() ? 'Enter a profile name.' : length(value.name.trim()) > 60 ? 'Name must be at most 60 characters.' : 'Instructions must be at most 4000 characters.';
      message = ''; render(); return;
    }
    request('PUT', { name: value.name.trim(), instructions: value.instructions });
  };
  const destroy = () => {
    if (destroyed) return;
    destroyed = true; generation++; controller?.abort(); controller = null;
    for (const remove of listeners) remove();
    render();
  };
  listen($('profiles-refresh'), 'click', refresh);
  listen($('profile-form'), 'submit', save);
  listen($('profile-name'), 'input', input);
  listen($('profile-instructions'), 'input', input);
  listen($('profile-delete'), 'click', () => {
    if (destroyed || busy || !loaded || !data.has(selected)) return;
    confirmingDelete = true; errorMessage = ''; message = ''; render();
  });
  listen($('profile-delete-cancel'), 'click', () => {
    if (destroyed || busy) return;
    confirmingDelete = false; render();
  });
  listen($('profile-delete-confirm'), 'click', () => {
    if (confirmingDelete && data.has(selected)) request('DELETE');
  });
  listen(env, 'pagehide', destroy);
  render(); refresh();
  return { destroy };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') mountProfiles(document, window);
