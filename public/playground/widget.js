// SPDX-License-Identifier: MIT OR Apache-2.0
// agent-tts v1.10.1 — playground widget. External file (v1.9 inlined this
// into MDX, which Astro/Starlight strip on production builds — see
// feedback-ship-only-tested.md). Vanilla JS, no framework runtime.
(() => {
  const root = document.querySelector('.agent-tts-playground');
  if (!root) return;

  const base = (root.dataset.base || '/').replace(/\/?$/, '/');
  const endpointBare = base + 'api/synth';
  const endpointStub = base + 'api/synth.html';
  const voiceEl = root.querySelector('[data-role="voice"]');
  const textEl = root.querySelector('[data-role="text"]');
  const btnEl = root.querySelector('[data-role="speak"]');
  const statusEl = root.querySelector('[data-role="status"]');
  const audioEl = root.querySelector('[data-role="audio"]');

  let audioCtx = null;
  function getCtx() {
    if (!audioCtx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (AC) audioCtx = new AC();
    }
    return audioCtx;
  }

  function setState(state, message) {
    root.dataset.state = state;
    statusEl.textContent = message;
  }

  async function speak() {
    const voice = voiceEl.value;
    const text = textEl.value.trim();
    if (!text) {
      setState('error', 'Digite algo antes de falar.');
      return;
    }
    btnEl.disabled = true;
    setState('pending', 'Sintetizando…');

    try {
      const payload = {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ voice, text }),
      };
      let res = await fetch(endpointBare, payload);
      if (res.status === 404) {
        res = await fetch(endpointStub, payload);
      }

      const body = await res.text();
      const isStub = body.includes('"not_implemented"');

      if (res.status === 501 || isStub) {
        setState('pending',
          '501 — WASM build pending. v1.10.1 ships the playground UI only. ' +
          'Backend synth (libpiper → WASM) lands in v1.10.2. ' +
          'See /agent-tts/whats-next/ for the next slate.'
        );
        return;
      }

      if (!res.ok) {
        setState('error', 'Erro ' + res.status + ' — ' + res.statusText);
        return;
      }

      const buf = await res.arrayBuffer();
      const ctx = getCtx();
      if (ctx) {
        const decoded = await ctx.decodeAudioData(buf.slice(0));
        const src = ctx.createBufferSource();
        src.buffer = decoded;
        src.connect(ctx.destination);
        src.start();
      }
      const blob = new Blob([buf], { type: 'audio/wav' });
      audioEl.src = URL.createObjectURL(blob);
      audioEl.hidden = false;
      setState('ok', 'Pronto — falando "' + voice + '".');
    } catch (err) {
      setState('error', 'Falha de rede: ' + (err && err.message ? err.message : String(err)));
    } finally {
      btnEl.disabled = false;
    }
  }

  btnEl.addEventListener('click', speak);
  textEl.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') speak();
  });
})();
