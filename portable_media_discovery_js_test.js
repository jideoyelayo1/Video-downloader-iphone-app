const fs = require('fs');
const vm = require('vm');

const swift = fs.readFileSync('VideoDownloaderApp/Services/MediaDiscovery.swift', 'utf8');
const match = swift.match(/let source = #"""\n([\s\S]*?)\n\s*"""#/);
if (!match) throw new Error('Could not extract the WebKit discovery script');

const messages = [];
let mutationCallback;
let resourceScans = 0;
const listeners = {};
const resources = [
  { name: 'https://ads.example/preview.mp4', startTime: 10, initiatorType: 'fetch' },
  { name: 'https://cdn.example/episode.m3u8', startTime: 20, initiatorType: 'fetch' }
];
const document = {
  baseURI: 'https://example.com/watch', title: 'Fixture', readyState: 'complete', documentElement: {},
  querySelectorAll: () => [],
  addEventListener: (name, callback) => { listeners[name] = callback; }
};
const context = {
  document,
  location: { href: 'https://example.com/watch' },
  window: {
    webkit: { messageHandlers: { mediaDiscovery: { postMessage: value => messages.push(value) } } },
    addEventListener: () => {}
  },
  history: { pushState: function () {}, replaceState: function () {} },
  MutationObserver: class { constructor(callback) { mutationCallback = callback; } observe() {} },
  PerformanceObserver: class { constructor() {} observe() {} },
  performance: { getEntriesByType: () => { resourceScans++; return resources; }, now: () => 1000 },
  setTimeout,
  URL,
  console
};
context.window.top = context.window;
vm.runInNewContext(match[1], context);
if (messages.length !== 1 || messages[0].url !== resources[1].name) throw new Error('pre-play ad clip was offered');
resources.push({ name: 'https://cdn.example/episode.mp4', startTime: 1001, initiatorType: 'video' });
listeners.pointerdown({ isTrusted: true });
if (messages.some(message => message.url === resources[0].name) || !messages.some(message => message.url === resources[2].name)) {
  throw new Error('interaction resource filtering failed');
}
listeners.pointerdown({ isTrusted: true });
listeners.keydown({ isTrusted: true });
if (resourceScans !== 2) throw new Error('resource list was rescanned on every interaction');
messages.length = 0;
const node = (tagName, src) => ({ nodeType: 1, tagName, src, getAttribute: () => null });
mutationCallback([{ type: 'childList', addedNodes: [node('IMG', 'https://example.com/poster.jpg')] }]);
mutationCallback([{ type: 'childList', addedNodes: [node('IFRAME', 'https://example.com/player')] }]);
mutationCallback([{ type: 'childList', addedNodes: [node('VIDEO', 'https://cdn.example/stream?id=1')] }]);
mutationCallback([{ type: 'childList', addedNodes: [node('VIDEO', 'https://cdn.example/episode.m3u8')] }]);
mutationCallback([{ type: 'childList', addedNodes: [node('VIDEO', 'https://cdn.example/thumb.jpg?ref=.m3u8')] }]);
setTimeout(() => {
  if (messages.length !== 3) throw new Error(`expected 3 media messages, got ${messages.length}`);
  if (messages[0].kind !== 'unknown' || messages[1].kind !== 'hls') throw new Error('media classification failed');
  if (messages[2].kind !== 'unknown') throw new Error('query-string extension false positive');
  messages.length = 0;
  context.window.top = {};
  resources.push({ name: 'https://***REMOVED***.top/vd/episode/seg-57-s1080p-v1-a1.m4s', startTime: 1002, initiatorType: 'fetch' });
  resources.push({ name: 'https://***REMOVED***.top/vd/episode/master.m3u8', startTime: 6, initiatorType: 'fetch' });
  context.window.__vdaRescan();
  if (!messages.some(message => message.url === resources[4].name && !message.event) ||
      messages.some(message => message.url === resources[3].name && !message.event) ||
      !messages.some(message => message.event === 'fragment' && message.url === resources[3].name)) {
    throw new Error('iframe playlist should be reported without exposing its segments');
  }
  console.log('WebKit discovery JavaScript fixture checks passed');
}, 150);
