import { test } from "node:test";
import assert from "node:assert/strict";
import { parseMarkdown, serializeMarkdown, schema } from "../src/editor/markdown.js";

const roundTrip = (src) => {
  const { doc, memo } = parseMarkdown(src);
  return serializeMarkdown(doc, memo);
};
// Serialize with no memory of the source: what an edited document produces.
const fresh = (src) => serializeMarkdown(parseMarkdown(src).doc, null);

const CORPUS = [
  "# Title\n\nSome *text* and **bold** and ~~gone~~.\n",
  "Para one\nstill para one\n\n\n\nPara two after three blank lines\n",
  "* star bullets\n* kept as stars\n\n1) odd ordered\n2) list\n",
  "- [ ] open task\n- [x] done task\n",
  "Colour: <span style=\"color:#e5484d\">red</span> and <u>under</u> and <span style=\"font-size:1.5em\">big</span>.\n",
  "Unknown <kbd>Ctrl</kbd> tag and <span class=\"x\">classy</span> span.\n",
  "<details>\n<summary>raw</summary>\nblock\n</details>\n",
  "![shot](media/shot-001.png)\n\n<img src=\"media/shot-002.png\" width=\"480\" alt=\"wide\">\n",
  "[Video 0:12](media/clip-001.mp4)\n",
  "```js\nconst x = 1;\n```\n",
  "> quote\n> more\n\n---\n\ntrailing text without newline",
  "\n\nleading blank lines\n",
  "Text with a hard break  \nnext line\n",
  "   indented weirdly\n\n    code block\n",
];

test("unedited documents come back byte for byte", () => {
  for (const src of CORPUS) assert.equal(roundTrip(src), src, JSON.stringify(src));
});

test("fresh serialization is stable (idempotent after one pass)", () => {
  for (const src of CORPUS) {
    const once = fresh(src);
    assert.equal(fresh(once), once, JSON.stringify(src));
  }
});

test("editing one block leaves the others untouched", () => {
  const src = "* a\n* b\n\n\nPara   with  odd   spacing\n\n# Head\n";
  const { doc, memo } = parseMarkdown(src);
  // replace the heading's text
  const heading = doc.child(2);
  const edited = doc.replace(
    doc.content.size - heading.nodeSize, doc.content.size,
    new (doc.slice(0).constructor)(schema.nodes.heading.create({ level: 2 }, schema.text("New")).type.schema.topNodeType.create(null, [schema.nodes.heading.create({ level: 2 }, schema.text("New"))]).content, 0, 0));
  const out = serializeMarkdown(edited, memo);
  assert.equal(out, "* a\n* b\n\n\nPara   with  odd   spacing\n\n## New\n");
});

test("marks parse into the schema", () => {
  const { doc } = parseMarkdown('<span style="color:#E5484D">red</span> <u>u</u> <span style="font-size:2em">big</span> ~~s~~');
  const marks = [];
  doc.descendants((n) => { if (n.isText) marks.push(n.marks.map((m) => m.type.name + (m.attrs.value ? "=" + m.attrs.value : "")).join(",")); });
  assert.deepEqual(marks.filter(Boolean), ["color=#e5484d", "underline", "fontsize=2em", "strike"]);
});

test("images, widths, videos and tasks", () => {
  const { doc } = parseMarkdown('<img src="media/a.png" width="300" alt="A">\n\n![b](media/b.png)\n\n[clip](media/c.mov)\n\n- [x] done\n');
  const found = [];
  doc.descendants((n) => {
    if (n.type.name === "image") found.push(`img ${n.attrs.src} ${n.attrs.width} ${n.attrs.alt}`);
    if (n.type.name === "video") found.push(`video ${n.attrs.src} ${n.attrs.label}`);
    if (n.type.name === "list_item") found.push(`task ${n.attrs.checked}`);
  });
  assert.deepEqual(found, ["img media/a.png 300 A", "img media/b.png null b", "video media/c.mov clip", "task true"]);
});

test("unclosed or unknown HTML is kept literally", () => {
  for (const src of ["a <span style=\"color:red\">never closed\n", "x </u> y\n", "<span style=\"color:red;font-weight:bold\">two props</span>\n"]) {
    assert.equal(fresh(src), src);
  }
});

test("nested colour inside size, and bold across", () => {
  const src = '<span style="font-size:1.5em"><span style="color:#30a46c">both</span></span>\n';
  const once = fresh(src);
  assert.equal(fresh(once), once);
  const { doc } = parseMarkdown(src);
  let names = "";
  doc.descendants((n) => { if (n.isText) names = n.marks.map((m) => m.type.name).sort().join(","); });
  assert.equal(names, "color,fontsize");
});

test("empty input gives an empty paragraph and serializes to a newline", () => {
  const { doc, memo } = parseMarkdown("");
  assert.equal(doc.childCount, 1);
  assert.equal(serializeMarkdown(doc, memo), "\n");
});
