import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  DEMO_DURATION, COMPLETED_PAUSE, createTimeline, sampleDemo, createController, advanceController, isRunning, mountVoiceDemo, mountScrollReveals,
} from '../website/dist/voice/assets/voice-demo.mjs';

function revealEnvironment({ reduced = false, unsupported = false, fail = false } = {}) {
  const targets = Array.from({ length: 3 }, () => ({ dataset: {} }));
  const motion = Object.assign(new EventTarget(), { matches: reduced });
  const window = new EventTarget();
  window.matchMedia = () => motion;
  const calls = { observed: [], unobserved: [], disconnected: 0 };
  let callback;
  if (!unsupported) window.IntersectionObserver = class {
    constructor(fn) { if (fail) throw new Error('unavailable'); callback = fn; }
    observe(target) { calls.observed.push(target); }
    unobserve(target) { calls.unobserved.push(target); }
    disconnect() { calls.disconnected++; }
  };
  return { targets, motion, window, calls, document: { querySelectorAll: () => targets },
    intersect: entries => callback(entries) };
}

test('scroll reveals each visible card once without changing offscreen content', () => {
  const env = revealEnvironment();
  const destroy = mountScrollReveals(env.document, env.window);
  assert.equal(env.calls.observed.length, 3);
  assert.ok(env.targets.every(target => target.dataset.revealState === 'waiting'));
  env.intersect([{ target: env.targets[0], isIntersecting: true }, { target: env.targets[1], isIntersecting: false }]);
  assert.equal(env.targets[0].dataset.revealState, 'visible');
  assert.equal(env.targets[1].dataset.revealState, 'waiting');
  assert.deepEqual(env.calls.unobserved, [env.targets[0]]);
  destroy();
  assert.equal(env.calls.disconnected, 1);
  assert.ok(env.targets.every(target => target.dataset.revealState === 'visible'));
});

test('reduced motion, missing observer and observer failure preserve full static content', () => {
  for (const options of [{ reduced: true }, { unsupported: true }, { fail: true }]) {
    const env = revealEnvironment(options);
    const destroy = mountScrollReveals(env.document, env.window);
    assert.ok(env.targets.every(target => target.dataset.revealState === 'visible'));
    assert.equal(env.calls.observed.length, 0);
    destroy();
  }
});

test('a changed motion preference reveals remaining cards and page teardown releases observer', () => {
  const env = revealEnvironment();
  const destroy = mountScrollReveals(env.document, env.window);
  env.motion.dispatchEvent(Object.assign(new Event('change'), { matches: true }));
  assert.ok(env.targets.every(target => target.dataset.revealState === 'visible'));
  assert.equal(env.calls.disconnected, 1);
  env.window.dispatchEvent(Object.assign(new Event('pagehide'), { persisted: false }));
  const count = env.calls.disconnected;
  env.motion.dispatchEvent(Object.assign(new Event('change'), { matches: true }));
  destroy();
  assert.equal(env.calls.disconnected, count);
});

// Deterministic DOM boundary doubles; parse and mount the shipped hero.
class Target extends EventTarget {
  listeners = new Map();
  addEventListener(type, listener) {
    super.addEventListener(type, listener);
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(listener);
  }
  removeEventListener(type, listener) {
    super.removeEventListener(type, listener);
    this.listeners.get(type)?.delete(listener);
  }
  emit(type, values = {}) { this.dispatchEvent(Object.assign(new Event(type), values)); }
  get listenerCount() { return [...this.listeners.values()].reduce((sum, set) => sum + set.size, 0); }
}

class Element extends Target {
  constructor(tag, attrs = {}) {
    super();
    this.tag = tag;
    this.attrs = { ...attrs };
    this.dataset = Object.fromEntries(Object.entries(attrs).filter(([key]) => key.startsWith('data-'))
      .map(([key, value]) => [key.slice(5).replace(/-([a-z])/g, (_, char) => char.toUpperCase()), value]));
    this.style = { transform: '' };
    this.children = [];
    this.hidden = 'hidden' in attrs;
  }
  setAttribute(key, value) { this.attrs[key] = value; }
  removeAttribute(key) { delete this.attrs[key]; }
  focus(options) {
    if (!('tabindex' in this.attrs) && !['button', 'input', 'a'].includes(this.tag)) return;
    for (let node = this; node; node = node.parentElement) assert.equal(node.hidden, false, 'Focus destination must be visible');
    this.ownerDocument.activeElement = this;
    this.focusOptions = options;
  }
  get textContent() { return this.children.map(child => typeof child === 'string' ? child : child.textContent).join(''); }
  set textContent(text) { this.children = [text]; }
  replaceChildren(...children) { this.children = children; }
  matches(selector) {
    if (selector.startsWith('.')) return (this.attrs.class ?? '').split(' ').includes(selector.slice(1));
    if (selector.startsWith('[')) return selector.slice(1, -1) in this.attrs;
    return this.tag === selector;
  }
  querySelectorAll(selector) {
    const parts = selector.split(' ');
    const result = [];
    function visit(node, ancestors) {
      if (node.matches(parts.at(-1))) {
        let index = parts.length - 2;
        for (let i = ancestors.length - 1; i >= 0 && index >= 0; i--) {
          if (ancestors[i].matches(parts[index])) index--;
        }
        if (index < 0) result.push(node);
      }
      node.children.filter(child => typeof child !== 'string').forEach(child => visit(child, [...ancestors, node]));
    }
    this.children.filter(child => typeof child !== 'string').forEach(child => visit(child, [this]));
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}

function readHero(route) {
  const html = readFileSync(new URL(`../website/dist/${route}`, import.meta.url), 'utf8');
  const source = html.match(/<figure\b[\s\S]*?<\/figure>/u)[0];
  const parent = new Element('root');
  const stack = [parent];
  for (const token of source.match(/<[^>]+>|[^<]+/gu)) {
    if (token.startsWith('</')) { stack.pop(); continue; }
    if (!token.startsWith('<')) { stack.at(-1).children.push(token); continue; }
    const tag = token.match(/^<(\w+)/u)[1];
    const attrs = Object.fromEntries([...token.matchAll(/([\w-]+)(?:="([^"]*)")?/gu)].slice(1)
      .map(([, key, value]) => [key, value ?? '']));
    const node = new Element(tag, attrs);
    node.parentElement = stack.at(-1);
    stack.at(-1).children.push(node);
    if (!['img', 'br'].includes(tag)) stack.push(node);
  }
  return { html, root: parent.children[0] };
}

function browser(route = 'voice/index.html', { reduced = false, hidden = false, observer = 'ok' } = {}) {
  const { root, html } = readHero(route);
  const document = new Target();
  document.hidden = hidden;
  document.createElement = tag => new Element(tag);
  root.ownerDocument = document;
  const bindDocument = node => {
    node.ownerDocument = document;
    node.children.filter(child => typeof child !== 'string').forEach(bindDocument);
  };
  bindDocument(root);
  const window = new Target();
  const motion = new Target();
  motion.matches = reduced;
  let now = 0;
  let serial = 0;
  const frames = new Map();
  const timers = new Map();
  const observation = { callback: null, disconnected: 0 };
  window.performance = { now: () => now };
  window.matchMedia = query => { assert.equal(query, '(prefers-reduced-motion: reduce)'); return motion; };
  window.requestAnimationFrame = callback => { frames.set(++serial, callback); return serial; };
  window.cancelAnimationFrame = id => frames.delete(id);
  window.setTimeout = (callback, delay) => {
    timers.set(++serial, { callback, at: now + delay });
    return serial;
  };
  window.clearTimeout = id => timers.delete(id);
  // Any accidental device/network/audio admission fails the real adapter tests.
  const forbidden = () => { assert.fail('example must never access devices, audio or network'); };
  window.fetch = window.Audio = window.AudioContext = window.WebSocket = forbidden;
  window.navigator = { mediaDevices: { getUserMedia: forbidden } };
  if (observer !== 'missing') window.IntersectionObserver = class {
    constructor(callback) {
      if (observer === 'constructor-failure') throw new Error('observer unavailable');
      observation.callback = callback;
    }
    observe(target) {
      assert.equal(target, root);
      if (observer === 'partial-failure') {
        observation.callback([{ target, isIntersecting: true }]);
        throw new Error('observer failed after admission');
      }
      if (observer === 'observe-failure') throw new Error('observation unavailable');
    }
    disconnect() { observation.disconnected++; }
  };
  const step = time => {
    now = time;
    const callbacks = [...frames.values()];
    frames.clear();
    callbacks.forEach(callback => callback(time));
    for (const [id, timer] of [...timers]) {
      if (timer.at <= now) { timers.delete(id); timer.callback(); }
    }
  };
  const destroy = mountVoiceDemo(root, { window, document });
  const conversations = root.querySelectorAll('[data-demo-conversation]');
  const shown = index => conversations[index].querySelectorAll('[data-demo-text]').map(visual => visual.children
    .filter(word => word.style.visibility === 'visible').map(word => word.textContent).join('').trim());
  const full = index => conversations[index].querySelectorAll('[data-demo-full]').map(el => el.textContent);
  return { root, html, window, document, motion, frames, timers, step, destroy, shown, full, conversations, observation,
    enter: (value = true) => observation.callback([{ target: root, isIntersecting: value }]),
    recordings: root.querySelector('[data-demo-recordings]'),
    choices: root.querySelectorAll('[data-demo-recording]'), list: root.querySelector('[data-demo-list]'),
    transcript: root.querySelector('[data-demo-transcript]'), bars: root.querySelectorAll('.dictation-pill .wave i'),
    pill: root.querySelector('[data-demo-pill]') };
}

const turns = ['Let’s share the idea.', 'I’ll prepare a draft today.', 'I’ll send it on Friday.'];

test('timeline streams words and speaker turns once, holds complete text forever', () => {
  for (const texts of [turns, ['Давайте поделимся идеей.', 'Подготовлю текст сегодня.', 'Отправлю в пятницу.']]) {
    const timeline = createTimeline(texts);
    assert.equal(timeline.duration, DEMO_DURATION);
    assert.ok(timeline.duration <= 5000);
    assert.equal(sampleDemo(timeline, 0).visibleWords, 0);
    timeline.words.forEach((word, index) => {
      assert.equal(sampleDemo(timeline, word.at - 0.01).visibleWords, index);
      assert.equal(sampleDemo(timeline, word.at).visibleWords, index + 1);
    });
    const final = sampleDemo(timeline, DEMO_DURATION);
    assert.equal(final.visibleWords, timeline.words.length);
    assert.equal(final.turn, 2);
    assert.ok(final.turns.every(count => count > 0));
    for (const elapsed of [DEMO_DURATION * 2, 900000]) assert.deepEqual(sampleDemo(timeline, elapsed), final);
    assert.deepEqual(sampleDemo(timeline, 0, true), final);
  }
  assert.equal(sampleDemo(createTimeline(''), 5000).visibleWords, 0);
});

test('speech wave is smooth, bounded, varied, and rests between words and after completion', () => {
  const timeline = createTimeline(turns);
  const first = timeline.words[0];
  const peak = sampleDemo(timeline, first.at + first.duration / 2).scales;
  assert.ok(Math.max(...peak) > 0.7);
  assert.ok(new Set(peak).size > 5);
  assert.ok(sampleDemo(timeline, first.at + first.duration + 1).scales.every(value => value === 0.14));
  assert.ok(sampleDemo(timeline, DEMO_DURATION).scales.every(value => value === 0.14));
  for (let time = 0; time <= DEMO_DURATION; time += 8) {
    const current = sampleDemo(timeline, time).scales;
    const next = sampleDemo(timeline, time + 1).scales;
    current.forEach((scale, index) => {
      assert.ok(scale >= 0.14 && scale <= 1);
      assert.ok(Math.abs(scale - next[index]) < 0.03);
    });
  }
});

test('controller loops only after a full completed pause and does not mutate prior state', () => {
  let state = createController(0);
  assert.equal(isRunning(state), false);
  state = advanceController(state, { type: 'tick' }, 10000);
  assert.equal(state.elapsed, DEMO_DURATION);
  state = advanceController(state, { type: 'viewport', value: true }, 12000);
  assert.equal(state.elapsed, 0);
  const previous = state;
  state = advanceController(state, { type: 'tick' }, 12000 + DEMO_DURATION);
  assert.equal(previous.elapsed, 0);
  assert.equal(state.elapsed, DEMO_DURATION);
  assert.equal(state.completedAt, 12000 + DEMO_DURATION);
  for (let cycle = 0; cycle < 3; cycle++) {
    const completedAt = state.completedAt;
    state = advanceController(state, { type: 'tick' }, completedAt + COMPLETED_PAUSE - 1);
    assert.equal(state.elapsed, DEMO_DURATION);
    state = advanceController(state, { type: 'tick' }, completedAt + COMPLETED_PAUSE);
    assert.equal(state.elapsed, 0);
    assert.equal(state.completedAt, null);
    state = advanceController(state, { type: 'tick' }, state.last + DEMO_DURATION);
  }
});

test('delayed completion still gets three seconds before resetting', () => {
  let state = advanceController(createController(0), { type: 'viewport', value: true }, 0);
  state = advanceController(state, { type: 'tick' }, 100000);
  assert.equal(state.elapsed, DEMO_DURATION);
  assert.equal(state.completedAt, 100000);
  state = advanceController(state, { type: 'tick' }, 102999);
  assert.equal(state.elapsed, DEMO_DURATION);
  state = advanceController(state, { type: 'tick' }, 103000);
  assert.equal(state.elapsed, 0);
});

test('controller suspends and resets on lifecycle changes, preserving recording selection', () => {
  for (const event of [{ type: 'visibility', value: true }, { type: 'page', value: false },
    { type: 'motion', value: true }, { type: 'viewport', value: false }]) {
    let state = advanceController(createController(0), { type: 'viewport', value: true }, 0);
    state = advanceController(state, { type: 'select', index: 1 }, 500);
    assert.equal(state.elapsed, 0);
    state = advanceController(state, event, 700);
    assert.equal(state.elapsed, DEMO_DURATION);
    assert.equal(state.completedAt, null);
    assert.equal(isRunning(state), false);
    state = advanceController(state, { ...event, value: !event.value }, 9000);
    assert.equal(state.elapsed, 0);
    assert.equal(state.selected, 1);
    assert.equal(isRunning(state), true);
  }
});

for (const route of ['index.html', 'voice/index.html', 'ru/voice/index.html']) {
  test(`${route}: shipped hero streams all speakers, holds three seconds without frames, then loops`, () => {
    const b = browser(route);
    assert.equal(b.frames.size + b.timers.size, 0);
    assert.deepEqual(b.shown(0), b.full(0));
    assert.equal(b.choices.length, 2);
    assert.equal(b.root.querySelector('.demo-settings').listenerCount, 0);
    assert.equal(b.root.querySelectorAll('button').length, 3);
    b.enter(false); b.step(10000);
    assert.equal(b.frames.size + b.timers.size, 0);
    b.enter();
    assert.deepEqual(b.shown(0), ['', '', '']);
    b.step(10700);
    assert.ok(b.shown(0)[0].length > 0);
    assert.equal(b.shown(0)[1], '');
    assert.equal(b.conversations[0].querySelectorAll('[data-demo-turn]')[1].style.visibility, 'hidden');
    b.step(12500); assert.ok(b.shown(0)[1].length > 0);
    b.step(14000); assert.ok(b.shown(0)[2].length > 0);
    assert.ok(b.conversations[0].querySelectorAll('.speaker')[2].textContent.includes(route.startsWith('ru') ? 'Вы' : 'You'));
    b.step(14800);
    assert.deepEqual(b.shown(0), b.full(0));
    assert.equal(b.pill.textContent, b.full(0)[2]);
    assert.equal(b.frames.size, 0);
    assert.equal(b.timers.size, 1);
    assert.ok(b.bars.every(bar => bar.style.transform === 'scaleY(0.14)'));
    b.step(17799);
    assert.deepEqual(b.shown(0), b.full(0));
    assert.equal(b.frames.size, 0);
    b.step(17800);
    assert.deepEqual(b.shown(0), ['', '', '']);
    assert.equal(b.timers.size, 0);
    assert.equal(b.frames.size, 1);
    b.step(22600); b.step(25600);
    assert.deepEqual(b.shown(0), ['', '', '']);
    b.destroy();
    assert.equal(b.frames.size + b.timers.size, 0);
  });

  test(`${route}: recording selection resets looping and moves keyboard focus to its visible heading`, () => {
    const b = browser(route);
    b.enter(); b.step(DEMO_DURATION);
    assert.equal(b.timers.size, 1);
    b.recordings.emit('click');
    assert.equal(b.list.hidden, false);
    assert.equal(b.transcript.hidden, true);
    assert.equal(b.frames.size + b.timers.size, 0);
    assert.equal(b.recordings.attrs['aria-expanded'], 'true');
    b.choices.forEach((choice, index) => {
      choice.focus();
      assert.equal(b.document.activeElement, choice);
      choice.emit('click');
      assert.equal(b.list.hidden, true);
      assert.equal(b.transcript.hidden, false);
      assert.equal(b.conversations[index].hidden, false);
      assert.equal(b.conversations[1 - index].hidden, true);
      assert.deepEqual(b.shown(index), ['', '', '']);
      const heading = b.conversations[index].querySelector('h3');
      assert.equal(b.document.activeElement, heading);
      assert.deepEqual(heading.focusOptions, { preventScroll: true });
      const start = DEMO_DURATION + index * (DEMO_DURATION + COMPLETED_PAUSE);
      b.step(start + DEMO_DURATION);
      assert.deepEqual(b.shown(index), b.full(index));
      b.step(start + DEMO_DURATION + COMPLETED_PAUSE);
      assert.deepEqual(b.shown(index), ['', '', '']);
      assert.equal(b.document.activeElement, heading, 'Loop must preserve keyboard focus');
      b.recordings.emit('click');
    });
    b.enter(false); b.enter(); b.step(100000);
    assert.equal(b.list.hidden, false);
    assert.equal(b.frames.size + b.timers.size, 0);
    b.destroy();
  });
}

test('hidden pages wait for both visibility and viewport before starting', () => {
  const b = browser('voice/index.html', { hidden: true });
  b.enter(); b.step(10000);
  assert.equal(b.frames.size + b.timers.size, 0);
  b.document.hidden = false; b.document.emit('visibilitychange');
  assert.deepEqual(b.shown(0), ['', '', '']);
  assert.equal(b.frames.size, 1);
  b.destroy();
});

test('visibility, viewport and persisted pagehide cancel streaming and completed holds then restart the selected recording', () => {
  for (const reason of ['visibility', 'viewport', 'pagehide']) {
    for (const elapsed of [700, DEMO_DURATION]) {
      const b = browser();
      b.enter(); b.recordings.emit('click'); b.choices[1].emit('click'); b.step(elapsed);
      if (reason === 'visibility') { b.document.hidden = true; b.document.emit('visibilitychange'); }
      if (reason === 'viewport') b.enter(false);
      if (reason === 'pagehide') b.window.emit('pagehide', { persisted: true });
      assert.equal(b.frames.size + b.timers.size, 0);
      assert.deepEqual(b.shown(1), b.full(1));
      b.step(100000);
      if (reason === 'visibility') { b.document.hidden = false; b.document.emit('visibilitychange'); }
      if (reason === 'viewport') b.enter();
      if (reason === 'pagehide') b.window.emit('pageshow', { persisted: true });
      assert.equal(b.frames.size, 1);
      assert.deepEqual(b.shown(1), ['', '', '']);
      assert.equal(b.conversations[0].hidden, true);
      b.destroy();
    }
  }
});

test('reduced motion stays complete on selection and cancels frames or completed timers when changed', () => {
  for (const elapsed of [700, DEMO_DURATION]) {
    const b = browser('ru/voice/index.html', { reduced: true });
    b.enter();
    assert.deepEqual(b.shown(0), b.full(0));
    assert.equal(b.frames.size + b.timers.size, 0);
    b.recordings.emit('click'); b.choices[1].emit('click');
    assert.deepEqual(b.shown(1), b.full(1));
    assert.equal(b.frames.size + b.timers.size, 0);
    b.motion.emit('change', { matches: false });
    assert.deepEqual(b.shown(1), ['', '', '']);
    b.step(elapsed);
    b.motion.emit('change', { matches: true });
    assert.deepEqual(b.shown(1), b.full(1));
    assert.equal(b.frames.size + b.timers.size, 0);
    b.destroy();
  }
});

test('missing or failed viewport observation stays static including recording selection', () => {
  for (const observer of ['missing', 'constructor-failure', 'observe-failure', 'partial-failure']) {
    const b = browser('voice/index.html', { observer });
    assert.equal(b.frames.size + b.timers.size, 0);
    assert.deepEqual(b.shown(0), b.full(0));
    b.recordings.emit('click'); b.choices[1].emit('click'); b.step(10000);
    assert.deepEqual(b.shown(1), b.full(1));
    if (b.observation.callback) b.enter(); // Ignore a queued callback from the failed observer.
    assert.equal(b.frames.size + b.timers.size, 0);
    b.destroy();
  }
});

test('unmount and terminal pagehide release frames, timers, observer and listeners and restore static content', () => {
  for (const pagehide of [false, true]) {
    for (const elapsed of [700, DEMO_DURATION]) {
      const b = browser();
      assert.equal(mountVoiceDemo(b.root, { window: b.window, document: b.document }), b.destroy);
      b.enter(); b.step(elapsed);
      const stale = [...b.frames.values(), ...[...b.timers.values()].map(timer => timer.callback)];
      if (pagehide) b.window.emit('pagehide', { persisted: false });
      else b.destroy();
      b.destroy(); stale.forEach(callback => callback(100000)); b.enter();
      assert.equal(b.frames.size + b.timers.size, 0);
      assert.equal(b.observation.disconnected, 1);
      assert.equal(b.window.listenerCount + b.document.listenerCount + b.motion.listenerCount
        + b.recordings.listenerCount + b.choices.reduce((sum, choice) => sum + choice.listenerCount, 0), 0);
      assert.equal(b.root.dataset.demoReady, undefined);
      assert.equal(b.root.dataset.demoMotion, undefined);
      assert.equal(b.recordings.hidden, true);
      assert.equal(b.list.hidden, true);
      assert.equal(b.transcript.hidden, false);
      assert.equal(b.conversations[0].hidden, false);
      assert.ok(b.bars.every(bar => bar.style.transform === ''));
      assert.ok(b.root.querySelectorAll('[data-demo-text]').every(visual => visual.children.length === 0));
      const cleanup = mountVoiceDemo(b.root, { window: b.window, document: b.document });
      assert.equal(b.frames.size + b.timers.size, 0);
      b.enter(); assert.equal(b.frames.size, 1);
      cleanup();
      assert.equal(b.frames.size + b.timers.size, 0);
    }
  }
});

test('incomplete markup safely retains the static transcript with no scheduled work', () => {
  assert.doesNotThrow(() => mountVoiceDemo(new Element('figure'), { window: {}, document: new Target() })());
});

test('English root remains identical to the voice route', () => {
  assert.equal(readHero('index.html').html, readHero('voice/index.html').html);
});

test('opening Recordings before intersection wins over autoplay until a recording is selected', () => {
  let state = advanceController(createController(0), { type: 'list' }, 10);
  state = advanceController(state, { type: 'viewport', value: true }, 20);
  assert.equal(state.view, 'list');
  assert.equal(isRunning(state), false);
  state = advanceController(state, { type: 'select', index: 1 }, 100);
  assert.equal(isRunning(state), true);
  assert.equal(state.elapsed, 0);
  assert.equal(state.selected, 1);
});


test('restoring one lifecycle condition never bypasses another suspension', () => {
  const b = browser();
  b.enter(); b.step(DEMO_DURATION);
  b.document.hidden = true; b.document.emit('visibilitychange');
  b.enter(false);
  b.window.emit('pagehide', { persisted: true });
  b.document.hidden = false; b.document.emit('visibilitychange');
  b.enter();
  assert.equal(b.frames.size + b.timers.size, 0);
  assert.deepEqual(b.shown(0), b.full(0));
  b.window.emit('pageshow', { persisted: true });
  assert.equal(b.frames.size, 1);
  b.step(2 * DEMO_DURATION);
  assert.equal(b.timers.size, 1);
  b.enter(); b.step(2 * DEMO_DURATION + COMPLETED_PAUSE - 1);
  b.enter(); // Repeated observations must not extend the completed pause.
  assert.deepEqual(b.shown(0), b.full(0));
  assert.equal(b.timers.size, 1);
  b.step(2 * DEMO_DURATION + COMPLETED_PAUSE);
  assert.deepEqual(b.shown(0), ['', '', '']);
  b.destroy();
});
