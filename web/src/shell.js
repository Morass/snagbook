// The notebook around the editor: sessions, the item list, titles, templates, hand-off.
// Everything on disk goes through `invoke` (the app's commands), so tests pass a fake one.

export function keyLabel(platform, combo) {
  // combo like "Mod+Shift+N"
  const mac = platform === "macos";
  return combo
    .split("+")
    .map((k) => (k === "Mod" ? (mac ? "⌘" : "Ctrl") : k === "Shift" ? (mac ? "⇧" : "Shift") : k === "Alt" ? (mac ? "⌥" : "Alt") : k))
    .join(mac ? "" : "+");
}

/// Tooltip text that leads with the shortcut: "Screenshot  Ctrl+Shift+S — drag a rectangle".
export function tip(what, keys, detail = "") {
  return what + (keys ? "  " + keys : "") + (detail ? " — " + detail : "");
}

/// Where the editor loads item `id`'s files. `epoch` changes with the session and when an
/// item is deleted: the page keeps every picture it has shown by address, so without it
/// item 1's media/image-001.png of another session (or of a deleted item 1) would be shown
/// in place of a new one of the same name.
export function mediaBase(platform, id, epoch = 0) {
  const at = `item/${id}.${epoch}/`;
  return platform === "windows" ? `http://snagbook.localhost/${at}` : `snagbook://localhost/${at}`;
}

/// A key press as "Ctrl+Alt+S" (the spelling of the shortcut settings); null for a lone
/// modifier.
export function comboFromEvent(e) {
  const k = e.key;
  if (["Control", "Shift", "Alt", "Meta", "AltGraph", "OS"].includes(k)) return null;
  const code = e.code || "";
  let name = code.startsWith("Key") ? code.slice(3) : code.startsWith("Digit") ? code.slice(5) : k.length === 1 ? k.toUpperCase() : k;
  if (name === " ") name = "Space";
  const mods = [e.ctrlKey && "Ctrl", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "Super"].filter(Boolean);
  return [...mods, name].join("+");
}

/// Two spellings of the same shortcut compare equal ("ctrl+alt+s", "Alt+Control+S").
export function sameCombo(a, b) {
  const norm = (s) =>
    String(s || "")
      .split("+")
      .map((p) => p.trim().toLowerCase())
      .map((p) => ({ control: "ctrl", option: "alt", cmd: "super", command: "super", meta: "super" })[p] || p)
      .filter(Boolean)
      .sort()
      .join("+");
  return !!a && !!b && norm(a) === norm(b);
}

/// The item to show after the one at `index` went away: the one now in its place, or the
/// last one.
export function neighbour(items, index) {
  if (!items.length) return null;
  return items[Math.min(index, items.length - 1)].id;
}

export function createShell({ invoke, snag, doc = globalThis.document, win = globalThis.window }) {
  const $ = (id) => doc.getElementById(id);
  const el = (tag, props = {}, ...kids) => {
    const e = doc.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "class") e.className = v;
      else if (k === "text") e.textContent = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null) e.setAttribute(k, v);
    }
    for (const kid of kids) if (kid !== null && kid !== undefined) e.append(kid);
    return e;
  };

  let view = null;
  let selected = null;
  let editorItem = null;
  let shownPath = null;
  let shownOpenToken = null;
  let editorReady = false;
  let titleFor = null;
  let statusTimer = null;
  const pendingCaptureAcks = new Map();
  const pendingOriginAcks = new Map();
  const originRevisions = new Map();
  const editorWrites = new Set();
  let flushTail = Promise.resolve();
  let noteTail = Promise.resolve();
  let acknowledgementTail = Promise.resolve();
  let originTail = Promise.resolve();
  let editorLocks = 0;
  const s = { view: () => view, selected: () => selected };

  function lockEditor() {
    const ed = snag();
    if (++editorLocks === 1) ed?.setReadOnly?.(true);
    return () => {
      if (editorLocks > 0 && --editorLocks === 0) ed?.setReadOnly?.(false);
    };
  }

  const platform = () => view?.platform || "linux";
  const key = (combo) => keyLabel(platform(), combo);
  const items = () => view?.session?.items || [];

  // ------------------------------------------------------------ talking to the app

  async function call(cmd, args = {}) {
    try {
      return await invoke(cmd, args);
    } catch (e) {
      const msg = String(e?.message || e);
      if (!msg.startsWith("NOTRASH:")) flash(msg, "error");
      throw e;
    }
  }

  /// A line in the status bar: tone "error" is red and stays longer, "ok" is green.
  function flash(text, tone = "") {
    const t = $("status-text");
    t.textContent = text;
    t.classList.toggle("error", tone === "error");
    t.classList.toggle("ok", tone === "ok");
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => (t.textContent = ""), tone === "error" ? 8000 : 4000);
  }

  /// Save what the editor has not reported yet (before switching items or sessions).
  function flush(options = {}) {
    const work = flushTail.then(() => flushOnce(options));
    flushTail = work.catch(() => {});
    return work;
  }

  async function flushOnce({ required = false } = {}) {
    const ed = snag();
    if (!ed || !editorReady) return;
    let ackItem = editorItem;
    while (true) {
      while (editorWrites.size) await Promise.allSettled([...editorWrites]);
      const p = ed.takePending?.();
      if (!p || p.id == null) {
        if (editorWrites.size) continue;
        break;
      }
      ackItem = p.id;
      try {
        await saveNote({ sessionId: view?.session?.id, openToken: view?.session?.openToken, itemToken: p.itemToken, id: p.id, markdown: p.markdown });
      } catch (e) {
        ed.restorePending?.(p);
        if (required) throw e;
        return;
      }
    }
    if (ackItem != null) {
      try { await serializeAcknowledgement(ackItem); }
      catch (e) { if (required) throw e; }
    }
  }

  function saveNote(args) {
    const writing = noteTail.then(() => call("write_note", args));
    noteTail = writing.catch(() => {});
    editorWrites.add(writing);
    writing.then(() => editorWrites.delete(writing), () => editorWrites.delete(writing));
    return writing;
  }

  function serializeAcknowledgement(id) {
    const work = acknowledgementTail.then(() => acknowledgeCapture(id));
    acknowledgementTail = work.catch(() => {});
    return work;
  }

  async function acknowledgeCapture(id) {
    const pending = pendingCaptureAcks.get(id) || [];
    const remaining = [];
    for (const p of pending) {
      if (p.sessionId !== view?.session?.id || p.openToken !== view?.session?.openToken) {
        remaining.push(p);
        continue;
      }
      try {
        await call("capture_filed", { ack: p.ack, inserted: true });
      } catch (e) {
        remaining.push(p);
        pendingCaptureAcks.set(id, remaining.concat(pending.slice(pending.indexOf(p) + 1)));
        throw e;
      }
    }
    if (remaining.length) pendingCaptureAcks.set(id, remaining);
    else pendingCaptureAcks.delete(id);
  }

  async function apply(v, { select } = {}) {
    const newSession = v.session?.path !== shownPath || v.session?.openToken !== shownOpenToken;
    const oldIds = items().map((i) => i.id);
    view = v;
    if (v.closed) flash(`The session folder ${v.closed} was deleted, so it was closed.`, "error");
    if (newSession) {
      shownPath = v.session?.path ?? null;
      shownOpenToken = v.session?.openToken ?? null;
      selected = null;
      for (const id of oldIds) snag()?.forget?.(id);
      editorItem = null;
      epoch++;
    }
    const ids = items().map((i) => i.id);
    let want = select ?? selected;
    if (want == null || !ids.includes(want)) want = newSession ? ids[ids.length - 1] ?? null : neighbour(items(), Math.max(0, ids.indexOf(selected)));
    render();
    if (want !== selected || newSession) await show(want, { focus: false });
    else renderTitle();
    await retryOriginCaptures();
  }

  async function refresh() {
    await apply(await call("state"));
  }

  async function reloadOriginItem(origin) {
    if (!originIsOpen(origin)) return;
    const openToken = view.session.openToken;
    const md = await call("read_note", { id: origin.id });
    if (!originIsOpen(origin)) return;
    if (view.session.openToken !== openToken) throw new Error("The source session changed while its note was reloading.");
    const itemToken = items().find((item) => item.id === origin.id)?.itemToken;
    snag()?.open({ id: origin.id, itemToken, markdown: md, base: mediaBase(platform(), origin.id, epoch), sessionId: origin.sessionId, openToken, focus: false });
    editorItem = origin.id;
  }

  // ------------------------------------------------------------ items

  let showing = 0;
  let epoch = 0; // part of every media address; see mediaBase

  async function show(id, { focus = true } = {}) {
    // Only the latest call opens its note: a slow read of an item left behind must not
    // open over the one chosen after it (its typing would go into the wrong note).
    const turn = ++showing;
    try { await flush({ required: true }); }
    catch { return; }
    if (titleFor != null && titleFor !== id) await renameSelected().catch(() => {});
    if (turn !== showing) return;
    selected = id;
    invoke("set_selected", { id }).catch(() => {});
    renderList();
    renderTitle();
    const ed = snag();
    if (id == null || !ed || !editorReady) {
      editorItem = null;
      return;
    }
    let md = "";
    const revisionKey = originRevisionKey({ path: view.session.path, sessionId: view.session.id, id });
    let revision = originRevisions.get(revisionKey) || 0;
    try {
      while (true) {
        md = await call("read_note", { id });
        const current = originRevisions.get(revisionKey) || 0;
        if (current === revision) break;
        revision = current;
      }
    } catch {
      return refresh();
    }
    if (turn !== showing || selected !== id) return;
    ed.open({ id, itemToken: items().find((item) => item.id === id)?.itemToken, markdown: md, base: mediaBase(platform(), id, epoch), sessionId: view.session.id, openToken: view.session.openToken, focus });
    editorItem = id;
    lockPendingOriginEditors();
  }

  async function newItem() {
    await flush();
    const before = new Set(items().map((i) => i.id));
    const v = await call("add_item", { title: null });
    const added = v.session.items.find((i) => !before.has(i.id));
    await apply(v, { select: added?.id });
    const t = $("item-title");
    t.focus();
    t.select();
  }

  async function newSession() {
    if (!(await changeSession(() => call("new_session")))) return;
    flash(`New session: ${view.session.path}`);
    $("item-title").focus();
    $("item-title").select();
  }

  async function openSession(path) {
    await changeSession(() => call("open_session", { path }));
  }

  async function changeSession(request) {
    const unlock = lockEditor();
    try {
      try { await flush({ required: true }); }
      catch { flash("The note could not be saved, so the session was not changed.", "error"); return false; }
      const v = await request();
      if (!v) return false;
      await apply(v);
      return true;
    } finally { unlock(); }
  }

  /// Save the title field into the item it shows. That is `titleFor`, not `selected`: the
  /// field loses focus (and saves) after the selection has already moved on.
  async function renameSelected() {
    const t = $("item-title");
    const id = titleFor;
    const it = items().find((i) => i.id === id);
    if (!it) return;
    const title = t.value.trim();
    if (!title) {
      if (id === selected) t.value = it.title;
      return;
    }
    if (title === it.title) return;
    await apply(await call("rename_item", { id, title }));
  }

  async function deleteItem(id) {
    const it = items().find((i) => i.id === id);
    if (!it) return;
    const sessionId = view.session.id;
    const openToken = view.session.openToken;
    const itemToken = it.itemToken;
    const ok = await confirm(`Delete “${it.title}”?`, "Its folder, with the note and all its pictures and videos, goes to the Trash.", "Move to Trash");
    if (!ok) return;
    if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) {
      return flash("The open session changed, so the item was not deleted.", "error");
    }
    const unlock = lockEditor();
    try {
      try { await flush({ required: true }); }
      catch { return flash("The note could not be saved, so the item was not deleted.", "error"); }
      if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) {
        return flash("The open session changed, so the item was not deleted.", "error");
      }
      const index = items().findIndex((i) => i.id === id);
      let v;
      try {
        v = await call("delete_item", { sessionId, openToken, itemToken, id, permanently: false });
      } catch (e) {
        const msg = String(e?.message || e);
        if (!msg.startsWith("NOTRASH:")) return flash(msg, "error");
        const again = await confirm(
          `Delete “${it.title}” permanently?`,
          `It could not go to the Trash (${msg.slice(8) || "this drive has none"}), so its folder, with the note and all its pictures and videos, would be deleted for good.`,
          "Delete Permanently"
        );
        if (!again) return;
        if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) {
          return flash("The open session changed, so the item was not deleted.", "error");
        }
        v = await call("delete_item", { sessionId, openToken, itemToken, id, permanently: true });
      }
      if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) return;
      snag()?.forget?.(id);
      epoch++;
      const rest = v.session?.items || [];
      await apply(v, { select: selected === id ? neighbour(rest, Math.max(0, index - 1)) : selected });
    } finally {
      unlock();
    }
  }

  async function deleteSession() {
    if (!view?.session) return;
    const title = view.session.title;
    const sessionId = view.session.id;
    const openToken = view.session.openToken;
    const ok = await confirm(`Delete “${title}”?`, "The whole session folder, with every item, note, picture and video, goes to the Trash.", "Move to Trash");
    if (!ok) return;
    const unlock = lockEditor();
    try {
      try { await flush({ required: true }); }
      catch { return flash("The note could not be saved, so the session was not deleted.", "error"); }
      if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) return flash("The open session changed, so it was not deleted.", "error");
      let v;
      try {
        v = await call("delete_session", { sessionId, openToken, permanently: false });
      } catch (e) {
        const msg = String(e?.message || e);
        if (!msg.startsWith("NOTRASH:")) return flash(msg, "error");
        const again = await confirm(
          `Delete “${title}” permanently?`,
          `It could not go to the Trash (${msg.slice(8) || "this drive has none"}), so the whole session folder would be deleted for good.`,
          "Delete Permanently"
        );
        if (!again) return;
        if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) return flash("The open session changed, so it was not deleted.", "error");
        v = await call("delete_session", { sessionId, openToken, permanently: true });
      }
      if (view?.session?.id !== sessionId || view?.session?.openToken !== openToken) return;
      await apply(v);
    } finally {
      unlock();
    }
  }

  async function moveItem(id, index) {
    await apply(await call("move_item", { id, index }));
  }

  async function insertTemplate(t) {
    if (selected == null) await newItem();
    snag()?.insertMarkdown(t.body);
    snag()?.focus();
  }

  async function record() {
    await flush();
    await call("toggle_recording").catch(() => {}); // a refusal is shown by call()
  }

  function setRecording(on) {
    if (view) view.recording = on ? view.recording || Date.now() : null;
    renderRecord();
  }

  function renderRecord() {
    const b = $("rec");
    const on = !!view?.recording;
    b.textContent = on ? "Stop" : "Record";
    b.classList.toggle("recording", on);
    const sc = view?.config?.shortcuts || {};
    b.title = on ? tip("Stop recording", sc.record || "") : tip("Record", sc.record || "", "drag the area; recording starts when you let go");
  }

  async function screenshot() {
    await flush();
    await call("start_screenshot").catch(() => {});
  }

  function serializeOrigin(work) {
    const running = originTail.then(work);
    originTail = running.catch(() => {});
    return running;
  }

  function leaveCaptureInOrigin(ack, origin) {
    return serializeOrigin(async () => {
    if (ack) {
      const pending = { ...origin, filed: false, unlock: null };
      pendingOriginAcks.set(ack, pending);
      const isOpen = originIsOpen(pending);
      if (isOpen) pending.unlock = lockEditor();
      try {
        if (isOpen) await flush({ required: true });
        await call("capture_filed", { ack, inserted: false });
        pending.filed = true;
        bumpOriginRevision(pending);
        if (originIsOpen(pending)) await reloadOriginItem(pending);
        pending.unlock?.();
        pendingOriginAcks.delete(ack);
      } catch {
        if (!pending.filed || !originIsOpen(pending)) {
          pending.unlock?.();
          pending.unlock = null;
        }
        return false;
      }
    }
    return true;
    });
  }

  function retryOriginCaptures() {
    return serializeOrigin(async () => {
    for (const [ack, origin] of [...pendingOriginAcks]) {
      const isOpen = originIsOpen(origin);
      if (isOpen && !origin.unlock) origin.unlock = lockEditor();
      try {
        if (!origin.filed) {
          if (isOpen) await flush({ required: true });
          await call("capture_filed", { ack, inserted: false });
          origin.filed = true;
          bumpOriginRevision(origin);
        }
        if (originIsOpen(origin)) await reloadOriginItem(origin);
        origin.unlock?.();
        pendingOriginAcks.delete(ack);
      } catch {
        if (!origin.filed || !originIsOpen(origin)) {
          origin.unlock?.();
          origin.unlock = null;
        }
      }
    }
    });
  }

  function originIsOpen(origin) {
    return !!origin && editorItem === origin.id
      && view?.session?.id === origin.sessionId
      && (origin.path ? view.session.path === origin.path : view.session.openToken === origin.openToken);
  }

  function lockPendingOriginEditors() {
    for (const origin of pendingOriginAcks.values()) {
      if (originIsOpen(origin) && !origin.unlock) origin.unlock = lockEditor();
    }
  }

  function originRevisionKey(origin) {
    return `${origin.path || origin.sessionId}\u0000${origin.id}`;
  }

  function bumpOriginRevision(origin) {
    const key = originRevisionKey(origin);
    originRevisions.set(key, (originRevisions.get(key) || 0) + 1);
  }

  /// A screenshot was saved into item `id`: show it and put it in the note at the caret.
  async function onCaptured({ sessionId, sessionPath = null, ack, id, rel, kind = "image", label = "", problem = null }) {
    const expectedSessionId = view?.session?.id;
    const expectedOpenToken = view?.session?.openToken;
    const expectedPath = view?.session?.path;
    const stillHere = () => view?.session?.id === expectedSessionId && view?.session?.openToken === expectedOpenToken;
    const path = sessionPath || (sessionId === expectedSessionId ? expectedPath : null);
    const openToken = sessionId === expectedSessionId && path === expectedPath ? expectedOpenToken : null;
    const origin = { id, sessionId, openToken, path };
    const belongsHere = ack ? await call("capture_can_insert", { ack }).catch(() => false) : sessionId === view?.session?.id;
    if (!belongsHere || !stillHere()) {
      const filed = await leaveCaptureInOrigin(ack, origin);
      await refresh();
      if (filed) flash("The capture stayed in its original session.");
      return;
    }
    await apply(await call("state"), { select: id });
    if (!stillHere()) {
      const filed = await leaveCaptureInOrigin(ack, origin);
      if (filed) flash("The capture stayed in its original session.");
      return;
    }
    if (selected !== id || editorItem !== id) await show(id, { focus: false });
    if (!stillHere() || selected !== id || editorItem !== id) {
      const filed = await leaveCaptureInOrigin(ack, origin);
      if (filed) flash("The capture stayed in its original session.");
      return;
    }
    if (editorLocks > 0 || snag()?.insertMedia({ kind, src: rel, label }) === false) {
      const filed = await leaveCaptureInOrigin(ack, origin);
      if (filed) flash("The capture stayed in its original session.");
      return;
    }
    try {
      await flush({ required: !!ack });
      if (ack) await call("capture_filed", { ack, inserted: true });
    } catch {
      if (ack) {
        if (!stillHere()) {
          const filed = await leaveCaptureInOrigin(ack, origin);
          if (filed) flash("The capture stayed in its original session.");
          return;
        }
        const pending = pendingCaptureAcks.get(id) || [];
        pending.push({ ack, sessionId: expectedSessionId, openToken: expectedOpenToken });
        pendingCaptureAcks.set(id, pending);
      }
      return;
    }
    await refresh();
    const it = items().find((i) => i.id === id);
    const where = it?.title ?? "item " + id;
    if (problem) flash(`${kind === "video" ? "Recording" : "Stills"} saved to ${where}, but ${problem}.`, "error");
    else flash(`${kind === "video" ? "Recording" : "Screenshot"} saved to ${where}`);
  }

  /// The mark-up window finished: a new screenshot goes into the note (or is gone); an
  /// existing picture is redrawn.
  async function onMarked({ sessionId, sessionPath = null, ack, id, rel, isNew, kept, changed }) {
    if (isNew && kept) return onCaptured({ sessionId, sessionPath, ack, id, rel, kind: "image" });
    if (sessionId && view?.session?.id !== sessionId) {
      await refresh();
      return flash("The marked picture stayed in its original session.");
    }
    if (isNew) {
      await refresh();
      return flash("Screenshot discarded");
    }
    if (changed) snag()?.refreshMedia(rel);
    await refresh();
  }

  async function copyHandoff() {
    try { await flush({ required: true }); }
    catch { return null; }
    const text = await call("copy_handoff");
    flash("✓ Hand-off copied: " + text.split("\n")[0].slice(0, 80), "ok");
    return text;
  }

  // ------------------------------------------------------------ drawing

  function render() {
    const has = !!view?.session;
    $("note").hidden = !has;
    $("topbar").hidden = !has;
    $("templates").hidden = !has;
    $("empty").hidden = has;
    renderSessionButton();
    renderList();
    renderTemplates();
    renderTitle();
    if (!has) renderEmpty();
    renderRecord();
    $("new-item-key").textContent = key("Mod+N");
    $("new-item").title = tip("New item", key("Mod+N"));
    $("handoff").title = tip("Copy hand-off", key("Mod+Shift+C"), "the text that hands this session to an agent");
    const sc = view?.config?.shortcuts || {};
    $("shot").title = tip("Screenshot", sc.screenshot || "", "drag a rectangle; it goes into this item");
    $("new-item").title = tip("New item", key("Mod+N"), sc.newItem ? "anywhere " + sc.newItem : "");
    $("items").setAttribute("aria-activedescendant", selected == null ? "" : "item-" + selected);
    if (view?.loadError) flash("Settings could not be read, so they are not saved: " + view.loadError, "error");
  }

  function renderSessionButton() {
    const b = $("session-button");
    b.textContent = "";
    if (!view?.session) {
      b.append(el("span", { class: "session-title", text: "No session" }));
    } else {
      const n = items().length;
      b.append(el("span", { class: "session-title", text: view.session.title }), el("span", { class: "session-sub", text: `${n} item${n === 1 ? "" : "s"}` }));
    }
    b.title = "Switch session, start a new one, or rename this one";
  }

  function renderList() {
    const ol = $("items");
    ol.textContent = "";
    items().forEach((it, i) => {
      const counts = [it.images ? `🖼 ${it.images}` : "", it.videos ? `🎬 ${it.videos}` : ""].filter(Boolean).join(" ");
      const li = el(
        "li",
        {
          id: "item-" + it.id,
          class: "item" + (it.id === selected ? " selected" : ""),
          draggable: "true",
          "data-id": it.id,
          onclick: () => show(it.id),
          oncontextmenu: (e) => {
            e.preventDefault();
            itemMenu(it, e.clientX, e.clientY);
          },
          ondragstart: (e) => e.dataTransfer?.setData("text/snag-item", String(it.id)),
          ondragover: (e) => e.preventDefault(),
          ondrop: (e) => {
            e.preventDefault();
            const from = Number(e.dataTransfer?.getData("text/snag-item"));
            if (from && from !== it.id) moveItem(from, i);
          },
        },
        el("span", { class: "num", text: String(i + 1) }),
        el("span", { class: "title", text: it.title }),
        counts ? el("span", { class: "counts", text: counts }) : null
      );
      ol.append(li);
    });
  }

  function renderTitle() {
    const it = items().find((i) => i.id === selected);
    const t = $("item-title");
    // Keep what is being typed, but only for the item it belongs to.
    if (doc.activeElement !== t || titleFor !== selected) t.value = it?.title ?? "";
    titleFor = selected;
    t.disabled = !it;
  }

  function renderTemplates() {
    const bar = $("templates");
    bar.textContent = "";
    (view?.config?.templates || []).forEach((t, i) => {
      const preview = t.body.replace(/\s+/g, " ").trim().slice(0, 40);
      bar.append(
        el(
          "button",
          { type: "button", class: "template", title: tip(t.label, i < 9 ? key(`Mod+${i + 1}`) : "", "inserts: " + preview), onclick: () => insertTemplate(t) },
          t.icon ? el("span", { class: "icon", text: t.icon }) : null,
          t.label
        )
      );
    });
  }

  async function renderEmpty() {
    const box = $("empty");
    box.textContent = "";
    box.append(
      el("div", { class: "empty-icon", text: "📓" }),
      el("h2", { text: "Start a session" }),
      el("p", { text: "A session is one sitting of testing: numbered items, each with a note, screenshots and recordings." }),
      el("button", { type: "button", class: "primary", onclick: newSession, title: tip("New session", key("Mod+Shift+N")) }, "New Session")
    );
    const recent = (await call("list_sessions").catch(() => [])).slice(0, 6);
    if (view?.session || !recent.length) return;
    const list = el("div", { class: "recent" }, el("div", { class: "caption", text: "Or continue one" }));
    for (const r of recent) {
      list.append(
        el("button", { type: "button", class: "recent-row", onclick: () => openSession(r.path) }, el("span", { text: r.title }), el("span", { class: "sub", text: `${r.items} item${r.items === 1 ? "" : "s"} · ${fmtDate(r.created)}` }))
      );
    }
    box.append(list);
  }

  function fmtDate(iso) {
    const d = new Date(iso);
    return isNaN(d) ? iso : d.toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  }

  // ------------------------------------------------------------ menus and dialogs

  function popup(x, y, entries) {
    const m = $("menu");
    m.textContent = "";
    for (const e of entries) {
      if (e === "-") m.append(el("div", { class: "sep" }));
      else if (e.caption) m.append(el("div", { class: "caption", text: e.caption }));
      else
        m.append(
          el(
            "button",
            {
              type: "button",
              class: "menu-row" + (e.danger ? " danger" : "") + (e.checked ? " checked" : ""),
              onclick: () => {
                closeMenu();
                e.run();
              },
            },
            el("span", { text: e.label }),
            e.sub ? el("span", { class: "sub", text: e.sub }) : null
          )
        );
    }
    m.hidden = false;
    m.style.left = x + "px";
    m.style.top = y + "px";
  }

  function closeMenu() {
    $("menu").hidden = true;
  }

  async function sessionMenu() {
    const b = $("session-button").getBoundingClientRect();
    // Reconcile the open session and read the folder each time the menu is unrolled.
    await apply(await call("state"), { select: selected });
    const recent = (await call("list_sessions").catch(() => [])).slice(0, 12);
    const cur = view?.session?.path;
    const entries = [];
    if (recent.length) {
      entries.push({ caption: "Recent sessions" });
      for (const r of recent) entries.push({ label: r.title, sub: `${r.items} item${r.items === 1 ? "" : "s"} · ${fmtDate(r.created)}`, checked: r.path === cur, run: () => openSession(r.path) });
      entries.push("-");
    }
    entries.push({ label: "New Session", sub: key("Mod+Shift+N"), run: newSession });
    if (view?.session) {
      entries.push({ label: "Rename This Session…", run: renameSession });
      entries.push({ label: "Edit Header…", run: editHeader });
    }
    entries.push({ label: "Open Another Folder…", run: pickFolder });
    if (view?.session) entries.push({ label: "Show in Files", run: () => call("reveal", { id: null }) });
    if (view?.session) entries.push("-", { label: "Delete This Session…", danger: true, run: deleteSession });
    entries.push("-", { label: "Settings…", sub: key("Mod+,"), run: settings });
    popup(b.left + 4, b.bottom + 2, entries);
  }

  function itemMenu(it, x, y) {
    popup(x, y, [
      { label: "Rename…", run: () => renameItemDialog(it) },
      { label: "Show in Files", run: () => call("reveal", { id: it.id }) },
      "-",
      { label: "Delete…", danger: true, run: () => deleteItem(it.id) },
    ]);
  }

  async function pickFolder() {
    await changeSession(() => call("pick_session_folder"));
  }

  /// A modal with `body` and buttons; resolves to the value of the button pressed (Escape: null).
  function modal(title, body, buttons) {
    return new Promise((resolve) => {
      const box = $("modal");
      box.textContent = "";
      const done = (v) => {
        box.hidden = true;
        box.textContent = "";
        doc.removeEventListener("keydown", onKey, true);
        resolve(v);
      };
      const row = el("div", { class: "buttons" });
      for (const b of buttons) row.append(el("button", { type: "button", class: (b.primary ? "primary" : "") + (b.danger ? " danger" : ""), onclick: () => done(b.value), "data-value": String(b.value) }, b.label));
      const card = el("div", { class: "card", role: "dialog", "aria-label": title }, el("h3", { text: title }), body, row);
      box.append(card);
      box.hidden = false;
      const onKey = (e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          done(null);
        } else if (e.key === "Enter" && !(e.target instanceof win.HTMLTextAreaElement)) {
          const focused = doc.activeElement?.closest?.("button");
          const p = focused ? buttons.find((b) => String(b.value) === focused.dataset.value) : buttons.find((b) => b.primary);
          if (p) {
            e.preventDefault();
            done(p.value);
          }
        }
      };
      doc.addEventListener("keydown", onKey, true);
      (card.querySelector("input, textarea") || card.querySelector("button.primary"))?.focus();
    });
  }

  async function confirm(title, text, okLabel) {
    return (await modal(title, el("p", { text }), [{ label: "Cancel", value: false }, { label: okLabel, value: true, primary: true, danger: true }])) === true;
  }

  async function ask(title, value, okLabel = "Rename") {
    const input = el("input", { type: "text", value, spellcheck: "false" });
    input.value = value;
    const r = await modal(title, input, [{ label: "Cancel", value: false }, { label: okLabel, value: true, primary: true }]);
    return r ? input.value : null;
  }

  async function renameItemDialog(it) {
    const t = await ask("Rename item", it.title);
    if (t != null && t.trim() && t.trim() !== it.title) await apply(await call("rename_item", { id: it.id, title: t }));
  }

  async function renameSession() {
    const t = await ask("Rename session", view.session.title);
    if (t != null) await apply(await call("set_session_title", { title: t }));
  }

  async function editHeader() {
    const own = view.session.header != null;
    const text = el("textarea", { rows: "10", spellcheck: "false" });
    text.value = view.session.header ?? view.config.header;
    const global = el("input", { type: "radio", name: "hdr", id: "hdr-global" });
    const mine = el("input", { type: "radio", name: "hdr", id: "hdr-own" });
    global.checked = !own;
    mine.checked = own;
    const sync = () => {
      text.disabled = global.checked;
      if (global.checked) text.value = view.config.header;
    };
    global.addEventListener("change", sync);
    mine.addEventListener("change", sync);
    sync();
    const body = el(
      "div",
      { class: "form" },
      el("p", { class: "hint", text: "Written at the top of README.md and used by Copy Hand-off. Placeholders: {session} {readme} {date} {items}." }),
      el("label", {}, global, " Use the global header (Settings)"),
      el("label", {}, mine, " This session has its own header"),
      text
    );
    const r = await modal("Session header", body, [{ label: "Cancel", value: false }, { label: "Save", value: true, primary: true }]);
    if (r) await apply(await call("set_session_header", { header: mine.checked ? text.value : null }));
  }

  async function settings() {
    const c = view.config;
    const folder = el("input", { type: "text", spellcheck: "false" });
    folder.value = c.sessionsFolder;
    const format = el("input", { type: "text", spellcheck: "false" });
    format.value = c.folderFormat;
    const header = el("textarea", { rows: "7", spellcheck: "false" });
    header.value = c.header;
    const onTop = el("input", { type: "checkbox" });
    onTop.checked = !!c.alwaysOnTop;
    const markUp = el("input", { type: "checkbox" });
    markUp.checked = c.capture?.annotateScreenshots !== false;
    const handoff = el("select", {}, el("option", { value: "header", text: "The header, with the session filled in" }), el("option", { value: "path", text: "Only the path of README.md" }));
    handoff.value = c.handoff;
    const keyField = (value) => {
      const f = el("input", { type: "text", class: "keys", readonly: "readonly", placeholder: "Press keys (Backspace: off)" });
      f.value = value || "";
      f.addEventListener("keydown", (e) => {
        if (e.key === "Tab" || e.key === "Escape" || e.key === "Enter") return;
        e.preventDefault();
        e.stopPropagation();
        if ((e.key === "Backspace" || e.key === "Delete") && !e.ctrlKey && !e.altKey && !e.metaKey) f.value = "";
        else {
          const c = comboFromEvent(e);
          if (c && c.includes("+")) f.value = c;
        }
      });
      return f;
    };
    const sc = c.shortcuts || {};
    const kShot = keyField(sc.screenshot);
    const kRec = keyField(sc.record);
    const kNew = keyField(sc.newItem);
    const kShow = keyField(sc.showNotebook);
    const errs = view.shortcutErrors?.length ? el("p", { class: "hint error", text: view.shortcutErrors.join(" · ") }) : null;
    const tpl = el("div", { class: "templates-edit" });
    const rows = [];
    const addRow = (t) => {
      const icon = el("input", { type: "text", class: "t-icon", placeholder: "icon" });
      const label = el("input", { type: "text", class: "t-label", placeholder: "Label" });
      const body = el("input", { type: "text", class: "t-body", placeholder: "Inserted text (\\n for a new line)" });
      icon.value = t.icon || "";
      label.value = t.label || "";
      body.value = (t.body || "").replace(/\n/g, "\\n");
      const row = el("div", { class: "t-row" }, icon, label, body);
      const entry = { id: t.id, icon, label, body, row };
      row.append(el("button", { type: "button", class: "small", title: "Remove", onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); } }, "−"));
      rows.push(entry);
      tpl.append(row);
    };
    (c.templates || []).forEach(addRow);
    const body = el(
      "div",
      { class: "form" },
      el("label", { class: "field" }, el("span", { text: "Sessions folder" }), folder),
      el("label", { class: "field" }, el("span", { text: "New session folder name" }), format),
      el("p", { class: "hint", text: "Tokens: {hash} {yyyy} {MM} {dd} {HH} {mm}. A leading ~ is your home folder." }),
      el("label", { class: "field" }, el("span", { text: "Copy Hand-off copies" }), handoff),
      el("label", {}, onTop, " Keep the notebook above other windows"),
      el("label", {}, markUp, " Open new screenshots in the mark-up window"),
      el("div", { class: "field" }, el("span", { text: "Shortcuts that work in any app" }),
        el("div", { class: "keys-grid" }, el("span", { text: "Screenshot" }), kShot, el("span", { text: "Record" }), kRec, el("span", { text: "New item" }), kNew, el("span", { text: "Show notebook" }), kShow)),
      errs,
      el("div", { class: "field" }, el("span", { text: "Header for every session (placeholders: {session} {readme} {date} {items})" }), header),
      el("div", { class: "field" }, el("span", { text: "Templates" }), tpl, el("button", { type: "button", class: "small", onclick: () => addRow({ icon: "", label: "", body: "" }) }, "Add template"))
    );
    const r = await modal("Settings", body, [{ label: "Cancel", value: false }, { label: "Save", value: true, primary: true }]);
    if (!r) return;
    const templates = rows
      .filter((x) => x.label.value.trim())
      .map((x) => ({ id: x.id || undefined, icon: x.icon.value.trim(), label: x.label.value.trim(), body: x.body.value.replace(/\\n/g, "\n") }));
    await apply(
      await call("update_config", {
        patch: {
          sessionsFolder: folder.value,
          folderFormat: format.value,
          header: header.value,
          handoff: handoff.value,
          alwaysOnTop: onTop.checked,
          annotateScreenshots: markUp.checked,
          templates,
          shortcuts: { screenshot: kShot.value, record: kRec.value, newItem: kNew.value, showNotebook: kShow.value },
        },
      })
    );
  }

  // ------------------------------------------------------------ editor messages

  async function onEditorMessage(msg) {
    switch (msg?.type) {
      case "ready":
        editorReady = true;
        if (selected != null) await show(selected, { focus: false });
        break;
      case "changed":
        if (msg.id != null) {
          try {
            const sessionId = view?.session?.id;
            const openToken = view?.session?.openToken;
            await saveNote({ sessionId, openToken, itemToken: msg.itemToken, id: msg.id, markdown: msg.markdown });
            await serializeAcknowledgement(msg.id);
          } catch {
            snag()?.restorePending?.(msg);
          }
        }
        break;
      case "media": {
        const id = msg.itemId;
        try {
          if (id == null) throw new Error("the destination changed");
          const saved = await call("save_media", { sessionId: msg.sessionId, openToken: msg.openToken, itemToken: msg.itemToken, id, base64: msg.base64, mime: msg.mime || "", name: msg.name || "" });
          const sessionPath = saved.sessionPath || (view?.session?.id === msg.sessionId && view?.session?.openToken === msg.openToken ? view.session.path : null);
          const canInsert = await call("capture_can_insert", { ack: saved.ack }).catch(() => false);
          if (!canInsert || selected !== id || view?.session?.id !== msg.sessionId || view?.session?.openToken !== msg.openToken || !snag()?.mediaSaved(msg.reqId, saved.rel)) {
            snag()?.mediaFailed(msg.reqId);
            const filed = await leaveCaptureInOrigin(saved.ack, { id, sessionId: msg.sessionId, openToken: msg.openToken, path: sessionPath });
            await refresh();
            break;
          }
          const pending = pendingCaptureAcks.get(id) || [];
          pending.push({ ack: saved.ack, sessionId: msg.sessionId, openToken: msg.openToken });
          pendingCaptureAcks.set(id, pending);
          await flush({ required: true });
          await refresh();
        } catch {
          snag()?.mediaFailed(msg.reqId);
        }
        break;
      }
      case "open":
        await call("open_link", { id: selected, href: msg.href }).catch(() => {});
        break;
      case "annotate":
        if (msg.itemId != null && msg.src && !msg.src.includes("://")) {
          await call("open_markup", { sessionId: msg.sessionId, openToken: msg.openToken, itemToken: msg.itemToken, id: msg.itemId, rel: msg.src }).catch(() => {});
        }
        break;
    }
  }

  // ------------------------------------------------------------ keys and wiring

  function onKey(e) {
    if (!$("modal").hidden) return;
    const sc = view?.config?.shortcuts || {};
    const combo = comboFromEvent(e);
    if (combo && sameCombo(combo, sc.screenshot)) return stop(e, screenshot);
    if (combo && sameCombo(combo, sc.record)) return stop(e, record);
    if (combo && sameCombo(combo, sc.newItem)) return stop(e, newItem);
    const mod = platform() === "macos" ? e.metaKey : e.ctrlKey;
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (mod && !e.altKey) {
      if (k === "n" && e.shiftKey) return stop(e, newSession);
      if (k === "n") return stop(e, newItem);
      if (k === "o") return stop(e, sessionMenu);
      if (k === "c" && e.shiftKey) return stop(e, copyHandoff);
      if (k === ",") return stop(e, settings);
      if (/^[1-9]$/.test(k) && !e.shiftKey) {
        const t = view?.config?.templates?.[Number(k) - 1];
        if (t) return stop(e, () => insertTemplate(t));
      }
    }
    if (e.key === "Escape") closeMenu();
    if (doc.activeElement === $("items")) {
      const ids = items().map((i) => i.id);
      const at = ids.indexOf(selected);
      if (e.key === "ArrowDown" && at < ids.length - 1) return stop(e, () => show(ids[at + 1], { focus: false }));
      if (e.key === "ArrowUp" && at > 0) return stop(e, () => show(ids[at - 1], { focus: false }));
      if ((e.key === "Delete" || e.key === "Backspace") && selected != null) return stop(e, () => deleteItem(selected));
      if (e.key === "Enter" && selected != null) return stop(e, () => $("item-title").focus());
    }
  }

  function stop(e, fn) {
    e.preventDefault();
    e.stopPropagation();
    fn();
  }

  function wire() {
    $("new-item").addEventListener("click", newItem);
    $("session-button").addEventListener("click", (e) => {
      e.stopPropagation();
      if ($("menu").hidden) sessionMenu();
      else closeMenu();
    });
    $("handoff").addEventListener("click", copyHandoff);
    $("shot").addEventListener("click", screenshot);
    $("rec").addEventListener("click", record);
    const t = $("item-title");
    t.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        renameSelected().then(() => snag()?.focus());
      } else if (e.key === "Escape") {
        t.value = items().find((i) => i.id === titleFor)?.title ?? "";
        snag()?.focus();
      }
    });
    t.addEventListener("blur", () => renameSelected());
    doc.addEventListener("keydown", onKey, true);
    doc.addEventListener("mousedown", (e) => {
      if (!$("menu").hidden && !e.target.closest?.("#menu") && e.target !== $("session-button")) closeMenu();
    });
    // Coming back to the window: the folders may have changed underneath.
    win.addEventListener("focus", () => refresh().catch(() => {}));
  }

  async function start() {
    wire();
    await apply(await call("state"));
  }

  return Object.assign(s, {
    start,
    refresh,
    apply,
    show,
    newItem,
    newSession,
    openSession,
    deleteItem,
    deleteSession,
    moveItem,
    renameSelected,
    insertTemplate,
    copyHandoff,
    screenshot,
    record,
    setRecording,
    onCaptured,
    onMarked,
    sessionMenu,
    pickFolder,
    settings,
    onEditorMessage,
    flush,
    flash,
    editorIsReady: () => editorReady,
  });
}
