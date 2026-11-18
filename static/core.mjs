export function chooseMimeType(isSupported) {
  return ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'].find(isSupported) || '';
}

export function createApi(deps) {
  const request = async (path, options = {}) => {
    const mutation = options.method && options.method !== 'GET';
    const response = await deps.fetch(path, { ...options, cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', headers: { ...options.headers, ...(mutation ? { 'X-Requested-With': 'voicepad' } : {}) } });
    let data;
    try { data = await response.json(); } catch { throw new Error(`Server returned an unreadable response (${response.status}).`); }
    if (!response.ok) throw new Error(data.error || `Request failed (${response.status}).`);
    return data;
  };
  const adminMutation = action => request(`./api/admin/${action}`, { method: 'POST', body: '{}', headers: { 'Content-Type': 'application/json' } });
  return {
    status: () => request('./api/status'),
    adminStatus: () => request('./api/admin/status'),
    refresh: () => adminMutation('refresh'),
    disconnect: () => adminMutation('disconnect'),
    cancelLogin: () => adminMutation('cancel'),
    login: () => adminMutation('login'),
    transcribe: (blob, signal) => request('./api/transcribe', { method: 'POST', body: blob, signal, headers: { 'Content-Type': blob.type || 'application/octet-stream', 'X-Requested-With': 'voicepad' } }),
  };
}

export function clearLegacyAccess(env) {
  if (env.location.hash || env.location.search) env.history.replaceState(null, '', env.location.pathname);
  try { env.sessionStorage.removeItem('voicepad.key'); } catch {}
}

export function createVoiceSession(deps) {
  let state = { phase: 'idle', text: '', error: '', seconds: 0, level: 0, result: null };
  let stream, recorder, monitor, timer, started;
  let generation = 0;
  const emit = patch => { state = { ...state, ...patch }; deps.onChange?.({ ...state }); };
  const cleanup = () => {
    stream?.getTracks().forEach(track => track.stop()); stream = null;
    monitor?.close(); monitor = null;
    if (timer != null) deps.clearInterval(timer);
    timer = null;
  };
  const fail = message => {
    generation++;
    if (recorder?.state === 'recording') recorder.stop();
    cleanup();
    emit({ phase: 'idle', error: message, level: 0 });
  };
  const upload = async (blob, current) => {
    try {
      if (!blob.size) throw new Error('No audio captured. Please try again.');
      if (blob.size > 25 * 1024 * 1024) throw new Error('Audio exceeds the 25 MB limit. Use a shorter clip.');
      emit({ phase: 'uploading', error: '', level: 0 });
      const result = await deps.upload(blob);
      if (!result || typeof result.text !== 'string') throw new Error('The provider did not return a valid transcript. Please try again.');
      if (current === generation) emit({ phase: 'idle', text: result.text, result });
    } catch (error) { if (current === generation) emit({ phase: 'idle', error: error.message }); }
  };
  return {
    snapshot: () => ({ ...state }),
    edit: text => emit({ text }),
    async uploadFile(blob) {
      if (state.phase !== 'idle') return;
      await upload(blob, ++generation);
    },
    cancel() {
      generation++;
      if (recorder?.state === 'recording') recorder.stop();
      cleanup();
      emit({ phase: 'idle', level: 0 });
    },
    async start() {
      if (state.phase !== 'idle') return;
      const current = ++generation;
      emit({ phase: 'requesting', error: '' });
      try {
      const acquired = await deps.getUserMedia();
      if (current !== generation) { acquired.getTracks().forEach(track => track.stop()); return; }
      stream = acquired;
      recorder = deps.createRecorder(stream);
      monitor = deps.monitor?.(stream);
      const chunks = [];
      let bytes = 0;
      recorder.onerror = event => { if (current === generation) fail(event.error?.message || 'The microphone stopped unexpectedly.'); };
      recorder.ondataavailable = event => {
        if (current !== generation || !event.data.size) return;
        bytes += event.data.size;
        if (bytes > 25 * 1024 * 1024) { fail('Audio exceeds the 25 MB limit. Use a shorter clip.'); return; }
        chunks.push(event.data);
      };
      recorder.onstop = async () => {
        if (current !== generation) return;
        cleanup();
        await upload(new Blob(chunks, { type: recorder.mimeType }), current);
      };
      started = deps.now();
      recorder.start(250);
      timer = deps.setInterval(() => {
        const seconds = Math.min(600, (deps.now() - started) / 1000);
        emit({ seconds, level: monitor?.level() ?? 0 });
        // Leave 200 ms for container/encoder padding below the server's 600 s cap.
        if (seconds >= 599.8) { emit({ phase: 'stopping', level: 0 }); recorder.stop(); cleanup(); }
      }, 100);
      emit({ phase: 'recording', seconds: 0 });
      } catch (error) {
        if (current === generation) fail(error.message);
      }
    },
    stop() {
      if (state.phase === 'requesting') { generation++; emit({ phase: 'idle' }); }
      else if (state.phase === 'recording' && recorder?.state === 'recording') { emit({ phase: 'stopping', level: 0 }); recorder.stop(); }
      cleanup();
    },
  };
}
