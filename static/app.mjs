import { createApi, clearLegacyAccess, createVoiceSession, chooseMimeType } from './core.mjs';

export function createAudioMonitor(stream, env) {
  const Context = env.AudioContext || env.webkitAudioContext;
  if (!Context) return null;
  const context = new Context();
  let source, analyser;
  try {
    analyser = context.createAnalyser(); analyser.fftSize = 256;
    source = context.createMediaStreamSource(stream); source.connect(analyser);
    const samples = new Uint8Array(analyser.fftSize);
    return {
      level() {
        analyser.getByteTimeDomainData(samples);
        let sum = 0;
        for (const value of samples) sum += ((value - 128) / 128) ** 2;
        return Math.min(1, Math.sqrt(sum / samples.length) * 3);
      },
      close() { source.disconnect(); analyser.disconnect(); context.close().catch(() => {}); },
    };
  } catch { source?.disconnect(); analyser?.disconnect(); context.close().catch(() => {}); return null; }
}

export function mountVoicepad(doc, env) {
  const $ = id => doc.getElementById(id);
  clearLegacyAccess(env);
  let ready = false;
  let statusGeneration = 0;
  let uploadController;
  const micAvailable = env.isSecureContext && !!env.navigator.mediaDevices?.getUserMedia && !!env.MediaRecorder;
  $('secure-warning').hidden = micAvailable;
  $('secure-warning').textContent = env.isSecureContext ? 'Microphone recording is not supported in this browser. You can upload an audio file instead.' : 'Microphone access requires HTTPS (or localhost). Open the secure link to record.';
  const showError = message => { $('error').textContent = message; $('error').hidden = !message; };
  const api = createApi({ fetch: (...args) => env.fetch(...args) });
  const render = state => {
    const seconds = Math.floor(state.seconds);
    $('timer').textContent = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
    $('level').value = state.level;
    $('record').setAttribute('aria-pressed', String(state.phase === 'recording'));
    $('recorder-panel').setAttribute('data-phase', state.phase);
    $('cancel').hidden = state.phase === 'idle';
    if ($('transcript').value !== state.text) $('transcript').value = state.text;
    $('copy').disabled = !state.text;
    $('clear').disabled = !state.text;
    $('audio-file').disabled = !ready || state.phase !== 'idle';
    if (state.result) {
      $('last-audio').textContent = Number.isFinite(state.result.audio_seconds) ? `${state.result.audio_seconds.toFixed(1)} s` : 'Not reported';
      $('latency').textContent = Number.isFinite(state.result.elapsed_seconds) ? `${state.result.elapsed_seconds.toFixed(1)} s` : 'Not reported';
      $('provider').textContent = state.result.provider || 'Not reported';
      $('quota').textContent = 'Not reported by provider';
      $('retention').textContent = state.result.provider_audio_retention === '30d' ? '30-day asset lifetime (provider reported)' : state.result.provider_audio_retention || 'Not reported';
    }
    $('record').disabled = !ready || !micAvailable || state.phase === 'uploading';
    $('record-label').textContent = state.phase === 'recording' ? 'Stop recording' : state.phase === 'requesting' ? 'Cancel request' : state.phase === 'uploading' ? 'Transcribing…' : 'Start recording';
    $('status').textContent = state.error ? 'Something needs attention' : state.phase === 'recording' ? 'Listening. Your words, at your pace.' : state.phase === 'requesting' ? 'Waiting for microphone permission…' : state.phase === 'uploading' ? 'Sending audio for transcription…' : ready ? 'Ready when you are' : 'Connect Codex in Administration to begin';
    showError(state.error);
  };
  const session = createVoiceSession({
    getUserMedia: () => env.navigator.mediaDevices.getUserMedia({ audio: true }),
    createRecorder: stream => {
      const mimeType = chooseMimeType(type => env.MediaRecorder.isTypeSupported?.(type));
      return new env.MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    },
    monitor: stream => createAudioMonitor(stream, env),
    now: () => env.performance.now(),
    setInterval: (fn, delay) => env.setInterval(fn, delay),
    clearInterval: id => env.clearInterval(id),
    upload: async blob => {
      const current = new env.AbortController();
      uploadController = current;
      try { return await api.transcribe(blob, current.signal); }
      finally { if (uploadController === current) uploadController = null; }
    },
    onChange: render,
  });
  const checkStatus = async () => {
    const current = ++statusGeneration;
    ready = false;
    render(session.snapshot());
    try {
      const status = await api.status();
      if (current !== statusGeneration) return;
      ready = status.credential_available === true && status.auth_state === 'connected';
      $('provider').textContent = status.provider || 'Not reported';
      $('quota').textContent = status.quota || 'Not reported by provider';
      $('retention').textContent = status.audio_retention || 'Not reported';
      $('credential-expiry').textContent = status.credential_expires_at || 'Not reported';
      render(session.snapshot());
      if (!ready) showError('Connect Codex in Administration to enable recording and audio uploads.');
    }
    catch (error) { if (current === statusGeneration) { ready = false; render(session.snapshot()); showError(error.message); } }
  };

  $('record').addEventListener('click', () => {
    if (!ready || !micAvailable) return;
    const phase = session.snapshot().phase;
    if (phase === 'idle') session.start();
    else if (phase === 'recording' || phase === 'requesting') session.stop();
  });
  $('transcript').addEventListener('input', () => session.edit($('transcript').value));
  $('clear').addEventListener('click', () => { session.edit(''); $('transcript').focus(); });
  $('copy').addEventListener('click', async () => {
    try { await env.navigator.clipboard.writeText(session.snapshot().text); $('status').textContent = 'Copied to clipboard'; }
    catch { showError('Clipboard unavailable. Select the text and copy it manually.'); $('transcript').focus(); }
  });
  $('audio-file').addEventListener('change', () => {
    const file = $('audio-file').files?.[0];
    $('audio-file').value = '';
    if (ready && file) session.uploadFile(file);
  });
  let holding = false;
  doc.addEventListener('keydown', event => {
    if (event.code !== 'Space' || event.repeat || event.ctrlKey || event.metaKey || event.altKey || event.target.closest?.('input, textarea, select, button, a, [contenteditable]')) return;
    event.preventDefault();
    if (ready && micAvailable && session.snapshot().phase === 'idle') { holding = true; session.start(); }
  });
  doc.addEventListener('keyup', event => {
    if (event.code === 'Space' && holding) { event.preventDefault(); holding = false; session.stop(); }
  });
  render(session.snapshot());
  checkStatus();
  const cancel = () => { holding = false; session.cancel(); uploadController?.abort(); };
  const destroy = () => { statusGeneration++; ready = false; cancel(); };
  $('cancel').addEventListener('click', cancel);
  env.addEventListener('pagehide', destroy);
  env.addEventListener('blur', () => { if (holding) { holding = false; session.cancel(); } });
  return { session, destroy };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') mountVoicepad(document, window);
