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
    selectors: root.querySelector('[data-demo-selectors]'),
    choices: root.querySelectorAll('[data-demo-recording]'), bars: root.querySelectorAll('.dictation-pill .wave i'),
    pill: root.querySelector('[data-demo-pill]') };
}

const turns = ['A short sentence.', 'Another thought.'];

test('timeline streams complete turns and waves settle', () => {
  const timeline = createTimeline(turns);
  assert.equal(sampleDemo(timeline, 0).visibleWords, 0);
  assert.deepEqual(sampleDemo(timeline, DEMO_DURATION).turns, [3, 2]);
  assert.ok(sampleDemo(timeline, DEMO_DURATION).scales.every(n => n === 0.14));
  assert.deepEqual(sampleDemo(timeline, 0, true), sampleDemo(timeline, DEMO_DURATION));
});

test('four scenes advance in order after a full hold, even with delayed frames', () => {
  let state = advanceController(createController(0), { type: 'viewport', value: true }, 0);
  for (const next of [1, 2, 3, 0]) {
    state = advanceController(state, { type: 'tick' }, state.last + DEMO_DURATION + 5000);
    const completed = state.completedAt;
    state = advanceController(state, { type: 'tick' }, completed + COMPLETED_PAUSE - 1);
    assert.equal(state.selected, (next + 3) % 4);
    state = advanceController(state, { type: 'tick' }, completed + COMPLETED_PAUSE);
    assert.equal(state.selected, next);
    assert.equal(state.elapsed, 0);
  }
});

for (const route of ['index.html', 'voice/index.html', 'ru/voice/index.html']) {
  test(`${route}: shipped scenes, accessible story, focus and automatic order`, () => {
    const b = browser(route);
    const accessible = b.root.querySelector('[data-demo-accessible]');
    const original = accessible.textContent;
    assert.equal(b.conversations.length, 4);
    assert.equal(b.choices.length, 4);
    assert.equal(b.root.querySelector('.story-stage').attrs['aria-hidden'], 'true');
    b.conversations.forEach((scene, index) => b.full(index).forEach(text => assert.ok(original.includes(text))));
    b.choices[2].focus();
    b.enter();
    for (let i = 0; i < 4; i++) {
      b.step(i * (DEMO_DURATION + COMPLETED_PAUSE) + DEMO_DURATION);
      assert.equal(b.timers.size, 1);
      assert.deepEqual(b.shown(i), b.full(i));
      b.step((i + 1) * (DEMO_DURATION + COMPLETED_PAUSE));
      assert.equal(b.conversations[(i + 1) % 4].attrs['data-active'], 'true');
      assert.equal(b.document.activeElement, b.choices[2]);
      assert.equal(accessible.textContent, original);
      assert.equal(accessible.parentElement, b.root);
    }
    b.choices[3].emit('click');
    assert.equal(b.conversations[3].attrs['data-active'], 'true');
    assert.equal(b.document.activeElement, b.choices[2]);
    b.destroy();
    assert.equal(b.frames.size + b.timers.size, 0);
    assert.equal(accessible.textContent, original);
  });

  test(`${route}: reduced motion is static and selectable`, () => {
    const b = browser(route, { reduced: true });
    b.enter();
    assert.equal(b.frames.size + b.timers.size, 0);
    assert.deepEqual(b.shown(0), b.full(0));
    b.choices[1].focus(); b.choices[1].emit('click');
    assert.deepEqual(b.shown(1), b.full(1));
    assert.equal(b.document.activeElement, b.choices[1]);
    b.destroy();
  });
}

test('multiple lifecycle suspensions require all conditions to resume and teardown releases work', () => {
  const b = browser();
  b.enter(); b.step(DEMO_DURATION);
  assert.equal(b.timers.size, 1);
  b.document.hidden = true; b.document.emit('visibilitychange');
  b.enter(false); b.window.emit('pagehide', { persisted: true });
  assert.equal(b.frames.size + b.timers.size, 0);
  b.document.hidden = false; b.document.emit('visibilitychange'); b.enter();
  assert.equal(b.frames.size + b.timers.size, 0);
  b.window.emit('pageshow', { persisted: true });
  assert.equal(b.frames.size, 1);
  b.window.emit('pagehide', { persisted: false });
  assert.equal(b.frames.size + b.timers.size, 0);
  assert.ok(b.observation.disconnected > 0);
  assert.equal(b.window.listenerCount + b.document.listenerCount + b.motion.listenerCount, 0);
  b.destroy();
});

test('missing or failed observer stays static and manual selection works', () => {
  for (const observer of ['missing', 'constructor-failure', 'observe-failure', 'partial-failure']) {
    const b = browser('voice/index.html', { observer });
    assert.equal(b.frames.size + b.timers.size, 0);
    b.choices[2].emit('click');
    assert.deepEqual(b.shown(2), b.full(2));
    b.destroy();
  }
});

test('incomplete markup safely stays static', () => {
  assert.doesNotThrow(() => mountVoiceDemo(new Element('figure'), { window: {}, document: new Target() })());
});

test('English preview and voice route are identical', () => {
  assert.equal(readHero('index.html').html, readHero('voice/index.html').html);
});


test('each word enters on its timestamp and speech waves are smooth and bounded', () => {
  for (const text of ['Please review the plan before Friday.', 'Давайте обсудим план до встречи в пятницу.']) {
    const timeline = createTimeline([text]);
    timeline.words.forEach((word, index) => {
      assert.equal(sampleDemo(timeline, word.at - 0.01).visibleWords, index);
      assert.equal(sampleDemo(timeline, word.at).visibleWords, index + 1);
    });
    const first = timeline.words[0];
    assert.ok(Math.max(...sampleDemo(timeline, first.at + first.duration / 2).scales) > 0.7);
    for (let time = 0; time < DEMO_DURATION; time += 16) {
      const a = sampleDemo(timeline, time).scales;
      const b = sampleDemo(timeline, time + 1).scales;
      a.forEach((value, i) => {
        assert.ok(value >= 0.14 && value <= 1);
        assert.ok(Math.abs(value - b[i]) < 0.03);
      });
    }
  }
  assert.equal(sampleDemo(createTimeline(''), 5000).visibleWords, 0);
});

for (const route of ['index.html', 'voice/index.html', 'ru/voice/index.html']) {
  test(`${route}: real scenes stream partially in the required branded order`, () => {
    const raw = readHero(route);
    assert.equal(raw.root.querySelector('[data-demo-selectors]').hidden, true);
    const b = browser(route);
    assert.equal(b.selectors.hidden, false);
    assert.deepEqual(b.choices.map(node => node.textContent.trim()), ['Gmail', 'Telegram', 'Zoom', route.startsWith('ru') ? 'Офлайн' : 'Offline']);
    assert.equal(b.conversations[0].querySelector('img').attrs.src, '/voice/assets/services/gmail.svg');
    assert.equal(b.conversations[1].querySelector('img').attrs.src, '/voice/assets/services/telegram.svg');
    b.enter();
    for (let i = 0; i < 4; i++) {
      const before = i * 2000;
      b.step(before);
      b.choices[i].emit('click');
      b.step(before + 450);
      const partial = b.shown(i)[0];
      assert.ok(partial.length > 0);
      assert.ok(partial.length < b.full(i)[0].length);
    }
    const accessible = b.root.querySelector('[data-demo-accessible]').textContent;
    assert.match(accessible, route.startsWith('ru') ? /планшете \(скоро\)/ : /tablet meeting \(Coming Soon\)/);
    b.destroy();
    assert.equal(b.selectors.hidden, true);
  });
}

test('motion changes and suspension during streaming cancel work and keep the current scene', () => {
  for (const duringHold of [false, true]) {
    const b = browser(); b.enter(); b.choices[2].emit('click');
    b.step(duringHold ? DEMO_DURATION : 700);
    b.motion.emit('change', { matches: true });
    assert.equal(b.frames.size + b.timers.size, 0);
    assert.deepEqual(b.shown(2), b.full(2));
    b.step(50000);
    assert.equal(b.conversations[2].attrs['data-active'], 'true');
    b.motion.emit('change', { matches: false });
    assert.equal(b.frames.size, 1);
    b.enter(false);
    assert.equal(b.frames.size + b.timers.size, 0);
    b.enter();
    assert.equal(b.frames.size, 1);
    b.destroy();
  }
});


for (const route of ['index.html', 'voice/index.html', 'ru/voice/index.html']) {
  test(`${route}: Telegram completion remains in the unsent draft composer`, () => {
    const b = browser(route); b.enter(); b.choices[1].emit('click');
    const scene = b.conversations[1];
    const draft = scene.querySelector('[data-demo-draft]');
    assert.equal(draft.attrs['data-message-state'], 'draft');
    assert.equal(scene.querySelector('.story-heading').textContent, route.startsWith('ru') ? 'Черновик' : 'Draft');
    b.step(DEMO_DURATION);
    assert.deepEqual(b.shown(1), b.full(1));
    assert.equal(draft.attrs['data-message-state'], 'draft');
    b.step(DEMO_DURATION + COMPLETED_PAUSE - 1);
    assert.deepEqual(b.shown(1), b.full(1));
    assert.equal(draft.attrs['data-message-state'], 'draft');
    assert.equal(scene.querySelectorAll('form').length + scene.querySelectorAll('button').length, 0);
    b.step(DEMO_DURATION + COMPLETED_PAUSE);
    assert.equal(b.conversations[2].attrs['data-active'], 'true');
    assert.equal(draft.attrs['data-message-state'], 'draft');
    b.destroy();
  });
}
