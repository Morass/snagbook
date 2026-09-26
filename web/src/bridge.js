// The editor talks to its host through window.webkit.messageHandlers.snag, as it does in
// the macOS app. Here the host is the shell in the same page: messages wait in a queue
// until the shell attaches, so the editor's first "ready" is never lost.
//
// On Linux the web view (WebKitGTK) has a window.webkit of its own that does not keep a
// handler added to it: only the first message got through, and typing, pasting, links and
// double-clicks were silently dropped. So the page gets its own `webkit`, shadowing the
// built-in one.
const queue = [];
let target = null;

const snag = {
  postMessage(msg) {
    if (target) target(msg);
    else queue.push(msg);
  },
};
const ours = { messageHandlers: { snag } };
try {
  Object.defineProperty(globalThis, "webkit", { value: ours, configurable: true, writable: false });
} catch {
  globalThis.webkit = ours;
}

export const bridgeIsInstalled = () => globalThis.webkit?.messageHandlers?.snag === snag;

export function attach(fn) {
  target = fn;
  while (queue.length) fn(queue.shift());
}
