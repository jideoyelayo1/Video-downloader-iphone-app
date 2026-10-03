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

// Verbose diagnostics: every resource is reported once by the buffered observer.
// A tap or Refresh must not re-post the whole buffer, and a playlist seen through
// both its XHR/fetch response and its resource entry yields one candidate.
(() => {
  const posted = [];
  const docListeners = {};
  let observerCallback;
  let fetchResponse;
  const entries = [
    { name: 'https://cdn.example/master.m3u8', startTime: 5, initiatorType: 'xmlhttprequest' },
    { name: 'https://cdn.example/seg-1.png', startTime: 6, initiatorType: 'xmlhttprequest' }
  ];
  const win = {
    webkit: { messageHandlers: { mediaDiscovery: { postMessage: value => posted.push(value) } } },
    addEventListener: () => {},
    __vdaDiagnostics: true,
    fetch: () => Promise.resolve(fetchResponse)
  };
  const ctx = {
    document: {
      baseURI: 'https://player.example/e/1', title: 'Player', documentElement: {},
      querySelectorAll: () => [], addEventListener: (name, callback) => { docListeners[name] = callback; }
    },
    location: { href: 'https://player.example/e/1' },
    window: win,
    history: { pushState: function () {}, replaceState: function () {} },
    MutationObserver: class { observe() {} },
    PerformanceObserver: class {
      constructor(callback) { observerCallback = callback; }
      observe(options) { if (options.buffered) observerCallback({ getEntries: () => entries.slice() }); }
    },
    performance: { getEntriesByType: () => entries.slice(), now: () => 1000 },
    setTimeout, URL, console
  };
  win.top = win;
  vm.runInNewContext(match[1], ctx);
  const resourceEvents = () => posted.filter(message => message.event === 'resource').length;
  const candidates = () => posted.filter(message => !message.event && message.url === entries[0].name).length;
  if (resourceEvents() !== 2) throw new Error(`expected each buffered resource once, got ${resourceEvents()}`);
  if (candidates() !== 1) throw new Error(`expected one playlist candidate, got ${candidates()}`);

  docListeners.pointerdown({ isTrusted: true });
  docListeners.touchstart({ isTrusted: true });
  if (resourceEvents() !== 2) throw new Error('a tap re-posted the resource buffer');

  fetchResponse = { url: entries[0].name, headers: { get: () => 'application/vnd.apple.mpegurl' } };
  win.fetch(entries[0].name).then(() => setTimeout(() => {
    if (!posted.some(message => message.event === 'response' && message.url === entries[0].name)) throw new Error('fetch response was not logged');
    if (candidates() !== 1) throw new Error('the fetch response duplicated the resource-timing candidate');
    win.__vdaRescan();
    if (resourceEvents() !== 2) throw new Error('Refresh re-posted the resource buffer');
    if (candidates() !== 2) throw new Error('Refresh should report the playlist again');
    console.log('WebKit discovery diagnostics checks passed');
  }, 0));
})();

// Plyr-style <track> elements: subtitles and captions are reported with their labels once;
// chapters and blob tracks are not.
(() => {
  const posted = [];
  const docListeners = {};
  const track = (attrs) => ({ tagName: 'TRACK', getAttribute: name => (name in attrs ? attrs[name] : null), hasAttribute: name => name in attrs });
  const tracks = [
    track({ kind: 'subtitles', src: '/subs/en.vtt', srclang: 'en', label: 'English', default: '' }),
    track({ kind: 'captions', src: 'https://cdn.example/es.vtt', srclang: 'es', label: 'Español' }),
    track({ kind: 'chapters', src: '/subs/chapters.vtt' }),
    track({ kind: 'subtitles', src: 'blob:https://player.example/1' })
  ];
  const video = { nodeType: 1, tagName: 'VIDEO', src: 'blob:https://player.example/v', currentSrc: '', getAttribute: () => null,
                  querySelectorAll: selector => selector === 'track' ? tracks : [] };
  const ctx = {
    document: {
      baseURI: 'https://player.example/e/1', title: 'Player', documentElement: {},
      querySelectorAll: selector => (selector.includes('video') ? [video] : []),
      addEventListener: (name, callback) => { docListeners[name] = callback; }
    },
    location: { href: 'https://player.example/e/1' },
    window: { webkit: { messageHandlers: { mediaDiscovery: { postMessage: value => posted.push(value) } } }, addEventListener: () => {} },
    history: { pushState: function () {}, replaceState: function () {} },
    MutationObserver: class { observe() {} },
    PerformanceObserver: class { observe() {} },
    performance: { getEntriesByType: () => [], now: () => 1000 },
    setTimeout, URL, console
  };
  ctx.window.top = ctx.window;
  vm.runInNewContext(match[1], ctx);
  const events = () => posted.filter(message => message.event === 'subtitles');
  if (events().length !== 1) throw new Error(`expected one subtitles message, got ${events().length}`);
  const reported = events()[0].tracks;
  if (reported.length !== 2) throw new Error(`expected 2 subtitle tracks, got ${reported.length}`);
  if (reported[0].url !== 'https://player.example/subs/en.vtt' || reported[0].label !== 'English' || !reported[0].isDefault)
    throw new Error('English track not reported correctly');
  if (reported[1].language !== 'es' || reported[1].isDefault) throw new Error('Spanish track not reported correctly');
  docListeners.play({ target: video });
  if (events().length !== 1) throw new Error('the same tracks were reported again');
  ctx.window.__vdaRescan();
  if (events().length !== 2) throw new Error('Refresh should report the tracks again');
  console.log('WebKit discovery subtitle track checks passed');
})();

// Artwork: a player's <video poster> and the page's og:image are reported once each, as absolute URLs.
(() => {
  const posted = [];
  const docListeners = {};
  const video = { nodeType: 1, tagName: 'VIDEO', src: '', currentSrc: '', querySelectorAll: () => [],
                  getAttribute: name => (name === 'poster' ? '/art/ep1.jpg' : null) };
  const meta = { getAttribute: name => (name === 'content' ? 'https://cdn.example/series.png' : null) };
  const ctx = {
    document: {
      baseURI: 'https://site.example/watch/1', title: 'Episode', readyState: 'complete', documentElement: {},
      querySelectorAll: selector => (selector.includes('video') ? [video] : []),
      querySelector: selector => (selector.includes('og:image') ? meta : null),
      addEventListener: (name, callback) => { docListeners[name] = callback; }
    },
    location: { href: 'https://site.example/watch/1' },
    window: { webkit: { messageHandlers: { mediaDiscovery: { postMessage: value => posted.push(value) } } }, addEventListener: () => {} },
    history: { pushState: function () {}, replaceState: function () {} },
    MutationObserver: class { observe() {} },
    PerformanceObserver: class { observe() {} },
    performance: { getEntriesByType: () => [], now: () => 1000 },
    setTimeout, URL, console
  };
  ctx.window.top = ctx.window;
  vm.runInNewContext(match[1], ctx);
  const posters = () => posted.filter(message => message.event === 'poster');
  const urls = posters().map(message => `${message.kind} ${message.url}`).sort();
  if (urls.join(',') !== 'page https://cdn.example/series.png,video https://site.example/art/ep1.jpg')
    throw new Error(`unexpected posters: ${urls.join(', ')}`);
  docListeners.play({ target: video });
  if (posters().length !== 2) throw new Error('the same poster was reported again');
  console.log('WebKit discovery poster checks passed');
})();
