const fs = require('fs');
const vm = require('vm');

const swift = fs.readFileSync('VideoDownloaderApp/Services/MediaDiscovery.swift', 'utf8');
const match = swift.match(/let source = #"""\n([\s\S]*?)\n\s*"""#/);
if (!match) throw new Error('Could not extract the WebKit discovery script');

const messages = [];
let mutationCallback;
const document = {
  baseURI: 'https://example.com/watch', title: 'Fixture', readyState: 'complete', documentElement: {},
  querySelectorAll: () => [],
  addEventListener: () => {}
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
  performance: { getEntriesByType: () => [] },
  URL,
  console
};
vm.runInNewContext(match[1], context);
mutationCallback([{ type: 'childList', addedNodes: [{ tagName: 'IMG', src: 'https://example.com/poster.jpg', getAttribute: () => null }] }]);
mutationCallback([{ type: 'childList', addedNodes: [{ tagName: 'IFRAME', src: 'https://example.com/player', getAttribute: () => null }] }]);
mutationCallback([{ type: 'childList', addedNodes: [{ tagName: 'VIDEO', src: 'https://cdn.example/stream?id=1', getAttribute: () => null }] }]);
mutationCallback([{ type: 'childList', addedNodes: [{ tagName: 'VIDEO', src: 'https://cdn.example/episode.m3u8', getAttribute: () => null }] }]);
mutationCallback([{ type: 'childList', addedNodes: [{ tagName: 'VIDEO', src: 'https://cdn.example/thumb.jpg?ref=.m3u8', getAttribute: () => null }] }]);
if (messages.length !== 3) throw new Error(`expected 3 media messages, got ${messages.length}`);
if (messages[0].kind !== 'unknown' || messages[1].kind !== 'hls') throw new Error('media classification failed');
if (messages[2].kind !== 'unknown') throw new Error('query-string extension false positive');
console.log('WebKit discovery JavaScript fixture checks passed');
