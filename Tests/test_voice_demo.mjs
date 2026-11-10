import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  createTimeline, sampleDemo, createController, advanceController, isRunning, mountVoiceDemo, mountScrollReveals,
} from '../website/dist/voice/assets/voice-demo.mjs';

const en = 'The idea is clear. Let’s put it into words.';
const ru = 'Мысль уже есть. Осталось превратить её в текст.';

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

test('words reveal in order, punctuation gives a breath, complete text holds then repeats', () => {
  for (const sentence of [en, ru]) {
    const timeline = createTimeline(sentence);
    assert.equal(sampleDemo(timeline, 0).visibleWords, 0);
    timeline.words.forEach((word, index) => {
      assert.equal(sampleDemo(timeline, word.at - 1).visibleWords, index);
      assert.equal(sampleDemo(timeline, word.at).visibleWords, index + 1);
    });
    const last = timeline.words.at(-1);
    assert.equal(sampleDemo(timeline, last.at + last.duration + 1700).visibleWords, timeline.words.length);
    assert.equal(sampleDemo(timeline, timeline.cycle).visibleWords, 0);
    assert.deepEqual(sampleDemo(timeline, timeline.cycle + 700), sampleDemo(timeline, 700));
    const endOfSentence = timeline.words.findIndex(word => word.text.endsWith('.'));
    const word = timeline.words[endOfSentence];
    assert.ok(timeline.words[endOfSentence + 1].at - word.at - word.duration >= 400);
  }
});

test('speech waveform is continuous, bounded and settles between words', () => {
  const timeline = createTimeline(en);
  const first = timeline.words[0];
  const peak = sampleDemo(timeline, first.at + first.duration / 2).scales;
  assert.ok(Math.max(...peak) > 0.7);
  assert.ok(new Set(peak).size > 5);
  const settled = sampleDemo(timeline, first.at + first.duration + 40).scales;
  assert.ok(settled.every(scale => scale === 0.14));
  for (let time = 0; time < timeline.cycle; time += 8) {
    const current = sampleDemo(timeline, time).scales;
    const next = sampleDemo(timeline, time + 1).scales;
    current.forEach((scale, index) => {
      assert.ok(scale >= 0.14 && scale <= 1);
      assert.ok(Math.abs(scale - next[index]) < 0.02);
    });
  }
});

test('reduced motion always has complete text and a static waveform', () => {
  const timeline = createTimeline(ru);
  for (const time of [0, 700, timeline.cycle, timeline.cycle * 4]) {
    assert.deepEqual(sampleDemo(timeline, time, true), {
      visibleWords: timeline.words.length, scales: Array(19).fill(1),
    });
  }
});

test('controller preserves speaking position through pause, visibility, motion and page suspension', () => {
  let state = createController(100);
  for (const type of ['pause', 'visibility', 'motion', 'page']) {
    const key = { pause: 'paused', visibility: 'hidden', motion: 'reducedMotion', page: 'pageActive' }[type];
    const suspendValue = type !== 'page';
    state = advanceController(state, { type, value: suspendValue }, state.last + 100);
    const frozen = state.elapsed;
    assert.equal(state[key], suspendValue);
    assert.equal(isRunning(state), false);
    state = advanceController(state, { type: 'tick' }, state.last + 50000);
    assert.equal(state.elapsed, frozen);
    state = advanceController(state, { type, value: !suspendValue }, state.last + 50000);
    assert.equal(state.elapsed, frozen);
    assert.equal(isRunning(state), true);
  }
  const original = state;
  const next = advanceController(state, { type: 'tick' }, state.last + 100);
  assert.equal(next.elapsed, state.elapsed + 100);
  assert.notEqual(next, original);
  assert.equal(original.elapsed, 400);
});

test('independent suspension reasons do not undo an explicit user pause', () => {
  let state = createController(0);
  state = advanceController(state, { type: 'pause', value: true }, 100);
  state = advanceController(state, { type: 'visibility', value: true }, 200);
  state = advanceController(state, { type: 'visibility', value: false }, 900);
  state = advanceController(state, { type: 'motion', value: true }, 1000);
  state = advanceController(state, { type: 'motion', value: false }, 2000);
  assert.equal(isRunning(state), false);
  assert.equal(state.elapsed, 100);
});

// Small deterministic DOM boundary doubles. Hero elements and attributes come
// from the shipped HTML; the controller, adapter and event handlers are real.
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
    stack.at(-1).children.push(node);
    if (!['img', 'br'].includes(tag)) stack.push(node);
  }
  return { html, root: parent.children[0] };
}

function browser(route = 'voice/index.html', { reduced = false, hidden = false } = {}) {
  const { root, html } = readHero(route);
  const document = new Target();
  document.hidden = hidden;
  document.createElement = tag => new Element(tag);
  root.ownerDocument = document;
  const window = new Target();
  const motion = new Target();
  motion.matches = reduced;
  let now = 0;
  let serial = 0;
  const frames = new Map();
  window.performance = { now: () => now };
  window.matchMedia = query => { assert.equal(query, '(prefers-reduced-motion: reduce)'); return motion; };
  window.requestAnimationFrame = callback => { frames.set(++serial, callback); return serial; };
  window.cancelAnimationFrame = id => frames.delete(id);
  const button = root.querySelector('[data-demo-toggle]');
  const visual = root.querySelector('[data-demo-text]');
  const bars = root.querySelectorAll('.dictation-pill .wave i');
  const shown = () => visual.children.filter(word => word.style.visibility === 'visible').map(word => word.textContent).join('').trim();
  const step = time => {
    now = time;
    const callbacks = [...frames.values()];
    frames.clear();
    callbacks.forEach(callback => callback(time));
  };
  const destroy = mountVoiceDemo(root, { window, document });
  return { root, html, window, document, motion, frames, button, bars, visual, shown, step, destroy };
}

for (const route of ['index.html', 'voice/index.html', 'ru/voice/index.html']) {
  test(`${route}: shipped hero mounts, reveals speech, pauses and resumes through the real button`, () => {
    const b = browser(route);
    assert.equal(b.button.hidden, false);
    assert.equal(b.button.textContent, b.button.dataset.pauseLabel);
    assert.equal(b.root.querySelector('[data-demo-full]').textContent, route.startsWith('ru') ? ru : en);
    assert.equal(b.visual.attrs['aria-hidden'], 'true');
    assert.equal(b.shown(), '');
    b.step(700);
    assert.ok(b.shown().length > 0);
    const words = b.shown();
    const transforms = b.bars.map(bar => bar.style.transform);
    b.button.emit('click');
    assert.equal(b.button.attrs['aria-pressed'], 'true');
    assert.equal(b.button.textContent, b.button.dataset.resumeLabel);
    assert.equal(b.frames.size, 0);
    b.step(50000);
    assert.equal(b.shown(), words);
    assert.deepEqual(b.bars.map(bar => bar.style.transform), transforms);
    b.button.emit('click');
    assert.equal(b.frames.size, 1);
    assert.equal(b.button.attrs['aria-pressed'], 'false');
    b.step(50700);
    assert.ok(b.shown().length > words.length);
    b.destroy();
  });
}

test('visibility and bfcache pagehide stop frames and resume without catching up', () => {
  const b = browser();
  b.step(700);
  const words = b.shown();
  b.document.hidden = true;
  b.document.emit('visibilitychange');
  assert.equal(b.frames.size, 0);
  b.step(100000);
  b.document.hidden = false;
  b.document.emit('visibilitychange');
  assert.equal(b.shown(), words);
  assert.equal(b.frames.size, 1);
  b.window.emit('pagehide', { persisted: true });
  assert.equal(b.frames.size, 0);
  b.step(200000);
  b.window.emit('pageshow', { persisted: true });
  assert.equal(b.shown(), words);
  assert.equal(b.frames.size, 1);
  b.destroy();
});

test('reduced motion mounts fully static, responds to preference changes and preserves pause', () => {
  const b = browser('ru/voice/index.html', { reduced: true });
  assert.equal(b.shown(), ru);
  assert.equal(b.frames.size, 0);
  assert.equal(b.button.disabled, true);
  assert.equal(b.button.textContent, 'Анимация отключена');
  assert.equal(b.root.dataset.demoMotion, 'static');
  b.motion.emit('change', { matches: false });
  assert.equal(b.frames.size, 1);
  b.step(700);
  b.button.emit('click');
  const partial = b.shown();
  b.motion.emit('change', { matches: true });
  assert.equal(b.shown(), ru);
  assert.equal(b.frames.size, 0);
  b.motion.emit('change', { matches: false });
  assert.equal(b.shown(), partial);
  assert.equal(b.button.attrs['aria-pressed'], 'true');
  assert.equal(b.frames.size, 0);
  b.destroy();
});

test('initially hidden pages own no frame and start only when visible', () => {
  const b = browser('voice/index.html', { hidden: true });
  assert.equal(b.frames.size, 0);
  b.step(200000);
  b.document.hidden = false;
  b.document.emit('visibilitychange');
  assert.equal(b.shown(), '');
  assert.equal(b.frames.size, 1);
  b.step(200700);
  assert.ok(b.shown().length > 0);
  b.destroy();
});

test('unmount and non-persisted pagehide cancel frames, remove listeners and restore static fallback', () => {
  for (const pagehide of [false, true]) {
    const b = browser();
    assert.equal(mountVoiceDemo(b.root, { window: b.window, document: b.document }), b.destroy);
    const staleFrame = [...b.frames.values()][0];
    if (pagehide) b.window.emit('pagehide', { persisted: false });
    else b.destroy();
    b.destroy();
    staleFrame(800);
    assert.equal(b.frames.size, 0);
    assert.equal(b.window.listenerCount + b.document.listenerCount + b.motion.listenerCount + b.button.listenerCount, 0);
    assert.equal(b.root.dataset.demoReady, undefined);
    assert.equal(b.root.dataset.demoMotion, undefined);
    assert.equal(b.button.hidden, true);
    assert.ok(b.bars.every(bar => bar.style.transform === ''));
    b.button.emit('click');
    b.document.emit('visibilitychange');
    assert.equal(b.frames.size, 0);
    const cleanup = mountVoiceDemo(b.root, { window: b.window, document: b.document });
    assert.equal(b.frames.size, 1);
    cleanup();
  }
});

test('incomplete markup safely remains a static example with no scheduled work', () => {
  const root = new Element('figure');
  assert.doesNotThrow(() => mountVoiceDemo(root, { window: {}, document: new Target() })());
});
