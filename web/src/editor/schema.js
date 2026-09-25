// The document model. Everything here has to survive a trip to Markdown and back:
// a node or mark with no Markdown spelling does not belong in this file.
import { Schema } from "prosemirror-model";

export const VIDEO_RE = /\.(mp4|mov|m4v|webm)(\?.*)?$/i;

// Colours and sizes the toolbar offers. Anything else found in a file is kept as is.
export const COLORS = ["#e5484d", "#f5a623", "#30a46c", "#0090ff", "#8e4ec6", "#6b7280"];
export const SIZES = ["0.85em", "1.25em", "1.5em", "2em"];

export const schema = new Schema({
  nodes: {
    doc: { content: "block+" },

    paragraph: {
      content: "inline*",
      group: "block",
      parseDOM: [{ tag: "p" }],
      toDOM: () => ["p", 0],
    },

    heading: {
      attrs: { level: { default: 1 } },
      content: "inline*",
      group: "block",
      defining: true,
      parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({ tag: `h${level}`, attrs: { level } })),
      toDOM: (node) => [`h${node.attrs.level}`, 0],
    },

    blockquote: {
      content: "block+",
      group: "block",
      defining: true,
      parseDOM: [{ tag: "blockquote" }],
      toDOM: () => ["blockquote", 0],
    },

    code_block: {
      content: "text*",
      group: "block",
      code: true,
      defining: true,
      marks: "",
      attrs: { params: { default: "" } },
      parseDOM: [{ tag: "pre", preserveWhitespace: "full" }],
      toDOM: () => ["pre", ["code", 0]],
    },

    horizontal_rule: {
      group: "block",
      parseDOM: [{ tag: "hr" }],
      toDOM: () => ["hr"],
    },

    bullet_list: {
      content: "list_item+",
      group: "block",
      attrs: { tight: { default: true }, bullet: { default: "-" } },
      parseDOM: [{ tag: "ul" }],
      toDOM: (node) => ["ul", { class: node.content.firstChild?.attrs.checked != null ? "checklist" : null }, 0],
    },

    ordered_list: {
      content: "list_item+",
      group: "block",
      attrs: { order: { default: 1 }, tight: { default: true } },
      parseDOM: [{ tag: "ol", getAttrs: (dom) => ({ order: +(dom.getAttribute("start") || 1) }) }],
      toDOM: (node) => ["ol", node.attrs.order === 1 ? {} : { start: node.attrs.order }, 0],
    },

    // checked: null for a plain item, true/false for a checklist item ("- [ ]" / "- [x]").
    list_item: {
      content: "paragraph block*",
      defining: true,
      attrs: { checked: { default: null } },
      parseDOM: [{ tag: "li", getAttrs: (dom) => ({ checked: dom.hasAttribute("data-checked") ? dom.getAttribute("data-checked") === "true" : null }) }],
      toDOM: (node) =>
        node.attrs.checked == null ? ["li", 0] : ["li", { "data-checked": String(node.attrs.checked), class: "task" }, 0],
    },

    // A block of HTML we do not understand. Shown as source, written back byte for byte.
    raw_block: {
      group: "block",
      atom: true,
      attrs: { html: { default: "" } },
      toDOM: (node) => ["pre", { class: "raw" }, node.attrs.html],
    },

    text: { group: "inline" },

    // width: null means natural size ("![alt](src)"); a number is written as <img width>.
    image: {
      inline: true,
      group: "inline",
      draggable: true,
      attrs: { src: {}, alt: { default: "" }, title: { default: null }, width: { default: null } },
      parseDOM: [
        {
          tag: "img[src]",
          getAttrs: (dom) => ({
            src: dom.getAttribute("data-src") || dom.getAttribute("src"),
            alt: dom.getAttribute("alt") || "",
            title: dom.getAttribute("title"),
            width: dom.getAttribute("width") ? +dom.getAttribute("width") : null,
          }),
        },
      ],
      toDOM: (node) => ["img", { src: node.attrs.src, alt: node.attrs.alt, width: node.attrs.width }],
    },

    // A link to a video file, drawn as a playable card. Markdown: [label](clip.mp4)
    video: {
      inline: true,
      group: "inline",
      atom: true,
      draggable: true,
      attrs: { src: {}, label: { default: "" } },
      toDOM: (node) => ["a", { href: node.attrs.src, class: "video" }, node.attrs.label || node.attrs.src],
    },

    // Inline HTML we do not understand, kept verbatim.
    raw_inline: {
      inline: true,
      group: "inline",
      atom: true,
      attrs: { html: { default: "" } },
      toDOM: (node) => ["code", { class: "raw" }, node.attrs.html],
    },

    hard_break: {
      inline: true,
      group: "inline",
      selectable: false,
      parseDOM: [{ tag: "br" }],
      toDOM: () => ["br"],
    },
  },

  marks: {
    link: {
      attrs: { href: {}, title: { default: null } },
      inclusive: false,
      parseDOM: [{ tag: "a[href]", getAttrs: (dom) => ({ href: dom.getAttribute("href"), title: dom.getAttribute("title") }) }],
      toDOM: (mark) => ["a", { href: mark.attrs.href, title: mark.attrs.title }, 0],
    },
    em: {
      parseDOM: [{ tag: "i" }, { tag: "em" }, { style: "font-style=italic" }],
      toDOM: () => ["em", 0],
    },
    strong: {
      parseDOM: [
        { tag: "strong" },
        { tag: "b", getAttrs: (dom) => dom.style.fontWeight !== "normal" && null },
        { style: "font-weight", getAttrs: (v) => /^(bold(er)?|[5-9]\d{2,})$/.test(v) && null },
      ],
      toDOM: () => ["strong", 0],
    },
    underline: {
      parseDOM: [{ tag: "u" }, { style: "text-decoration=underline" }],
      toDOM: () => ["u", 0],
    },
    strike: {
      parseDOM: [{ tag: "s" }, { tag: "del" }, { tag: "strike" }, { style: "text-decoration=line-through" }],
      toDOM: () => ["s", 0],
    },
    color: {
      attrs: { value: {} },
      parseDOM: [{ tag: "span[style]", getAttrs: (dom) => (dom.style.color ? { value: normColor(dom.style.color) } : false) }],
      toDOM: (mark) => ["span", { style: `color:${mark.attrs.value}` }, 0],
    },
    fontsize: {
      attrs: { value: {} },
      parseDOM: [{ tag: "span[style]", getAttrs: (dom) => (/em$/.test(dom.style.fontSize) ? { value: dom.style.fontSize } : false) }],
      toDOM: (mark) => ["span", { style: `font-size:${mark.attrs.value}` }, 0],
    },
    code: {
      code: true,
      parseDOM: [{ tag: "code" }],
      toDOM: () => ["code", 0],
    },
  },
});

// "rgb(229, 72, 77)" -> "#e5484d"; a hex value passes through lower-cased.
export function normColor(v) {
  const m = /^rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(v);
  if (!m) return v.toLowerCase();
  return "#" + [m[1], m[2], m[3]].map((n) => (+n).toString(16).padStart(2, "0")).join("");
}
