// The editor talks to its host through window.webkit.messageHandlers.snag, as it does in
// the macOS app. Here the host is the shell in the same page: messages wait in a queue
// until the shell attaches, so the editor's first "ready" is never lost.
const queue = [];
let target = null;

globalThis.webkit = globalThis.webkit || {};
globalThis.webkit.messageHandlers = globalThis.webkit.messageHandlers || {};
globalThis.webkit.messageHandlers.snag = {
  postMessage(msg) {
    if (target) target(msg);
    else queue.push(msg);
  },
};

export function attach(fn) {
  target = fn;
  while (queue.length) fn(queue.shift());
}
