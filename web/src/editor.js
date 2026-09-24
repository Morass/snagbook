// The note editor: a ProseMirror view over one item's Markdown, talking to the app
// through window.webkit.messageHandlers.snag (or a stub in tests).
import { EditorState, TextSelection, AllSelection, Plugin } from "prosemirror-state";
import { EditorView } from "prosemirror-view";
import { Slice, Fragment } from "prosemirror-model";
import { findWrapping } from "prosemirror-transform";
import { keymap } from "prosemirror-keymap";
import { history, undo, redo } from "prosemirror-history";
import { baseKeymap, toggleMark, setBlockType, chainCommands, exitCode, wrapIn } from "prosemirror-commands";
import { splitListItem, liftListItem, sinkListItem, wrapInList } from "prosemirror-schema-list";
import { inputRules, wrappingInputRule, textblockTypeInputRule, InputRule, smartQuotes, emDash, ellipsis } from "prosemirror-inputrules";
import { dropCursor } from "prosemirror-dropcursor";
import { gapCursor } from "prosemirror-gapcursor";
import { schema, COLORS, SIZES } from "./schema.js";
import { parseMarkdown, serializeMarkdown } from "./markdown.js";

const nodes = schema.nodes;
const marks = schema.marks;

// ---------------------------------------------------------------- bridge

function post(msg) {
  const h = globalThis.webkit?.messageHandlers?.snag;
  if (h) h.postMessage(msg);
  else if (globalThis.__snagPosted) globalThis.__snagPosted.push(msg);
}

// ---------------------------------------------------------------- commands

function markActive(state, type) {
  const { from, $from, to, empty } = state.selection;
  if (empty) return !!type.isInSet(state.storedMarks || $from.marks());
  return state.doc.rangeHasMark(from, to, type);
}

function markValue(state, type) {
  const { from, $from, to, empty } = state.selection;
  if (empty) return type.isInSet(state.storedMarks || $from.marks())?.attrs.value ?? null;
  let value = null;
  state.doc.nodesBetween(from, to, (n) => {
    const m = type.isInSet(n.marks);
    if (m && value == null) value = m.attrs.value;
  });
  return value;
}

// Set (or with value == null, clear) a valued mark such as colour or size.
function setValueMark(type, value) {
  return (state, dispatch) => {
    const { from, to, empty } = state.selection;
    if (!dispatch) return true;
    let tr = state.tr;
    if (empty) {
      tr = value == null ? tr.removeStoredMark(type) : tr.addStoredMark(type.create({ value }));
    } else {
      tr = tr.removeMark(from, to, type);
      if (value != null) tr = tr.addMark(from, to, type.create({ value }));
    }
    dispatch(tr.scrollIntoView());
    return true;
  };
}

function clearFormatting(state, dispatch) {
  const { from, to, empty } = state.selection;
  if (dispatch) {
    let tr = state.tr;
    if (empty) tr = tr.setStoredMarks([]);
    else for (const m of [marks.em, marks.strong, marks.underline, marks.strike, marks.color, marks.fontsize, marks.code]) tr = tr.removeMark(from, to, m);
    dispatch(tr);
  }
  return true;
}

function toggleList(listType, checked) {
  return (state, dispatch, view) => {
    const { $from } = state.selection;
    for (let d = $from.depth; d > 0; d--) {
      const node = $from.node(d);
      if (node.type === nodes.bullet_list || node.type === nodes.ordered_list) {
        const isChecklist = node.firstChild?.attrs.checked != null;
        const same = node.type === listType && isChecklist === (checked != null);
        if (same) return liftListItem(nodes.list_item)(state, dispatch, view);
        // switch the kind of this list in place
        if (dispatch) {
          const pos = $from.before(d);
          let tr = state.tr.setNodeMarkup(pos, listType, listType === nodes.bullet_list ? { tight: node.attrs.tight } : { tight: node.attrs.tight, order: 1 });
          node.forEach((item, offset) => {
            tr = tr.setNodeMarkup(pos + 1 + offset, null, { checked });
          });
          dispatch(tr);
        }
        return true;
      }
    }
    if (!wrapInList(listType)(state)) return false;
    if (!dispatch) return true;
    return wrapInList(listType)(state, (tr) => {
      if (checked != null) {
        // mark every new item as a task
        tr.doc.nodesBetween(tr.mapping.map(state.selection.from), tr.mapping.map(state.selection.to), (n, pos) => {
          if (n.type === nodes.list_item && n.attrs.checked == null) tr.setNodeMarkup(pos, null, { checked: false });
        });
      }
      dispatch(tr);
    });
  };
}

// Enter in an empty checklist item ends the list; in a filled one the new item is a task too.
function splitTask(state, dispatch) {
  const { $from } = state.selection;
  if ($from.depth < 2) return false;
  const item = $from.node($from.depth - 1);
  if (item.type !== nodes.list_item || item.attrs.checked == null) return false;
  return splitListItem(nodes.list_item, { checked: false })(state, dispatch);
}

function toggleHeading(level) {
  return (state, dispatch) => {
    const { $from } = state.selection;
    if ($from.parent.type === nodes.heading && $from.parent.attrs.level === level) return setBlockType(nodes.paragraph)(state, dispatch);
    return setBlockType(nodes.heading, { level })(state, dispatch);
  };
}

function toggleLink(state, dispatch) {
  if (markActive(state, marks.link)) {
    const { from, to } = state.selection;
    let a = from, b = to;
    if (state.selection.empty) {
      // extend over the link around the caret
      const $pos = state.selection.$from;
      const start = $pos.parent.childAfter($pos.parentOffset);
      if (!start.node) return false;
      a = $pos.start() + start.offset;
      b = a + start.node.nodeSize;
    }
    if (dispatch) dispatch(state.tr.removeMark(a, b, marks.link));
    return true;
  }
  if (state.selection.empty) return false;
  if (dispatch) {
    const guess = state.doc.textBetween(state.selection.from, state.selection.to).trim();
    const href = globalThis.prompt ? globalThis.prompt("Link address", /^\w+:\/\//.test(guess) ? guess : "https://") : null;
    if (!href) return true;
    dispatch(state.tr.addMark(state.selection.from, state.selection.to, marks.link.create({ href })));
  }
  return true;
}

const insertHardBreak = chainCommands(exitCode, (state, dispatch) => {
  if (dispatch) dispatch(state.tr.replaceSelectionWith(nodes.hard_break.create()).scrollIntoView());
  return true;
});

// ---------------------------------------------------------------- input rules

function markRule(regexp, markType) {
  return new InputRule(regexp, (state, match, start, end) => {
    const text = match[2];
    if (!text) return null;
    const tr = state.tr;
    const textStart = start + match[0].indexOf(match[1]);
    tr.delete(textStart, end);
    tr.insertText(text, textStart);
    tr.addMark(textStart, textStart + text.length, markType.create());
    tr.removeStoredMark(markType);
    return tr;
  });
}

function taskRule() {
  // "[ ] " or "[] " typed at the start of a bullet item turns the list into a checklist
  return new InputRule(/^\[( |x)?\]\s$/, (state, match, start, end) => {
    const $start = state.doc.resolve(start);
    const item = $start.node($start.depth - 1);
    if (!item || item.type !== nodes.list_item) {
      // not in a list yet: make one
      const tr = state.tr.delete(start, end);
      const range = tr.doc.resolve(start).blockRange();
      const wrapping = range && findWrapping(range, nodes.bullet_list);
      if (!wrapping) return null;
      tr.wrap(range, wrapping);
      tr.doc.nodesBetween(start, start + 4, (n, pos) => {
        if (n.type === nodes.list_item) tr.setNodeMarkup(pos, null, { checked: match[1] === "x" });
      });
      return tr;
    }
    const tr = state.tr.delete(start, end);
    tr.setNodeMarkup($start.before($start.depth - 1), null, { checked: match[1] === "x" });
    return tr;
  });
}

function buildInputRules() {
  return inputRules({
    rules: [
      ...smartQuotes,
      ellipsis,
      emDash,
      wrappingInputRule(/^\s*>\s$/, nodes.blockquote),
      wrappingInputRule(/^(\d+)\.\s$/, nodes.ordered_list, (m) => ({ order: +m[1] }), (m, node) => node.childCount + node.attrs.order === +m[1]),
      wrappingInputRule(/^\s*([-+*])\s$/, nodes.bullet_list),
      taskRule(),
      textblockTypeInputRule(/^```$/, nodes.code_block),
      textblockTypeInputRule(/^(#{1,3})\s$/, nodes.heading, (m) => ({ level: m[1].length })),
      markRule(/(?:^|[^*])(\*\*([^*]+)\*\*)$/, marks.strong),
      markRule(/(?:^|[^*])(\*([^*]+)\*)$/, marks.em),
      markRule(/(?:^|[^~])(~~([^~]+)~~)$/, marks.strike),
      markRule(/(?:^|[^`])(`([^`]+)`)$/, marks.code),
    ],
  });
}

// ---------------------------------------------------------------- keymap

function buildKeymap() {
  const k = {
    "Mod-z": undo,
    "Shift-Mod-z": redo,
    "Mod-y": redo,
    "Mod-b": toggleMark(marks.strong),
    "Mod-i": toggleMark(marks.em),
    "Mod-u": toggleMark(marks.underline),
    "Shift-Mod-x": toggleMark(marks.strike),
    "Mod-e": toggleMark(marks.code),
    "Mod-k": toggleLink,
    "Mod-Alt-0": setBlockType(nodes.paragraph),
    "Mod-Alt-1": toggleHeading(1),
    "Mod-Alt-2": toggleHeading(2),
    "Mod-Alt-3": toggleHeading(3),
    "Shift-Mod-7": toggleList(nodes.ordered_list, null),
    "Shift-Mod-8": toggleList(nodes.bullet_list, null),
    "Shift-Mod-9": toggleList(nodes.bullet_list, false),
    "Shift-Mod-.": wrapIn(nodes.blockquote),
    "Mod-\\": clearFormatting,
    "Shift-Enter": insertHardBreak,
    "Mod-Enter": insertHardBreak,
    Enter: chainCommands(splitTask, splitListItem(nodes.list_item)),
    Tab: sinkListItem(nodes.list_item),
    "Shift-Tab": liftListItem(nodes.list_item),
  };
  return keymap(k);
}

// ---------------------------------------------------------------- media URLs

let mediaBase = "";
const bust = new Map(); // src -> version, bumped when an image file is rewritten

export function resolveSrc(src) {
  if (!src) return "";
  if (/^[a-z][a-z0-9+.-]*:/i.test(src)) return src;
  const v = bust.get(src);
  return mediaBase + src.split("/").map(encodeURIComponent).join("/") + (v ? `?v=${v}` : "");
}

export function posterFor(src) {
  return src.replace(/\.(mp4|mov|m4v|webm)$/i, "-frames/0001.jpg");
}

// ---------------------------------------------------------------- node views

class ImageView {
  constructor(node, view, getPos) {
    this.node = node;
    this.view = view;
    this.getPos = getPos;
    this.dom = document.createElement("span");
    this.dom.className = "img-wrap";
    this.img = document.createElement("img");
    this.img.draggable = false;
    this.dom.appendChild(this.img);
    this.handle = document.createElement("span");
    this.handle.className = "resize";
    this.handle.title = "Drag to resize";
    this.dom.appendChild(this.handle);
    this.handle.addEventListener("mousedown", (e) => this.startResize(e));
    this.dom.addEventListener("dblclick", (e) => {
      e.preventDefault();
      post({ type: "annotate", src: this.node.attrs.src });
    });
    this.render();
  }
  render() {
    this.img.src = resolveSrc(this.node.attrs.src);
    this.img.alt = this.node.attrs.alt || "";
    this.img.title = (this.node.attrs.alt ? this.node.attrs.alt + " — " : "") + "double-click to mark up";
    this.img.style.width = this.node.attrs.width ? this.node.attrs.width + "px" : "";
  }
  startResize(e) {
    e.preventDefault();
    e.stopPropagation();
    const startX = e.clientX;
    const startW = this.img.getBoundingClientRect().width;
    const max = this.img.naturalWidth ? this.img.naturalWidth / (globalThis.devicePixelRatio || 1) : 4000;
    const move = (ev) => {
      const w = Math.max(60, Math.min(Math.max(max, 60), startW + ev.clientX - startX));
      this.img.style.width = w + "px";
    };
    const up = (ev) => {
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
      const w = Math.round(this.img.getBoundingClientRect().width);
      const pos = this.getPos();
      if (pos == null) return;
      const natural = Math.round(max);
      const width = Math.abs(w - natural) <= 2 ? null : w;
      this.view.dispatch(this.view.state.tr.setNodeMarkup(pos, null, { ...this.node.attrs, width }));
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  }
  update(node) {
    if (node.type !== this.node.type) return false;
    this.node = node;
    this.render();
    return true;
  }
  selectNode() {
    this.dom.classList.add("selected");
  }
  deselectNode() {
    this.dom.classList.remove("selected");
  }
  stopEvent(e) {
    return e.target === this.handle;
  }
  ignoreMutation() {
    return true;
  }
}

class VideoView {
  constructor(node) {
    this.node = node;
    this.dom = document.createElement("span");
    this.dom.className = "video-card";
    this.dom.contentEditable = "false";
    this.render();
  }
  render() {
    const { src, label } = this.node.attrs;
    this.dom.textContent = "";
    const poster = document.createElement("img");
    poster.className = "poster";
    poster.src = resolveSrc(posterFor(src));
    poster.onerror = () => poster.classList.add("missing");
    const play = document.createElement("button");
    play.className = "play";
    play.type = "button";
    play.title = "Play";
    play.textContent = "▶";
    const cap = document.createElement("span");
    cap.className = "caption";
    cap.textContent = label || src.split("/").pop();
    const open = () => {
      const video = document.createElement("video");
      video.src = resolveSrc(src);
      video.controls = true;
      video.autoplay = true;
      this.dom.replaceChildren(video, cap);
    };
    play.addEventListener("click", (e) => {
      e.preventDefault();
      open();
    });
    poster.addEventListener("click", open);
    this.dom.append(poster, play, cap);
  }
  update(node) {
    if (node.type !== this.node.type) return false;
    if (node.attrs.src !== this.node.attrs.src || node.attrs.label !== this.node.attrs.label) {
      this.node = node;
      this.render();
    }
    this.node = node;
    return true;
  }
  stopEvent(e) {
    return e.type !== "dragstart" && e.type !== "mousedown" ? true : e.target.tagName === "VIDEO" || e.target.tagName === "BUTTON";
  }
  ignoreMutation() {
    return true;
  }
  selectNode() {
    this.dom.classList.add("selected");
  }
  deselectNode() {
    this.dom.classList.remove("selected");
  }
}

class TaskItemView {
  constructor(node, view, getPos) {
    this.node = node;
    this.dom = document.createElement("li");
    if (node.attrs.checked != null) {
      this.dom.className = "task";
      this.box = document.createElement("input");
      this.box.type = "checkbox";
      this.box.contentEditable = "false";
      this.box.checked = node.attrs.checked;
      this.box.addEventListener("mousedown", (e) => e.preventDefault());
      this.box.addEventListener("click", (e) => {
        e.preventDefault();
        const pos = getPos();
        if (pos == null) return;
        view.dispatch(view.state.tr.setNodeMarkup(pos, null, { checked: !this.node.attrs.checked }));
      });
      this.dom.appendChild(this.box);
      this.dom.dataset.checked = String(node.attrs.checked);
    }
    this.contentDOM = document.createElement("div");
    this.contentDOM.className = "li-body";
    this.dom.appendChild(this.contentDOM);
  }
  update(node) {
    if (node.type !== this.node.type || (node.attrs.checked == null) !== (this.node.attrs.checked == null)) return false;
    this.node = node;
    if (this.box) {
      this.box.checked = node.attrs.checked;
      this.dom.dataset.checked = String(node.attrs.checked);
    }
    return true;
  }
  ignoreMutation(m) {
    return m.target === this.box || m.target === this.dom;
  }
}

// ---------------------------------------------------------------- paste and drop

let nextReq = 1;
const pending = new Map(); // reqId -> {pos|null, alt}

function fileToBase64(file) {
  return file.arrayBuffer().then((buf) => {
    let bin = "";
    const bytes = new Uint8Array(buf);
    const CH = 0x8000;
    for (let i = 0; i < bytes.length; i += CH) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
    return btoa(bin);
  });
}

function sendFiles(files, pos) {
  let any = false;
  for (const file of files) {
    if (!/^(image|video)\//.test(file.type)) continue;
    any = true;
    const reqId = nextReq++;
    pending.set(reqId, { pos, kind: file.type.startsWith("video") ? "video" : "image", name: file.name });
    fileToBase64(file).then((base64) => post({ type: "media", reqId, name: file.name || "", mime: file.type, base64 }));
  }
  return any;
}

// ---------------------------------------------------------------- the editor

const cache = new Map(); // item id -> {state, memo, saved}
let view = null;
let currentId = null;
let saveTimer = null;
let onToolbar = () => {};

function persistNow() {
  if (!view || currentId == null) return;
  clearTimeout(saveTimer);
  saveTimer = null;
  const entry = cache.get(currentId);
  const markdown = serializeMarkdown(view.state.doc, entry?.memo);
  if (entry && markdown === entry.saved) return;
  if (entry) entry.saved = markdown;
  post({ type: "changed", id: currentId, markdown });
}

function schedulePersist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(persistNow, 350);
}

function plugins() {
  return [
    buildInputRules(),
    buildKeymap(),
    keymap(baseKeymap),
    dropCursor({ color: "var(--accent)", width: 2 }),
    gapCursor(),
    history({ depth: 500 }),
    new Plugin({
      props: {
        handlePaste(view, event) {
          const files = Array.from(event.clipboardData?.files || []);
          if (files.length && sendFiles(files, null)) {
            event.preventDefault();
            return true;
          }
          return false;
        },
        handleDrop(view, event) {
          const files = Array.from(event.dataTransfer?.files || []);
          if (!files.length) return false;
          const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
          if (sendFiles(files, at ? at.pos : null)) {
            event.preventDefault();
            return true;
          }
          return false;
        },
        handleClickOn(view, pos, node, nodePos, event) {
          if (event.metaKey) {
            const link = marks.link.isInSet(node.isText ? node.marks : view.state.doc.resolve(pos).marks());
            if (link) {
              post({ type: "open", href: link.attrs.href });
              return true;
            }
          }
          return false;
        },
      },
    }),
  ];
}

function makeState(doc) {
  return EditorState.create({ doc, plugins: plugins() });
}

export function mount(place, opts = {}) {
  onToolbar = opts.onToolbar || onToolbar;
  view = new EditorView(place, {
    state: makeState(parseMarkdown("").doc),
    nodeViews: {
      image: (n, v, g) => new ImageView(n, v, g),
      video: (n) => new VideoView(n),
      list_item: (n, v, g) => new TaskItemView(n, v, g),
    },
    attributes: { spellcheck: "true", class: "doc" },
    dispatchTransaction(tr) {
      view.updateState(view.state.apply(tr));
      if (currentId != null) {
        const entry = cache.get(currentId);
        if (entry) entry.state = view.state;
      }
      if (tr.docChanged) schedulePersist();
      onToolbar(view.state);
    },
  });
  onToolbar(view.state);
  return view;
}

// ---------------------------------------------------------------- API used by the app

export const api = {
  /** Show item `id`. Keeps undo history when coming back to an item whose file did not change. */
  open({ id, markdown, base, focus = true }) {
    persistNow();
    if (base != null) mediaBase = base;
    const entry = cache.get(id);
    if (entry && entry.saved === markdown) {
      view.updateState(entry.state);
    } else {
      const { doc, memo } = parseMarkdown(markdown);
      const state = makeState(doc);
      cache.set(id, { state, memo, saved: serializeMarkdown(doc, memo) });
      view.updateState(state);
    }
    currentId = id;
    onToolbar(view.state);
    if (focus) api.focus();
    return true;
  },

  /** Forget an item (deleted), so a later item with the same id starts clean. */
  forget(id) {
    cache.delete(id);
    if (currentId === id) currentId = null;
  },

  /** Write out a pending change right now (before switching items or quitting). */
  flush() {
    persistNow();
    return true;
  },

  focus() {
    view.focus();
  },

  markdown() {
    return serializeMarkdown(view.state.doc, cache.get(currentId)?.memo);
  },

  /** Insert Markdown text (a template) at the caret. */
  insertMarkdown(text) {
    const { doc } = parseMarkdown(text);
    const state = view.state;
    const single = doc.childCount === 1 && doc.firstChild.type === nodes.paragraph;
    let tr = state.tr;
    if (single) {
      // A one-line template is text: keep the spaces around it, which Markdown would drop.
      const lead = /^[ \t]*/.exec(text)[0];
      const trail = /[ \t]*\n*$/.exec(text)[0].replace(/\n/g, "");
      const marksHere = state.storedMarks || state.selection.$from.marks();
      const content = [];
      if (lead) content.push(schema.text(lead, marksHere));
      doc.firstChild.content.forEach((n) => content.push(n));
      if (trail) content.push(schema.text(trail, marksHere));
      tr = tr.replaceSelection(new Slice(Fragment.from(content), 0, 0));
    } else {
      tr = tr.replaceSelection(new Slice(doc.content, 1, 1));
    }
    view.dispatch(tr.scrollIntoView());
    view.focus();
    return true;
  },

  /** Insert a picture or video as its own paragraph after the caret's block. */
  insertMedia({ kind, src, label = "", pos = null }) {
    const node = kind === "video" ? nodes.video.create({ src, label }) : nodes.image.create({ src, alt: label });
    const state = view.state;
    let tr = state.tr;
    if (pos != null) {
      tr = tr.insert(Math.min(pos, tr.doc.content.size), node);
    } else {
      const { $from } = state.selection;
      const para = $from.parent;
      if (para.type === nodes.paragraph && para.content.size === 0) {
        tr = tr.replaceSelectionWith(node, false);
        const after = tr.selection.$to.after();
        tr = tr.insert(after, nodes.paragraph.create());
        tr = tr.setSelection(TextSelection.create(tr.doc, after + 1));
      } else {
        const depth = $from.depth > 0 ? $from.depth : 1;
        const after = $from.after(depth);
        tr = tr.insert(after, [nodes.paragraph.create(null, node), nodes.paragraph.create()]);
        tr = tr.setSelection(TextSelection.create(tr.doc, after + node.nodeSize + 3));
      }
    }
    view.dispatch(tr.scrollIntoView());
    return true;
  },

  /** The app saved a pasted or dropped file; put it where the user dropped it. */
  mediaSaved(reqId, src) {
    const p = pending.get(reqId);
    pending.delete(reqId);
    if (!p) return false;
    return api.insertMedia({ kind: p.kind, src, label: "", pos: p.pos });
  },

  mediaFailed(reqId) {
    pending.delete(reqId);
    return true;
  },

  /** An image file was rewritten (re-annotated): make every view of it reload. */
  refreshMedia(src) {
    bust.set(src, (bust.get(src) || 0) + 1);
    const tr = view.state.tr;
    tr.setMeta("addToHistory", false);
    view.state.doc.descendants((n, pos) => {
      if (n.type === nodes.image && n.attrs.src === src) tr.setNodeMarkup(pos, null, { ...n.attrs });
    });
    view.dispatch(tr);
    view.dom.querySelectorAll("img").forEach((img) => {
      if (img.src.includes(encodeURIComponent(src.split("/").pop()))) img.src = resolveSrc(src);
    });
    return true;
  },

  undo: () => undo(view.state, view.dispatch),
  redo: () => redo(view.state, view.dispatch),

  // --- for the self-test and the screenshot mode ---
  typeText(text) {
    view.dispatch(view.state.tr.insertText(text));
    return true;
  },
  selectAll() {
    view.dispatch(view.state.tr.setSelection(new AllSelection(view.state.doc)));
  },
  text() {
    return view.state.doc.textContent;
  },
  run(name, arg) {
    const cmd = commands[name];
    if (!cmd) return false;
    return cmd(arg)(view.state, view.dispatch, view);
  },
};

// Commands the toolbar can call by name.
export const commands = {
  bold: () => toggleMark(marks.strong),
  italic: () => toggleMark(marks.em),
  underline: () => toggleMark(marks.underline),
  strike: () => toggleMark(marks.strike),
  code: () => toggleMark(marks.code),
  color: (v) => setValueMark(marks.color, v || null),
  size: (v) => setValueMark(marks.fontsize, v || null),
  heading: (level) => (level ? toggleHeading(+level) : setBlockType(nodes.paragraph)),
  bullets: () => toggleList(nodes.bullet_list, null),
  numbers: () => toggleList(nodes.ordered_list, null),
  checklist: () => toggleList(nodes.bullet_list, false),
  quote: () => wrapIn(nodes.blockquote),
  link: () => toggleLink,
  clear: () => clearFormatting,
};

export function toolbarState(state) {
  const { $from } = state.selection;
  let list = null;
  for (let d = $from.depth; d > 0; d--) {
    const n = $from.node(d);
    if (n.type === nodes.bullet_list) {
      list = n.firstChild?.attrs.checked != null ? "checklist" : "bullets";
      break;
    }
    if (n.type === nodes.ordered_list) {
      list = "numbers";
      break;
    }
  }
  return {
    bold: markActive(state, marks.strong),
    italic: markActive(state, marks.em),
    underline: markActive(state, marks.underline),
    strike: markActive(state, marks.strike),
    code: markActive(state, marks.code),
    link: markActive(state, marks.link),
    color: markValue(state, marks.color),
    size: markValue(state, marks.fontsize),
    heading: $from.parent.type === nodes.heading ? $from.parent.attrs.level : 0,
    list,
  };
}

export { COLORS, SIZES, view as _view };
