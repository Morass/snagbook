// Page entry: builds the formatting bar, mounts the editor and exposes window.snag.
import { mount, api, toolbarState, COLORS, SIZES } from "./editor.js";

const $ = (tag, props = {}, ...kids) => {
  const el = document.createElement(tag);
  Object.assign(el, props);
  for (const k of kids) el.append(k);
  return el;
};

const buttons = {};
let editorView = null;

function run(name, arg) {
  if (editorView && api.run(name, arg)) {
    editorView.focus();
  }
}

function button(name, label, title, cls = "") {
  const b = $("button", { type: "button", className: "tb " + cls, title, innerHTML: label });
  b.addEventListener("mousedown", (e) => e.preventDefault()); // keep the selection
  b.addEventListener("click", () => run(name));
  buttons[name] = b;
  return b;
}

function menu(label, title, items, onPick, cls = "") {
  const wrap = $("span", { className: "menu " + cls });
  const b = $("button", { type: "button", className: "tb", title, innerHTML: label });
  const pop = $("div", { className: "pop" });
  for (const it of items) {
    const i = $("button", { type: "button", className: "pop-item " + (it.cls || ""), title: it.title || "", innerHTML: it.html });
    i.addEventListener("mousedown", (e) => e.preventDefault());
    i.addEventListener("click", () => {
      wrap.classList.remove("open");
      onPick(it.value);
    });
    pop.append(i);
  }
  b.addEventListener("mousedown", (e) => e.preventDefault());
  b.addEventListener("click", () => {
    document.querySelectorAll(".menu.open").forEach((m) => m !== wrap && m.classList.remove("open"));
    wrap.classList.toggle("open");
  });
  wrap.append(b, pop);
  return { wrap, button: b };
}

document.addEventListener("mousedown", (e) => {
  if (!e.target.closest(".menu")) document.querySelectorAll(".menu.open").forEach((m) => m.classList.remove("open"));
});

function buildToolbar(bar) {
  const sep = () => $("span", { className: "sep" });
  const heading = menu(
    "Text",
    "Paragraph style",
    [
      { value: 0, html: "Body text" },
      { value: 1, html: "<b style='font-size:1.4em'>Heading 1</b>" },
      { value: 2, html: "<b style='font-size:1.2em'>Heading 2</b>" },
      { value: 3, html: "<b>Heading 3</b>" },
    ],
    (v) => run("heading", v),
    "heading"
  );
  buttons.heading = heading.button;
  const colors = menu(
    "<span class='a-color'>A</span>",
    "Text colour",
    [{ value: null, html: "<span class='swatch none'></span>", title: "Default colour" }, ...COLORS.map((c) => ({ value: c, html: `<span class='swatch' style='background:${c}'></span>`, title: c }))],
    (v) => run("color", v),
    "colors"
  );
  buttons.color = colors.button;
  const sizes = menu(
    "<span class='a-size'>aA</span>",
    "Text size",
    [
      { value: "0.85em", html: "<span style='font-size:0.85em'>Small</span>" },
      { value: null, html: "Normal" },
      { value: "1.25em", html: "<span style='font-size:1.25em'>Large</span>" },
      { value: "1.5em", html: "<span style='font-size:1.5em'>Larger</span>" },
      { value: "2em", html: "<span style='font-size:2em'>Huge</span>" },
    ],
    (v) => run("size", v),
    "sizes"
  );
  buttons.size = sizes.button;
  bar.append(
    heading.wrap,
    sep(),
    button("bold", "<b>B</b>", "Bold (⌘B)"),
    button("italic", "<i>I</i>", "Italic (⌘I)"),
    button("underline", "<u>U</u>", "Underline (⌘U)"),
    button("strike", "<s>S</s>", "Strikethrough (⇧⌘X)"),
    colors.wrap,
    sizes.wrap,
    sep(),
    button("bullets", "•&thinsp;≡", "Bulleted list (⇧⌘8)"),
    button("numbers", "1.&thinsp;≡", "Numbered list (⇧⌘7)"),
    button("checklist", "☑", "Checklist (⇧⌘9)"),
    button("quote", "❝", "Quote (⇧⌘.)"),
    sep(),
    button("link", "🔗", "Link (⌘K)"),
    button("code", "&lt;/&gt;", "Code (⌘E)"),
    button("clear", "⌫<small>A</small>", "Clear formatting (⌘\\)")
  );
}

function updateToolbar(state) {
  const s = toolbarState(state);
  for (const k of ["bold", "italic", "underline", "strike", "code", "link"]) buttons[k]?.classList.toggle("on", !!s[k]);
  for (const k of ["bullets", "numbers", "checklist"]) buttons[k]?.classList.toggle("on", s.list === k);
  if (buttons.heading) buttons.heading.textContent = s.heading ? `Heading ${s.heading}` : "Text";
  if (buttons.color) {
    buttons.color.classList.toggle("on", !!s.color);
    buttons.color.querySelector(".a-color").style.borderBottomColor = s.color || "transparent";
  }
  buttons.size?.classList.toggle("on", !!s.size);
}

function start() {
  const bar = document.getElementById("toolbar");
  buildToolbar(bar);
  editorView = mount(document.getElementById("editor"), { onToolbar: updateToolbar });
  window.snag = api;
  const post = globalThis.webkit?.messageHandlers?.snag;
  if (post) post.postMessage({ type: "ready" });
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
else start();
