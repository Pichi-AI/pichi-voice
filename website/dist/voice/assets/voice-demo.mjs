// Synthetic, local-only hero animation. No audio input or external services.
export function createTimeline(text, barCount = 19) {
  let cursor = 450;
  const words = text.trim().split(/\s+/u).filter(Boolean).map(text => {
    const duration = 260 + Math.min(text.length, 10) * 18;
    const word = { text, at: cursor, duration };
    cursor += duration + (/[.!?]$/u.test(text) ? 420 : /[,;:]$/u.test(text) ? 230 : 90);
    return word;
  });
  return { words, barCount, speechEnd: cursor, cycle: cursor + 2500 };
}

export function sampleDemo(timeline, elapsed, reducedMotion = false) {
  const time = Math.max(0, Number.isFinite(elapsed) ? elapsed : 0) % timeline.cycle;
  const visibleWords = reducedMotion ? timeline.words.length : timeline.words.filter(word => time >= word.at).length;
  const speaking = timeline.words.find(word => time >= word.at && time < word.at + word.duration);
  const envelope = speaking && !reducedMotion
    ? Math.sin(Math.PI * (time - speaking.at) / speaking.duration) ** 2 : 0;
  const scales = Array.from({ length: timeline.barCount }, (_, index) => reducedMotion ? 1
    : 0.14 + 0.86 * envelope * (0.35 + 0.65 * Math.sin(time / 115 + index * 0.83) ** 2));
  return { visibleWords, scales };
}

export function isRunning(state) {
  return !state.paused && !state.hidden && !state.reducedMotion && state.pageActive;
}

export function createController(now, { hidden = false, reducedMotion = false } = {}) {
  return { elapsed: 0, last: now, paused: false, hidden, reducedMotion, pageActive: true };
}

// Pure transition: account for time under the previous state before changing it.
export function advanceController(state, event, now) {
  const elapsed = state.elapsed + (isRunning(state) ? Math.max(0, now - state.last) : 0);
  const next = { ...state, elapsed, last: now };
  if (event.type === 'pause') next.paused = event.value;
  if (event.type === 'visibility') next.hidden = event.value;
  if (event.type === 'motion') next.reducedMotion = event.value;
  if (event.type === 'page') next.pageActive = event.value;
  return next;
}

const mounted = new WeakMap();

export function mountVoiceDemo(root, { window = globalThis.window, document = root.ownerDocument } = {}) {
  if (mounted.has(root)) return mounted.get(root);
  const full = root.querySelector('[data-demo-full]');
  const visual = root.querySelector('[data-demo-text]');
  const button = root.querySelector('[data-demo-toggle]');
  const bars = [...root.querySelectorAll('.dictation-pill .wave i')];
  if (!full || !visual || !button || !bars.length || !window?.requestAnimationFrame) return () => {};

  const timeline = createTimeline(full.textContent, bars.length);
  const words = timeline.words.map(({ text }) => {
    const span = document.createElement('span');
    span.textContent = `${text} `;
    return span;
  });
  visual.replaceChildren(...words);
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const now = () => window.performance.now();
  let state = createController(now(), { hidden: document.hidden, reducedMotion: motion.matches });
  let frame = null;
  let destroyed = false;
  let previousCount = -1;
  const originalTransforms = bars.map(bar => bar.style.transform);

  function render() {
    const sample = sampleDemo(timeline, state.elapsed, state.reducedMotion);
    if (sample.visibleWords !== previousCount) {
      words.forEach((word, index) => { word.style.visibility = index < sample.visibleWords ? 'visible' : 'hidden'; });
      previousCount = sample.visibleWords;
    }
    bars.forEach((bar, index) => { bar.style.transform = `scaleY(${sample.scales[index]})`; });
    button.disabled = state.reducedMotion;
    button.textContent = state.reducedMotion ? button.dataset.staticLabel
      : state.paused ? button.dataset.resumeLabel : button.dataset.pauseLabel;
    button.setAttribute('aria-pressed', String(state.paused));
    root.dataset.demoMotion = state.reducedMotion ? 'static' : 'animated';
  }

  function schedule() {
    if (!destroyed && isRunning(state) && frame === null) frame = window.requestAnimationFrame(tick);
  }

  function tick(time) {
    frame = null;
    if (destroyed) return;
    state = advanceController(state, { type: 'tick' }, time);
    render();
    schedule();
  }

  function update(event) {
    if (destroyed) return;
    state = advanceController(state, event, now());
    if (frame !== null) window.cancelAnimationFrame(frame);
    frame = null;
    render();
    schedule();
  }

  const onToggle = () => update({ type: 'pause', value: !state.paused });
  const onVisibility = () => update({ type: 'visibility', value: document.hidden });
  const onMotion = event => update({ type: 'motion', value: event.matches });
  const onPageHide = event => {
    if (!event.persisted) destroy();
    else update({ type: 'page', value: false });
  };
  const onPageShow = () => update({ type: 'page', value: true });

  function destroy() {
    if (destroyed) return;
    destroyed = true;
    if (frame !== null) window.cancelAnimationFrame(frame);
    frame = null;
    button.removeEventListener('click', onToggle);
    document.removeEventListener('visibilitychange', onVisibility);
    motion.removeEventListener('change', onMotion);
    window.removeEventListener('pagehide', onPageHide);
    window.removeEventListener('pageshow', onPageShow);
    delete root.dataset.demoReady;
    delete root.dataset.demoMotion;
    button.hidden = true;
    button.disabled = false;
    button.removeAttribute('aria-pressed');
    bars.forEach((bar, index) => { bar.style.transform = originalTransforms[index]; });
    visual.replaceChildren();
    mounted.delete(root);
  }

  button.addEventListener('click', onToggle);
  document.addEventListener('visibilitychange', onVisibility);
  motion.addEventListener('change', onMotion);
  window.addEventListener('pagehide', onPageHide);
  window.addEventListener('pageshow', onPageShow);
  root.dataset.demoReady = '';
  button.hidden = false;
  render();
  schedule();
  mounted.set(root, destroy);
  return destroy;
}

if (typeof document !== 'undefined') {
  document.querySelectorAll('[data-voice-demo]').forEach(root => mountVoiceDemo(root));
}
