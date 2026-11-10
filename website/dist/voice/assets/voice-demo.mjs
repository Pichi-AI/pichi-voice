// Synthetic local examples only. No microphone, audio, network or user data.
export const DEMO_DURATION = 4800;
export const COMPLETED_PAUSE = 3000;

export function createTimeline(turns, barCount = 19) {
  const texts = Array.isArray(turns) ? turns : [turns];
  const tokens = texts.flatMap((text, turn) => text.trim().split(/\s+/u).filter(Boolean).map(text => ({ text, turn })));
  const slot = 4000 / Math.max(1, tokens.length);
  const words = tokens.map((word, index) => ({ ...word, at: 200 + index * slot, duration: slot * 0.85 }));
  return { words, texts, barCount, duration: DEMO_DURATION };
}

export function sampleDemo(timeline, elapsed, reducedMotion = false) {
  const time = reducedMotion ? timeline.duration : Math.max(0, Number.isFinite(elapsed) ? elapsed : 0);
  const visibleWords = timeline.words.filter(word => time >= word.at).length;
  const speaking = timeline.words.find(word => time >= word.at && time < word.at + word.duration);
  const envelope = speaking ? Math.sin(Math.PI * (time - speaking.at) / speaking.duration) ** 2 : 0;
  const scales = Array.from({ length: timeline.barCount }, (_, index) =>
    0.14 + 0.86 * envelope * (0.35 + 0.65 * Math.sin(time / 115 + index * 0.83) ** 2));
  const turn = timeline.words[Math.max(0, visibleWords - 1)]?.turn ?? 0;
  return { visibleWords, turn, scales,
    turns: timeline.texts.map((_, index) => timeline.words.slice(0, visibleWords).filter(word => word.turn === index).length) };
}

export function createController(now, { hidden = false, reducedMotion = false } = {}) {
  return { elapsed: DEMO_DURATION, completedAt: null, last: now, hidden, reducedMotion, pageActive: true,
    inViewport: false, playing: false, selected: 0, view: 'transcript' };
}

export function isRunning(state) {
  return state.playing && state.view === 'transcript' && !state.hidden && !state.reducedMotion && state.pageActive && state.inViewport;
}

export function advanceController(state, event, now) {
  const next = { ...state, last: now };
  if (isRunning(state)) {
    if (state.completedAt !== null) {
      if (now - state.completedAt >= COMPLETED_PAUSE) {
        next.elapsed = 0;
        next.completedAt = null;
      }
    } else {
      next.elapsed = Math.min(DEMO_DURATION, state.elapsed + Math.max(0, now - state.last));
      // Start the full pause when the completed text is actually rendered,
      // even if the browser delivers a delayed animation frame.
      if (next.elapsed === DEMO_DURATION) next.completedAt = now;
    }
  }
  if (event.type === 'visibility') next.hidden = event.value;
  if (event.type === 'page') next.pageActive = event.value;
  if (event.type === 'motion') next.reducedMotion = event.value;
  if (event.type === 'viewport') next.inViewport = event.value;
  if (event.type === 'list') next.view = 'list';
  if (event.type === 'select') {
    next.selected = event.index;
    next.view = 'transcript';
    next.playing = false;
  }
  const eligible = next.view === 'transcript' && !next.hidden && !next.reducedMotion && next.pageActive && next.inViewport;
  if (!eligible) {
    next.elapsed = DEMO_DURATION;
    next.completedAt = null;
    next.playing = false;
  } else if (!next.playing) {
    next.elapsed = 0;
    next.completedAt = null;
    next.playing = true;
  }
  return next;
}

const mounted = new WeakMap();

export function mountVoiceDemo(root, { window = globalThis.window, document = root.ownerDocument } = {}) {
  if (mounted.has(root)) return mounted.get(root);
  const conversations = [...root.querySelectorAll('[data-demo-conversation]')];
  const recordings = root.querySelector('[data-demo-recordings]');
  const choices = [...root.querySelectorAll('[data-demo-recording]')];
  const transcript = root.querySelector('[data-demo-transcript]');
  const list = root.querySelector('[data-demo-list]');
  const pill = root.querySelector('[data-demo-pill]');
  const bars = [...root.querySelectorAll('.dictation-pill .wave i')];
  if (!conversations.length || !recordings || choices.length !== conversations.length || !transcript || !list || !pill || !bars.length || !window?.requestAnimationFrame) return () => {};
  const groups = conversations.map(conversation => [...conversation.querySelectorAll('[data-demo-turn]')].map(row => ({
    row, full: row.querySelector('[data-demo-full]'), visual: row.querySelector('[data-demo-text]'),
  })));
  if (groups.some(group => !group.length || group.some(row => !row.full || !row.visual))) return () => {};
  const timelines = groups.map(group => createTimeline(group.map(({ full }) => full.textContent), bars.length));
  groups.forEach((group, index) => group.forEach((row, turn) => {
    row.words = timelines[index].words.filter(word => word.turn === turn).map(({ text }) => {
      const span = document.createElement('span');
      span.textContent = `${text} `;
      return span;
    });
    row.visual.replaceChildren(...row.words);
  }));
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const now = () => window.performance.now();
  let state = createController(now(), { hidden: document.hidden, reducedMotion: motion.matches });
  let frame = null;
  let timer = null;
  let observer = null;
  let destroyed = false;
  const originalPill = pill.textContent;
  const originalTransforms = bars.map(bar => bar.style.transform);
  const listeners = [];
  const listen = (target, type, listener) => {
    target.addEventListener(type, listener);
    listeners.push(() => target.removeEventListener(type, listener));
  };

  function render() {
    const timeline = timelines[state.selected];
    const sample = sampleDemo(timeline, state.elapsed, state.reducedMotion);
    conversations.forEach((conversation, index) => { conversation.hidden = index !== state.selected; });
    groups[state.selected].forEach(({ row, words }, index) => {
      row.style.visibility = sample.turns[index] ? 'visible' : 'hidden';
      words.forEach((word, at) => { word.style.visibility = at < sample.turns[index] ? 'visible' : 'hidden'; });
    });
    pill.textContent = timeline.words.slice(0, sample.visibleWords).filter(word => word.turn === sample.turn).map(word => word.text).join(' ') || '\u00a0';
    bars.forEach((bar, index) => { bar.style.transform = `scaleY(${sample.scales[index]})`; });
    transcript.hidden = state.view !== 'transcript';
    list.hidden = state.view !== 'list';
    recordings.setAttribute('aria-expanded', String(state.view === 'list'));
    root.dataset.demoMotion = isRunning(state) ? 'animated' : 'static';
  }

  function schedule() {
    if (destroyed || !isRunning(state) || frame !== null || timer !== null) return;
    if (state.completedAt !== null) {
      timer = window.setTimeout(() => { timer = null; tick(now()); },
        Math.max(0, COMPLETED_PAUSE - (now() - state.completedAt)));
    } else frame = window.requestAnimationFrame(tick);
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
    if (timer !== null) window.clearTimeout(timer);
    frame = timer = null;
    render();
    schedule();
  }
  function destroy() {
    if (destroyed) return;
    destroyed = true;
    if (frame !== null) window.cancelAnimationFrame(frame);
    if (timer !== null) window.clearTimeout(timer);
    frame = timer = null;
    observer?.disconnect();
    listeners.forEach(remove => remove());
    delete root.dataset.demoReady;
    delete root.dataset.demoMotion;
    recordings.hidden = true;
    recordings.removeAttribute('aria-expanded');
    transcript.hidden = false;
    list.hidden = true;
    conversations.forEach((conversation, index) => { conversation.hidden = index !== 0; });
    groups.forEach(group => group.forEach(({ row, visual }) => { row.style.visibility = ''; visual.replaceChildren(); }));
    bars.forEach((bar, index) => { bar.style.transform = originalTransforms[index]; });
    pill.textContent = originalPill;
    mounted.delete(root);
  }

  listen(recordings, 'click', () => update({ type: 'list' }));
  choices.forEach((choice, index) => listen(choice, 'click', () => {
    update({ type: 'select', index });
    conversations[index].querySelector('h3')?.focus({ preventScroll: true });
  }));
  listen(document, 'visibilitychange', () => update({ type: 'visibility', value: document.hidden }));
  listen(motion, 'change', event => update({ type: 'motion', value: event.matches }));
  listen(window, 'pagehide', event => { if (event.persisted) update({ type: 'page', value: false }); else destroy(); });
  listen(window, 'pageshow', () => update({ type: 'page', value: true }));
  root.dataset.demoReady = '';
  recordings.hidden = false;
  render();
  mounted.set(root, destroy);
  // Without reliable viewport observation, keep complete static content,
  // including recording selection. Never animate an unobserved hero.
  try {
    if (window.IntersectionObserver) {
      observer = new window.IntersectionObserver(entries => {
        if (!observer) return;
        for (const entry of entries) if (entry.target === root) update({ type: 'viewport', value: entry.isIntersecting });
      }, { threshold: 0.15 });
      observer.observe(root);
    }
  } catch {
    observer?.disconnect();
    observer = null;
    update({ type: 'viewport', value: false });
  }
  return destroy;
}

export function mountScrollReveals(document, window) {
  const targets = [...document.querySelectorAll('[data-reveal]')];
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let observer = null;
  let destroyed = false;
  const showAll = () => targets.forEach(target => { target.dataset.revealState = 'visible'; });
  const reveal = entries => {
    if (destroyed) return;
    entries.filter(entry => entry.isIntersecting).forEach(({ target }) => {
      target.dataset.revealState = 'visible';
      observer?.unobserve(target);
    });
  };
  const onMotion = event => {
    if (event.matches) { observer?.disconnect(); showAll(); }
  };
  function destroy() {
    if (destroyed) return;
    destroyed = true;
    observer?.disconnect();
    motion.removeEventListener('change', onMotion);
    window.removeEventListener('pagehide', onPageHide);
    showAll();
  }
  const onPageHide = event => { if (!event.persisted) destroy(); };
  if (motion.matches || !window.IntersectionObserver) {
    showAll();
    return destroy;
  }
  try {
    observer = new window.IntersectionObserver(reveal, { threshold: 0.1 });
    targets.forEach(target => { target.dataset.revealState = 'waiting'; observer.observe(target); });
  } catch {
    observer?.disconnect(); showAll();
    return destroy;
  }
  motion.addEventListener('change', onMotion);
  window.addEventListener('pagehide', onPageHide);
  return destroy;
}

if (typeof document !== 'undefined') {
  document.querySelectorAll('[data-voice-demo]').forEach(root => mountVoiceDemo(root));
  mountScrollReveals(document, window);
}
