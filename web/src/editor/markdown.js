// Markdown in, Markdown out.
//
// Two promises this file keeps:
//  1. Anything the editor can show has a plain-text spelling another program (or person)
//     can read without Snagbook: CommonMark + GFM, plus a handful of HTML tags for what
//     Markdown cannot say (underline, colour, size, an image's display width).
//  2. Opening a file and saving it again does not rewrite what you did not touch. Each
//     top-level block remembers the exact source it came from; an unedited block is
//     written back byte for byte, and only edited blocks go through the serializer.
import MarkdownIt from "markdown-it";
import { MarkdownParser, MarkdownSerializer, defaultMarkdownSerializer } from "prosemirror-markdown";
import { schema, VIDEO_RE } from "./schema.js";

// ---------------------------------------------------------------- parsing

const md = MarkdownIt("commonmark", { html: true }).enable("strikethrough");

const OPEN_TAG = /^<(u|s|del|span)(\s+style\s*=\s*"([^"]*)")?\s*>$/i;
const CLOSE_TAG = /^<\/(u|s|del|span)\s*>$/i;
const BR_TAG = /^<br\s*\/?>$/i;
const IMG_TAG = /^<img\s[^>]*>$/i;

function attrOf(tag, name) {
  const m = new RegExp(`\\s${name}\\s*=\\s*"([^"]*)"`, "i").exec(tag);
  return m ? m[1] : null;
}

function styleKind(style) {
  if (!style) return null;
  const parts = style.split(";").map((s) => s.trim()).filter(Boolean);
  if (parts.length !== 1) return null;
  const m = /^(color|font-size)\s*:\s*(.+)$/i.exec(parts[0]);
  if (!m) return null;
  return m[1].toLowerCase() === "color" ? { type: "color", value: m[2].trim().toLowerCase() } : { type: "fontsize", value: m[2].trim() };
}

function imageToken(state, tag) {
  const t = new state.Token("image", "img", 0);
  t.attrs = [["src", attrOf(tag, "src") || ""]];
  const width = attrOf(tag, "width");
  if (width && /^\d+$/.test(width)) t.attrs.push(["width", width]);
  const title = attrOf(tag, "title");
  if (title) t.attrs.push(["title", title]);
  t.attrs.push(["data-alt", attrOf(tag, "alt") || ""]);
  t.children = [];
  return t;
}

// Inline HTML we understand becomes marks; the rest stays verbatim.
function pairInlineHtml(state) {
  for (const block of state.tokens) {
    if (block.type !== "inline" || !block.children) continue;
    const out = [];
    const stack = []; // {index in out, tag}
    for (const tok of block.children) {
      if (tok.type !== "html_inline") {
        out.push(tok);
        continue;
      }
      const html = tok.content;
      let m;
      if (BR_TAG.test(html)) {
        out.push(Object.assign(new state.Token("hardbreak", "br", 0), {}));
      } else if (IMG_TAG.test(html) && attrOf(html, "src")) {
        out.push(imageToken(state, html));
      } else if ((m = OPEN_TAG.exec(html))) {
        const tag = m[1].toLowerCase();
        let kind = null;
        if (tag === "u" && !m[2]) kind = { type: "underline" };
        else if ((tag === "s" || tag === "del") && !m[2]) kind = { type: "s" };
        else if (tag === "span") kind = styleKind(m[3]);
        if (!kind) {
          out.push(tok);
          continue;
        }
        stack.push({ at: out.length, tag, kind, raw: tok });
        const open = new state.Token(`${kind.type}_open`, tag, 1);
        if (kind.value) open.attrs = [["value", kind.value]];
        out.push(open);
      } else if ((m = CLOSE_TAG.exec(html))) {
        const tag = m[1].toLowerCase();
        const top = stack[stack.length - 1];
        if (top && top.tag === tag) {
          stack.pop();
          out.push(new state.Token(`${top.kind.type}_close`, tag, -1));
        } else {
          out.push(tok);
        }
      } else {
        out.push(tok);
      }
    }
    // An opening tag that never closed goes back to being literal HTML.
    for (const open of stack) out[open.at] = open.raw;
    block.children = out;
  }
}

// "- [ ] text" / "- [x] text" become checklist items.
function taskLists(state) {
  const toks = state.tokens;
  for (let i = 0; i < toks.length - 2; i++) {
    if (toks[i].type !== "list_item_open" || toks[i + 1].type !== "paragraph_open" || toks[i + 2].type !== "inline") continue;
    const inline = toks[i + 2];
    const m = /^\[([ xX])\](\s|$)/.exec(inline.content);
    if (!m) continue;
    toks[i].attrSet("checked", m[1] === " " ? "false" : "true");
    inline.content = inline.content.slice(m[0].length);
    const first = inline.children && inline.children[0];
    if (first && first.type === "text") first.content = first.content.replace(/^\[([ xX])\](\s|$)/, "");
  }
}

// [label](clip.mp4) becomes a video card.
function videoLinks(state) {
  for (const block of state.tokens) {
    if (block.type !== "inline" || !block.children) continue;
    const kids = block.children;
    const out = [];
    for (let i = 0; i < kids.length; i++) {
      const t = kids[i];
      if (t.type === "link_open" && VIDEO_RE.test(t.attrGet("href") || "")) {
        let j = i + 1;
        let label = "";
        while (j < kids.length && kids[j].type === "text") label += kids[j++].content;
        if (j < kids.length && kids[j].type === "link_close") {
          const v = new state.Token("video", "a", 0);
          v.attrs = [["src", t.attrGet("href")], ["label", label]];
          out.push(v);
          i = j;
          continue;
        }
      }
      out.push(t);
    }
    block.children = out;
  }
}

// A lone <img …> line is an HTML block to CommonMark; to us it is a paragraph with a picture.
function imageBlocks(state) {
  const out = [];
  for (const t of state.tokens) {
    const html = t.type === "html_block" ? t.content.trim() : "";
    if (html && IMG_TAG.test(html) && attrOf(html, "src") && t.level === 0) {
      const open = new state.Token("paragraph_open", "p", 1);
      open.map = t.map;
      const inline = new state.Token("inline", "", 0);
      inline.content = html;
      inline.children = [imageToken(state, html)];
      out.push(open, inline, new state.Token("paragraph_close", "p", -1));
    } else {
      out.push(t);
    }
  }
  state.tokens = out;
}

md.core.ruler.push("snag_images", imageBlocks);
md.core.ruler.push("snag_html", pairInlineHtml);
md.core.ruler.push("snag_tasks", taskLists);
md.core.ruler.push("snag_video", videoLinks);

const listIsTight = (tokens, i) => {
  while (++i < tokens.length) if (tokens[i].type !== "list_item_open") return tokens[i].hidden;
  return false;
};

const parser = new MarkdownParser(schema, md, {
  blockquote: { block: "blockquote" },
  paragraph: { block: "paragraph" },
  list_item: {
    block: "list_item",
    getAttrs: (tok) => {
      const c = tok.attrGet("checked");
      return { checked: c == null ? null : c === "true" };
    },
  },
  bullet_list: { block: "bullet_list", getAttrs: (tok, tokens, i) => ({ tight: listIsTight(tokens, i), bullet: tok.markup || "-" }) },
  ordered_list: {
    block: "ordered_list",
    getAttrs: (tok, tokens, i) => ({ order: +tok.attrGet("start") || 1, tight: listIsTight(tokens, i) }),
  },
  heading: { block: "heading", getAttrs: (tok) => ({ level: +tok.tag.slice(1) }) },
  code_block: { block: "code_block", noCloseToken: true },
  fence: { block: "code_block", getAttrs: (tok) => ({ params: tok.info || "" }), noCloseToken: true },
  hr: { node: "horizontal_rule" },
  html_block: { node: "raw_block", getAttrs: (tok) => ({ html: tok.content.replace(/\n+$/, "") }), noCloseToken: true },
  image: {
    node: "image",
    getAttrs: (tok) => ({
      src: tok.attrGet("src"),
      title: tok.attrGet("title") || null,
      alt: tok.attrGet("data-alt") ?? ((tok.children && tok.children.map((c) => c.content).join("")) || ""),
      width: tok.attrGet("width") ? +tok.attrGet("width") : null,
    }),
  },
  video: { node: "video", getAttrs: (tok) => ({ src: tok.attrGet("src"), label: tok.attrGet("label") || "" }), noCloseToken: true },
  html_inline: { node: "raw_inline", getAttrs: (tok) => ({ html: tok.content }), noCloseToken: true },
  hardbreak: { node: "hard_break" },
  em: { mark: "em" },
  strong: { mark: "strong" },
  s: { mark: "strike" },
  underline: { mark: "underline" },
  color: { mark: "color", getAttrs: (tok) => ({ value: tok.attrGet("value") }) },
  fontsize: { mark: "fontsize", getAttrs: (tok) => ({ value: tok.attrGet("value") }) },
  link: { mark: "link", getAttrs: (tok) => ({ href: tok.attrGet("href"), title: tok.attrGet("title") || null }) },
  code_inline: { mark: "code", noCloseToken: true },
});

// ---------------------------------------------------------------- serializing

const esc = (s) => String(s).replace(/"/g, "&quot;");
const escLabel = (s) => String(s).replace(/([\\[\]])/g, "\\$1");
const escUrl = (s) => String(s).replace(/[()\s]/g, (c) => encodeURIComponent(c));

const serializer = new MarkdownSerializer(
  {
    ...defaultMarkdownSerializer.nodes,
    bullet_list(state, node) {
      state.renderList(node, "  ", () => (node.attrs.bullet || "-") + " ");
    },
    list_item(state, node) {
      if (node.attrs.checked != null) state.write(node.attrs.checked ? "[x] " : "[ ] ");
      state.renderContent(node);
    },
    code_block(state, node) {
      const backticks = node.textContent.match(/`{3,}/gm);
      const fence = backticks ? backticks.sort().slice(-1)[0] + "`" : "```";
      state.write(fence + (node.attrs.params || "") + "\n");
      state.text(node.textContent, false);
      state.write("\n");
      state.write(fence);
      state.closeBlock(node);
    },
    image(state, node) {
      const { src, alt, title, width } = node.attrs;
      if (width) {
        state.write(`<img src="${esc(src)}" width="${Math.round(width)}" alt="${esc(alt || "")}"${title ? ` title="${esc(title)}"` : ""}>`);
      } else {
        state.write(`![${state.esc(alt || "")}](${escUrl(src)}${title ? ` "${title.replace(/"/g, '\\"')}"` : ""})`);
      }
    },
    video(state, node) {
      state.write(`[${escLabel(node.attrs.label || "video")}](${escUrl(node.attrs.src)})`);
    },
    raw_block(state, node) {
      state.write(node.attrs.html);
      state.closeBlock(node);
    },
    raw_inline(state, node) {
      state.write(node.attrs.html);
    },
    hard_break(state, node, parent, index) {
      for (let i = index + 1; i < parent.childCount; i++)
        if (parent.child(i).type != node.type) {
          state.write("<br>");
          return;
        }
    },
  },
  {
    ...defaultMarkdownSerializer.marks,
    em: { open: "*", close: "*", mixable: true, expelEnclosingWhitespace: true },
    strong: { open: "**", close: "**", mixable: true, expelEnclosingWhitespace: true },
    strike: { open: "~~", close: "~~", mixable: true, expelEnclosingWhitespace: true },
    underline: { open: "<u>", close: "</u>", mixable: true, expelEnclosingWhitespace: true },
    color: { open: (_s, mark) => `<span style="color:${mark.attrs.value}">`, close: "</span>", expelEnclosingWhitespace: true },
    fontsize: { open: (_s, mark) => `<span style="font-size:${mark.attrs.value}">`, close: "</span>", expelEnclosingWhitespace: true },
  }
);

// ---------------------------------------------------------------- the round trip

/**
 * Parse Markdown into a document plus a memo of where each top-level block came from.
 * @returns {{doc, memo}}
 */
export function parseMarkdown(src) {
  src = String(src ?? "").replace(/\r\n?/g, "\n");
  const doc = parser.parse(src);
  return { doc, memo: buildMemo(src, doc) };
}

function buildMemo(src, doc) {
  const env = {};
  const tokens = md.parse(src, env);
  const ranges = tokens.filter((t) => t.level === 0 && t.nesting >= 0 && t.map).map((t) => t.map);
  if (!ranges.length || ranges.length !== doc.childCount) return null;
  const lines = src.split("\n");
  const nonBlankEnd = ([s, e]) => {
    while (e > s && lines[e - 1].trim() === "") e--;
    return e;
  };
  const children = [];
  doc.forEach((c) => children.push(c));
  const ends = ranges.map(nonBlankEnd);
  const chunks = ranges.map(([s], i) => lines.slice(s, ends[i]).join("\n"));
  const seps = ranges.map(([s], i) => {
    if (i === 0) return "";
    const prevEnd = ends[i - 1];
    return "\n" + lines.slice(prevEnd, s).join("\n") + (s > prevEnd ? "\n" : "");
  });
  const s0 = ranges[0][0];
  const leading = s0 > 0 ? lines.slice(0, s0).join("\n") + "\n" : "";
  const lastEnd = ends[ends.length - 1];
  const trailing = lastEnd < lines.length ? "\n" + lines.slice(lastEnd).join("\n") : "";
  return { children, chunks, seps, leading, trailing };
}

function serializeBlock(node) {
  return serializer.serialize(schema.topNodeType.create(null, [node]), { tightLists: true }).replace(/\n+$/, "");
}

/**
 * Serialize a document. With the memo from parseMarkdown, blocks that are the very same
 * node objects as when the file was read are written back exactly as they were.
 */
export function serializeMarkdown(doc, memo) {
  const children = [];
  doc.forEach((c) => children.push(c));
  const index = new Map();
  if (memo) memo.children.forEach((c, i) => index.set(c, i));

  let out = "";
  let prev = -2; // memo index of the previously written child, -2 = none / edited
  children.forEach((child, n) => {
    const j = index.has(child) ? index.get(child) : -1;
    const text = j >= 0 ? memo.chunks[j] : serializeBlock(child);
    if (n === 0) out += j === 0 ? memo.leading : "";
    else out += j >= 0 && prev === j - 1 ? memo.seps[j] : "\n\n";
    out += text;
    prev = j >= 0 ? j : -2;
  });
  const last = children.length - 1;
  const lastJ = index.has(children[last]) ? index.get(children[last]) : -1;
  if (memo && lastJ === memo.children.length - 1) out += memo.trailing;
  else out += "\n";
  return out;
}

export { schema };
