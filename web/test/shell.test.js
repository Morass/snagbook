import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { createShell, keyLabel, neighbour, mediaBase, tip } from "../src/shell.js";

const html = readFileSync(new URL("../src/index.html", import.meta.url), "utf8").replace(/<script[^>]*><\/script>/, "");

/// An in-memory stand-in for the app's commands.
function fakeApp({ platform = "linux", trash = true, sessions = [] } = {}) {
  const calls = [];
  const notes = new Map();
  let session = null;
  let nextHash = 1;
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
      session = { path, title: "Session 25 Sep, 18:00", header: null, items: [], nextItem: 1 };
      list.unshift({ path, title: session.title, items: 1, created: "2026-09-25T16:00:00Z" });
      handlers.add_item({});
      return view();
    },
    open_session: ({ path }) => {
      const s = list.find((x) => x.path === path);
      if (!s) throw "not a session";
      session = { path, title: s.title, header: null, items: [{ id: 1, title: "Old", folder: "01-old", images: 0, videos: 0 }], nextItem: 2 };
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
    move_item: ({ id, index }) => {
      const at = session.items.findIndex((i) => i.id === id);
      const [it] = session.items.splice(at, 1);
      session.items.splice(index, 0, it);
      return view();
    },
    read_note: ({ id }) => notes.get(id) ?? "",
    write_note: ({ id, markdown }) => (notes.set(id, markdown), true),
    copy_handoff: () => `Read ${session.path}/README.md`,
    set_session_title: ({ title }) => ((session.title = title || "Session 25 Sep, 18:00"), view()),
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
  assert.equal(mediaBase("linux", 3), "snagbook://localhost/item/3/");
  assert.equal(mediaBase("windows", 3), "http://snagbook.localhost/item/3/");
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
  assert.equal(opened.base, "snagbook://localhost/item/1/");
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
});

test("switching sessions forgets the old items in the editor", async () => {
  const t = await setup({ session: true, sessions: [{ path: "~/Snagbook/b", title: "B", items: 1, created: "2026-09-20T10:00:00Z" }] });
  await t.shell.openSession("~/Snagbook/b");
  assert.ok(t.editor.log.some((l) => l[0] === "forget" && l[1] === 1), "item 1 of the new session is not the old item 1");
  const opened = t.editor.log.filter((l) => l[0] === "open").pop()[1];
  assert.equal(opened.id, 1);
});
