import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { createShell, keyLabel, neighbour, mediaBase, tip, comboFromEvent, sameCombo } from "../src/shell.js";
import { rectFraction, formatElapsed } from "../src/rect.js";

const html = readFileSync(new URL("../src/index.html", import.meta.url), "utf8").replace(/<script[^>]*><\/script>/, "");

/// An in-memory stand-in for the app's commands.
function fakeApp({ platform = "linux", trash = true, sessions = [], captureCanInsert = true } = {}) {
  const calls = [];
  const notes = new Map();
  let slowNote = null;
  let session = null;
  let nextHash = 1;
  let nextOpen = 1;
  const config = { templates: [{ id: "A", label: "Bug", icon: "🐞", body: "**Bug:** " }, { id: "B", label: "Idea", icon: "", body: "**Idea:** " }], header: "H", sessionsFolder: "~/Snagbook" };
  const list = [...sessions];
  const view = (extra = {}) => ({ config, session: session && JSON.parse(JSON.stringify(session)), loadError: null, closed: null, platform, ...extra });
  const settle = () => {
    session.nextItem = Math.max(0, ...session.items.map((i) => i.id)) + 1;
  };
  const handlers = {
    state: () => view(),
    list_sessions: () => list.map((s) => ({ ...s })),
    new_session: () => {
      const path = `~/Snagbook/${String(nextHash++).padStart(8, "0")}_25-09-2026`;
      session = { id: `id-${nextHash}`, openToken: `open-${nextOpen++}`, path, title: "Session 25 Sep, 18:00", header: null, items: [], nextItem: 1 };
      list.unshift({ path, title: session.title, items: 1, created: "2026-09-25T16:00:00Z" });
      handlers.add_item({});
      return view();
    },
    open_session: ({ path }) => {
      const s = list.find((x) => x.path === path);
      if (!s) throw "not a session";
      session = { id: s.id || `id-${path}`, openToken: `open-${nextOpen++}`, path, title: s.title, header: null, items: [{ id: 1, title: "Old", folder: "01-old", images: 0, videos: 0 }], nextItem: 2 };
      return view();
    },
    add_item: ({ title }) => {
      const id = session.nextItem;
      session.items.push({ id, title: title || `Item ${id}`, folder: `${String(id).padStart(2, "0")}-item-${id}`, images: 0, videos: 0 });
      session.nextItem = id + 1;
      return view();
    },
    rename_item: ({ id, title }) => {
      const it = session.items.find((i) => i.id === id);
      it.title = title;
      return view();
    },
    delete_item: ({ id, permanently }) => {
      if (!permanently && !trash) throw "NOTRASH:the drive has no Trash";
      session.items = session.items.filter((i) => i.id !== id);
      settle();
      return view();
    },
    delete_session: ({ sessionId, openToken, permanently }) => {
      if (session?.id !== sessionId || session?.openToken !== openToken) throw "The open session changed.";
      if (!permanently && !trash) throw "NOTRASH:the drive has no Trash";
      const at = list.findIndex((s) => s.path === session.path);
      if (at >= 0) list.splice(at, 1);
      session = null;
      return view();
    },
    move_item: ({ id, index }) => {
      const at = session.items.findIndex((i) => i.id === id);
      const [it] = session.items.splice(at, 1);
      session.items.splice(index, 0, it);
      return view();
    },
    read_note: ({ id }) => (slowNote === id ? new Promise((r) => setTimeout(() => r(notes.get(id) ?? ""), 30)) : notes.get(id) ?? ""),
    write_note: ({ sessionId, openToken, id, markdown }) => {
      if (session?.id !== sessionId || session?.openToken !== openToken) throw "The open session changed before the note could be saved.";
      notes.set(id, markdown);
      return true;
    },
    copy_handoff: () => `Read ${session.path}/README.md`,
    set_session_title: ({ title }) => ((session.title = title || "Session 25 Sep, 18:00"), view()),
    set_selected: () => null,
    update_config: ({ patch }) => (Object.assign(config, patch), view()),
    start_screenshot: () => null,
    capture_filed: () => null,
    capture_can_insert: () => captureCanInsert,
  };
  const invoke = async (cmd, args = {}) => {
    calls.push([cmd, args]);
    if (!handlers[cmd]) throw `unknown command ${cmd}`;
    return handlers[cmd](args);
  };
  return {
    invoke,
    calls,
    notes,
    slowNoteFor(id) {
      slowNote = id;
    },
    list,
    deleteFromOutside() {
      list.splice(list.findIndex((s) => s.path === session.path), 1);
      const path = session.path;
      session = null;
      handlers.state = () => ((handlers.state = () => view()), view({ closed: path }));
    },
  };
}

function fakeEditor() {
  const log = [];
  return {
    log,
    open: (o) => log.push(["open", o]),
    forget: (id) => log.push(["forget", id]),
    takePending: () => null,
    insertMarkdown: (t) => log.push(["insert", t]),
    focus: () => {},
    mediaSaved: (r, s) => log.push(["saved", r, s]),
    mediaFailed: (r) => log.push(["failed", r]),
  };
}

async function setup(opts = {}) {
  const dom = new JSDOM(html, { pretendToBeVisual: true });
  const { window } = dom;
  const app = fakeApp(opts);
  const editor = fakeEditor();
  const shell = createShell({ invoke: app.invoke, snag: () => editor, doc: window.document, win: window });
  await shell.onEditorMessage({ type: "ready" });
  await shell.start();
  if (opts.session) await shell.newSession();
  const $ = (id) => window.document.getElementById(id);
  const key = (target, init) => target.dispatchEvent(new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  const tick = () => new Promise((r) => setTimeout(r, 0));
  const settle = async () => {
    for (let i = 0; i < 10; i++) await tick();
  };
  const answer = async (value) => {
    await settle();
    assert.equal($("modal").hidden, false, "a question is showing");
    $("modal").querySelector(`button[data-value="${value}"]`).click();
    await settle();
  };
  return { window, doc: window.document, app, editor, shell, $, key, settle, answer };
}

test("key labels follow the platform", () => {
  assert.equal(keyLabel("linux", "Mod+N"), "Ctrl+N");
  assert.equal(keyLabel("windows", "Mod+Shift+C"), "Ctrl+Shift+C");
  assert.equal(keyLabel("macos", "Mod+Shift+C"), "⌘⇧C");
  assert.equal(tip("Stop", ""), "Stop", "no stray separator when a shortcut is cleared");
  assert.equal(tip("Record", "Ctrl+R", "drag"), "Record  Ctrl+R — drag");
});

test("picture addresses carry the item, per platform", () => {
  assert.equal(mediaBase("linux", 3, 2), "snagbook://localhost/item/3.2/");
  assert.equal(mediaBase("windows", 3, 2), "http://snagbook.localhost/item/3.2/");
});

test("after a delete the item in its place is shown, or the last one", () => {
  const items = [{ id: 1 }, { id: 3 }, { id: 4 }];
  assert.equal(neighbour(items, 1), 3);
  assert.equal(neighbour(items, 9), 4);
  assert.equal(neighbour([], 0), null);
});

test("with no session the start screen offers recent sessions", async () => {
  const t = await setup({ sessions: [{ path: "~/Snagbook/a", title: "Build 7", items: 2, created: "2026-09-20T10:00:00Z" }] });
  await t.settle();
  assert.equal(t.$("empty").hidden, false);
  assert.equal(t.$("note").hidden, true);
  assert.match(t.$("empty").textContent, /Build 7/);
  t.$("empty").querySelector(".recent-row").click();
  await t.settle();
  assert.equal(t.shell.view().session.path, "~/Snagbook/a");
  assert.equal(t.$("empty").hidden, true);
});

test("a new session starts on Item 1 with its title ready to type", async () => {
  const t = await setup({ session: true });
  assert.equal(t.$("item-title").value, "Item 1");
  assert.equal(t.doc.querySelectorAll("#items .item").length, 1);
  assert.match(t.$("session-button").textContent, /1 item$/);
  const opened = t.editor.log.filter((l) => l[0] === "open").pop()[1];
  assert.match(opened.base, /^snagbook:\/\/localhost\/item\/1\.\d+\/$/);
});

test("Ctrl+N adds an item on Linux and ⌘N does on macOS; the hint says which", async () => {
  const t = await setup({ session: true });
  assert.equal(t.$("new-item-key").textContent, "Ctrl+N");
  assert.match(t.$("new-item").title, /^New item {2}Ctrl\+N/);
  t.key(t.doc.body, { key: "n", ctrlKey: true });
  await t.settle();
  assert.equal(t.shell.view().session.items.length, 2);
  assert.equal(t.shell.selected(), 2);

  const m = await setup({ session: true, platform: "macos" });
  assert.equal(m.$("new-item-key").textContent, "⌘N");
  m.key(m.doc.body, { key: "n", ctrlKey: true });
  await m.settle();
  assert.equal(m.shell.view().session.items.length, 1, "Ctrl+N is not the macOS shortcut");
  m.key(m.doc.body, { key: "n", metaKey: true });
  await m.settle();
  assert.equal(m.shell.view().session.items.length, 2);
});

test("typing a title and pressing Enter renames the item", async () => {
  const t = await setup({ session: true });
  t.$("item-title").focus();
  t.$("item-title").value = "Main menu";
  t.key(t.$("item-title"), { key: "Enter" });
  await t.settle();
  assert.equal(t.shell.view().session.items[0].title, "Main menu");
  assert.ok(t.app.calls.some(([c, a]) => c === "rename_item" && a.title === "Main menu"));
});

test("an empty title is refused and the old one comes back", async () => {
  const t = await setup({ session: true });
  t.$("item-title").value = "   ";
  await t.shell.renameSelected();
  assert.equal(t.$("item-title").value, "Item 1");
  assert.ok(!t.app.calls.some(([c]) => c === "rename_item"));
});

test("arrow keys in the list move the selection", async () => {
  const t = await setup({ session: true });
  await t.shell.newItem();
  await t.shell.newItem();
  t.$("items").focus();
  t.key(t.$("items"), { key: "ArrowUp" });
  await t.settle();
  assert.equal(t.shell.selected(), 2);
  t.key(t.$("items"), { key: "ArrowDown" });
  await t.settle();
  assert.equal(t.shell.selected(), 3);
});

test("delete asks first, and Cancel keeps the item", async () => {
  const t = await setup({ session: true });
  const p = t.shell.deleteItem(1);
  await t.answer(false);
  await p;
  assert.equal(t.shell.view().session.items.length, 1);
  assert.ok(!t.app.calls.some(([c]) => c === "delete_item"));
});

test("on a drive without a Trash, delete asks again before deleting for good", async () => {
  const t = await setup({ session: true, trash: false });
  await t.shell.newItem();
  const p = t.shell.deleteItem(2);
  await t.answer(true);
  assert.match(t.$("modal").textContent, /permanently/);
  assert.match(t.$("modal").textContent, /the drive has no Trash/);
  await t.answer(true);
  await p;
  assert.deepEqual(t.shell.view().session.items.map((i) => i.id), [1]);
  assert.deepEqual(t.app.calls.filter(([c]) => c === "delete_item").map(([, a]) => a.permanently), [false, true]);
  assert.doesNotMatch(t.$("status-text").textContent, /NOTRASH/, "the refused Trash is a question, not an error");
  assert.equal(t.$("status-text").classList.contains("error"), false);
});

test("declining the second question keeps the item", async () => {
  const t = await setup({ session: true, trash: false });
  const p = t.shell.deleteItem(1);
  await t.answer(true);
  await t.answer(false);
  await p;
  assert.equal(t.shell.view().session.items.length, 1);
});

test("after deleting the last item the next new one takes its number", async () => {
  const t = await setup({ session: true });
  await t.shell.newItem();
  await t.shell.newItem();
  const p = t.shell.deleteItem(3);
  await t.answer(true);
  await p;
  assert.equal(t.shell.selected(), 2, "the item above is shown");
  await t.shell.newItem();
  assert.deepEqual(t.shell.view().session.items.map((i) => i.id), [1, 2, 3]);
});

test("the session menu reads the folder each time it opens", async () => {
  const t = await setup({ session: true });
  await t.shell.sessionMenu();
  assert.match(t.$("menu").textContent, /Recent sessions/);
  t.app.list.push({ path: "~/Snagbook/other", title: "Other run", items: 4, created: "2026-09-01T10:00:00Z" });
  await t.shell.sessionMenu();
  assert.match(t.$("menu").textContent, /Other run/);
  t.app.list.pop();
  await t.shell.sessionMenu();
  assert.doesNotMatch(t.$("menu").textContent, /Other run/, "a session deleted from outside is not offered");
  assert.equal(t.app.calls.filter(([c]) => c === "list_sessions").length >= 3, true);
});

test("opening the session menu closes a current session deleted from outside", async () => {
  const t = await setup({ session: true });
  t.app.deleteFromOutside();
  await t.shell.sessionMenu();
  assert.equal(t.shell.view().session, null);
  assert.doesNotMatch(t.$("menu").textContent, /Delete This Session/);
});

test("a session can be deleted from its menu", async () => {
  const t = await setup({ session: true });
  await t.shell.sessionMenu();
  assert.match(t.$("menu").textContent, /Delete This Session/);

  const p = t.shell.deleteSession();
  await t.answer(true);
  await p;

  assert.equal(t.shell.view().session, null);
  assert.deepEqual(t.app.calls.filter(([c]) => c === "delete_session").map(([, a]) => a.permanently), [false]);
});

test("deleting a session asks again when its drive has no Trash", async () => {
  const t = await setup({ session: true, trash: false });
  const p = t.shell.deleteSession();
  await t.answer(true);
  assert.match(t.$("modal").textContent, /permanently/);
  await t.answer(true);
  await p;

  assert.equal(t.shell.view().session, null);
  assert.deepEqual(t.app.calls.filter(([c]) => c === "delete_session").map(([, a]) => a.permanently), [false, true]);
});

test("Enter on the focused Cancel button keeps the session", async () => {
  const t = await setup({ session: true });
  const deleting = t.shell.deleteSession();
  await t.settle();
  const cancel = t.$("modal").querySelector('button[data-value="false"]');
  cancel.focus();
  t.key(cancel, { key: "Enter" });
  await deleting;
  assert.notEqual(t.shell.view().session, null);
  assert.equal(t.app.calls.some(([c]) => c === "delete_session"), false);
});

test("a session switch during confirmation cannot delete the replacement", async () => {
  const t = await setup({ session: true, sessions: [{ path: "~/Snagbook/other", title: "Other", items: 1, created: "2026-09-25T16:00:00Z" }] });
  const deleting = t.shell.deleteSession();
  await t.settle();
  await t.shell.openSession("~/Snagbook/other");
  await t.answer(true);
  await deleting;
  assert.equal(t.shell.view().session.title, "Other");
  assert.equal(t.app.calls.some(([c]) => c === "delete_session"), false);
});

test("a copied session with the same manifest id cannot reuse a deletion confirmation", async () => {
  const t = await setup({ session: true, sessions: [{ id: "id-2", path: "~/Snagbook/copy", title: "Copy", items: 1, created: "2026-09-25T16:00:00Z" }] });
  const deleting = t.shell.deleteSession();
  await t.settle();
  await t.shell.openSession("~/Snagbook/copy");
  await t.answer(true);
  await deleting;
  assert.equal(t.shell.view().session.title, "Copy");
  assert.equal(t.app.calls.some(([c]) => c === "delete_session"), false);
});

test("a failed pending-note write prevents session deletion", async () => {
  const t = await setup({ session: true });
  let pending = { id: 1, markdown: "unsaved" };
  t.editor.takePending = () => { const p = pending; pending = null; return p; };
  t.editor.restorePending = (p) => { pending = p; };
  const before = t.shell.view().session.path;
  const old = t.app.calls.length;
  const set = t.app.notes.set.bind(t.app.notes);
  let full = true;
  t.app.notes.set = (id, markdown) => { if (full) throw new Error("disk full"); return set(id, markdown); };
  const deleting = t.shell.deleteSession();
  await t.answer(true);
  await deleting;
  assert.equal(t.shell.view().session.path, before);
  assert.equal(t.app.calls.slice(old).some(([c]) => c === "delete_session"), false);

  full = false;
  const retry = t.shell.deleteSession();
  await t.answer(true);
  await retry;
  assert.equal(t.app.notes.get(1), "unsaved", "the retry saves the exact pending note before deletion");
  assert.equal(t.shell.view().session, null);
});

test("a failed ordinary autosave is restored for the next required flush", async () => {
  const t = await setup({ session: true });
  let pending = null;
  t.editor.restorePending = (p) => { pending = p; };
  t.editor.takePending = () => { const p = pending; pending = null; return p; };
  const set = t.app.notes.set.bind(t.app.notes);
  let full = true;
  t.app.notes.set = (id, markdown) => { if (full) throw new Error("disk full"); return set(id, markdown); };
  await t.shell.onEditorMessage({ type: "changed", id: 1, markdown: "not lost" });
  assert.deepEqual(pending, { type: "changed", id: 1, markdown: "not lost" });

  full = false;
  const deleting = t.shell.deleteSession();
  await t.answer(true);
  await deleting;
  assert.equal(t.app.notes.get(1), "not lost");
  assert.equal(t.shell.view().session, null);
});

test("a failed autosave prevents switching to a new session", async () => {
  const t = await setup({ session: true });
  let pending = null;
  t.editor.restorePending = (p) => { pending = p; };
  t.editor.takePending = () => { const p = pending; pending = null; return p; };
  t.app.notes.set = () => { throw new Error("disk full"); };
  const before = t.shell.view().session.openToken;
  await t.shell.onEditorMessage({ type: "changed", id: 1, markdown: "not lost" });
  await t.shell.newSession();
  assert.equal(t.shell.view().session.openToken, before);
  assert.deepEqual(pending, { type: "changed", id: 1, markdown: "not lost" });
});

test("every finished recording kind acknowledges only after filing", async () => {
  const t = await setup({ session: true });
  t.editor.insertMedia = () => {};
  const sessionId = t.shell.view().session.id;
  await t.shell.onCaptured({ sessionId, ack: "contact-ack", id: 1, rel: "media/clip-001-contact.jpg", kind: "image" });
  assert.deepEqual(t.app.calls.filter(([c]) => c === "capture_filed").map(([, a]) => a), [{ ack: "contact-ack", inserted: true }]);
});

test("a marked screenshot carries its native filing acknowledgement", async () => {
  const t = await setup({ session: true });
  t.editor.insertMedia = () => {};
  const sessionId = t.shell.view().session.id;
  await t.shell.onMarked({ sessionId, ack: "marked-ack", id: 1, rel: "media/shot-001.png", isNew: true, kept: true, changed: true });
  assert.deepEqual(t.app.calls.filter(([c]) => c === "capture_filed").map(([, a]) => a), [{ ack: "marked-ack", inserted: true }]);
});

test("a capture is not inserted into a same-id copied session", async () => {
  const t = await setup({ session: true, captureCanInsert: false });
  let inserted = 0;
  t.editor.insertMedia = () => { inserted++; };
  await t.shell.onMarked({ sessionId: t.shell.view().session.id, ack: "origin-ack", id: 1, rel: "media/shot-001.png", isNew: true, kept: true, changed: true });
  assert.equal(inserted, 0);
  assert.deepEqual(t.app.calls.filter(([c]) => c === "capture_filed").map(([, a]) => a), [{ ack: "origin-ack", inserted: false }]);
});

test("two captures waiting on one failed note save are both acknowledged", async () => {
  const t = await setup({ session: true });
  let pending = null;
  t.editor.insertMedia = ({ src }) => { pending = { id: 1, markdown: src }; };
  t.editor.takePending = () => { const p = pending; pending = null; return p; };
  t.editor.restorePending = (p) => { pending = p; };
  const set = t.app.notes.set.bind(t.app.notes);
  t.app.notes.set = () => { throw new Error("disk full"); };
  const sessionId = t.shell.view().session.id;
  await t.shell.onCaptured({ sessionId, ack: "first", id: 1, rel: "media/shot-001.png" });
  await t.shell.onCaptured({ sessionId, ack: "second", id: 1, rel: "media/shot-002.png" });
  t.app.notes.set = set;
  await t.shell.onEditorMessage({ type: "changed", id: 1, markdown: "both links" });
  assert.deepEqual(t.app.calls.filter(([c]) => c === "capture_filed").map(([, a]) => a), [
    { ack: "first", inserted: true },
    { ack: "second", inserted: true },
  ]);
});

test("a delayed capture stays in its source session", async () => {
  const t = await setup({ session: true, captureCanInsert: false });
  let inserted = 0;
  t.editor.insertMedia = () => { inserted++; };
  await t.shell.onCaptured({ sessionId: "another-session", ack: "source-ack", id: 1, rel: "media/clip-001.mp4", kind: "video" });
  assert.deepEqual(t.app.calls.filter(([c]) => c === "capture_filed").map(([, a]) => a), [{ ack: "source-ack", inserted: false }]);
  assert.equal(inserted, 0);
});

test("an open session deleted from outside is closed with a message", async () => {
  const t = await setup({ session: true });
  const path = t.shell.view().session.path;
  t.app.deleteFromOutside();
  t.window.dispatchEvent(new t.window.Event("focus"));
  await t.settle();
  assert.equal(t.shell.view().session, null);
  assert.equal(t.$("empty").hidden, false);
  assert.match(t.$("status-text").textContent, new RegExp(`${path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} was deleted`));
});

test("template buttons name their shortcut and Ctrl+1 types the first", async () => {
  const t = await setup({ session: true });
  const b = t.doc.querySelector("#templates .template");
  assert.match(b.title, /^Bug {2}Ctrl\+1 — inserts: \*\*Bug:\*\*/);
  t.key(t.doc.body, { key: "2", ctrlKey: true });
  await t.settle();
  assert.deepEqual(t.editor.log.filter((l) => l[0] === "insert").pop(), ["insert", "**Idea:** "]);
});

test("pasted bytes are saved into the shown item and handed back to the editor", async () => {
  const t = await setup({ session: true });
  await t.shell.onEditorMessage({ type: "media", reqId: 7, base64: "AA==", mime: "image/png", name: "" });
  // The fake app has no save_media: the editor is told it failed, and nothing breaks.
  assert.deepEqual(t.editor.log.pop(), ["failed", 7]);
  assert.equal(t.app.calls.find(([c]) => c === "save_media")[1].sessionId, t.shell.view().session.id);
  assert.equal(t.app.calls.find(([c]) => c === "save_media")[1].openToken, t.shell.view().session.openToken);
});

test("switching sessions forgets the old items in the editor", async () => {
  const t = await setup({ session: true, sessions: [{ path: "~/Snagbook/b", title: "B", items: 1, created: "2026-09-20T10:00:00Z" }] });
  await t.shell.openSession("~/Snagbook/b");
  assert.ok(t.editor.log.some((l) => l[0] === "forget" && l[1] === 1), "item 1 of the new session is not the old item 1");
  const opened = t.editor.log.filter((l) => l[0] === "open").pop()[1];
  assert.equal(opened.id, 1);
});

test("key presses spell shortcuts the way the settings do", () => {
  assert.equal(comboFromEvent({ key: "s", code: "KeyS", ctrlKey: true, altKey: true }), "Ctrl+Alt+S");
  assert.equal(comboFromEvent({ key: "§", code: "Digit5", ctrlKey: true, shiftKey: true }), "Ctrl+Shift+5", "the key, not what the layout types");
  assert.equal(comboFromEvent({ key: "F5", code: "F5" }), "F5");
  assert.equal(comboFromEvent({ key: "Control", code: "ControlLeft", ctrlKey: true }), null);
  assert.ok(sameCombo("Ctrl+Alt+S", "alt+control+s"));
  assert.ok(!sameCombo("Ctrl+Alt+S", "Ctrl+S"));
  assert.ok(!sameCombo("", ""), "an empty shortcut matches nothing");
});

test("a drag becomes a rectangle in fractions; a click does not", () => {
  assert.deepEqual(rectFraction({ x: 100, y: 50 }, { x: 300, y: 250 }, 1000, 500), { x: 0.1, y: 0.1, w: 0.2, h: 0.4 });
  assert.deepEqual(rectFraction({ x: 300, y: 250 }, { x: 100, y: 50 }, 1000, 500), { x: 0.1, y: 0.1, w: 0.2, h: 0.4 }, "dragged up and left");
  assert.equal(rectFraction({ x: 10, y: 10 }, { x: 12, y: 40 }, 1000, 500), null);
});

test("the configured screenshot shortcut also works inside the window", async () => {
  const t = await setup({ session: true });
  t.shell.view().config.shortcuts = { screenshot: "Ctrl+Alt+S", newItem: "", showNotebook: "" };
  t.key(t.doc.body, { key: "s", code: "KeyS", ctrlKey: true, altKey: true });
  await t.settle();
  assert.ok(t.app.calls.some(([c]) => c === "start_screenshot"));
});

test("the recording timer reads like a clock", () => {
  assert.equal(formatElapsed(0), "0:00");
  assert.equal(formatElapsed(65.9), "1:05");
  assert.equal(formatElapsed(3723), "1:02:03");
  assert.equal(formatElapsed(-3), "0:00");
});

test("Record turns into Stop while a recording runs", async () => {
  const t = await setup({ session: true });
  assert.equal(t.$("rec").textContent, "Record");
  t.shell.setRecording(true);
  assert.equal(t.$("rec").textContent, "Stop");
  assert.match(t.$("rec").title, /^Stop recording/);
  t.shell.setRecording(false);
  assert.equal(t.$("rec").textContent, "Record");
});

test("switching items while the title field has focus never renames the item switched to", async () => {
  const t = await setup({ session: true });
  await t.shell.newItem(); // item 2, its title field focused and showing "Item 2"
  assert.equal(t.doc.activeElement, t.$("item-title"));
  await t.shell.show(1);
  t.$("item-title").blur();
  await t.settle();
  assert.deepEqual(t.shell.view().session.items.map((i) => i.title), ["Item 1", "Item 2"]);
  assert.equal(t.$("item-title").value, "Item 1", "the field shows the item switched to");
});

test("a title typed and not yet saved goes to its own item when you switch", async () => {
  const t = await setup({ session: true });
  await t.shell.newItem();
  t.$("item-title").value = "Inventory";
  await t.shell.show(1);
  t.$("item-title").blur();
  await t.settle();
  assert.deepEqual(t.shell.view().session.items.map((i) => i.title), ["Item 1", "Inventory"]);
});

test("Settings can turn off opening screenshots in mark-up", async () => {
  const t = await setup({ session: true });
  const p = t.shell.settings();
  await t.settle();
  const box = [...t.$("modal").querySelectorAll("label")].find((l) => /mark-up window/.test(l.textContent)).querySelector("input");
  assert.equal(box.checked, true, "on by default, as on the macOS app");
  box.checked = false;
  await t.answer(true);
  await p;
  const patch = t.app.calls.find(([c]) => c === "update_config")[1].patch;
  assert.equal(patch.annotateScreenshots, false);
});

test("a slow note of an item left behind does not open over the one chosen next", async () => {
  const { shell, app, editor, settle } = await setup({ session: true });
  await shell.newItem();
  app.notes.set(1, "one");
  app.notes.set(2, "two");
  app.slowNoteFor(1);
  editor.log.length = 0;
  const first = shell.show(1);
  const second = shell.show(2);
  await Promise.all([first, second]);
  await new Promise((r) => setTimeout(r, 60));
  await settle();
  const opened = editor.log.filter((e) => e[0] === "open").map((e) => e[1].id);
  assert.deepEqual(opened, [2], "only item 2 is opened: " + JSON.stringify(opened));
  assert.equal(shell.selected(), 2, "and item 2 stays selected");
});

test("Copy Hand-off says so in green, and the next plain message is not green", async () => {
  const { shell, $ } = await setup({ session: true });
  await shell.copyHandoff();
  assert.match($("status-text").textContent, /copied/);
  assert.ok($("status-text").classList.contains("ok"), "the copied line is green");
  await shell.newSession();
  assert.ok(!$("status-text").classList.contains("ok"), "an ordinary message is not green");
});

test("item 1 of another session, or a new item 1 after a delete, gets new picture addresses", async () => {
  const { shell, editor, settle, answer } = await setup({ session: true });
  const bases = () => editor.log.filter((e) => e[0] === "open" && e[1].id === 1).map((e) => e[1].base);
  const first = bases().at(-1);
  await shell.newSession();
  await settle();
  const second = bases().at(-1);
  assert.notEqual(second, first, "the page would show the old session's image-001.png");
  const deleted = shell.deleteItem(1);
  await answer(true);
  await deleted;
  await settle();
  await shell.newItem();
  await settle();
  assert.ok(![first, second].includes(bases().at(-1)), "a new item 1 must not reuse the deleted one's addresses");
});
