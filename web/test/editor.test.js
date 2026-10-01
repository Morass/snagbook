import { test, before } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

let api, commands, toolbarState, view;
const posted = [];

before(async () => {
  const dom = new JSDOM("<!doctype html><div id=e></div>", { pretendToBeVisual: true });
  for (const k of ["window", "document", "Node", "HTMLElement", "MutationObserver", "getComputedStyle", "requestAnimationFrame", "DOMParser"])
    globalThis[k] = k === "window" ? dom.window : dom.window[k];
  Object.defineProperty(globalThis, "navigator", { value: dom.window.navigator, configurable: true });
  globalThis.__snagPosted = posted;
  dom.window.Element.prototype.getClientRects = () => [];
  dom.window.Range.prototype.getClientRects = () => [];
  dom.window.Range.prototype.getBoundingClientRect = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 });
  const ed = await import("../src/editor.js");
  ({ api, commands, toolbarState } = ed);
  view = ed.mount(document.getElementById("e"));
});

const type = (text) => {
  for (const ch of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, ch));
    if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to));
  }
};
const md = () => api.markdown();
const changes = () => posted.filter((m) => m.type === "changed");

test("open, type, flush posts the new Markdown once", () => {
  api.open({ id: "01", markdown: "Hello\n", base: "snagbook://item/01/", focus: false });
  view.dispatch(view.state.tr.setSelection(view.state.selection.constructor.atEnd(view.state.doc)));
  type(" world");
  api.flush();
  api.flush();
  const c = changes();
  assert.equal(c.length, 1);
  assert.deepEqual(c[0], { type: "changed", id: "01", markdown: "Hello world\n" });
});

test("input rules: heading, bullets, checklist, bold", () => {
  api.open({ id: "02", markdown: "", focus: false });
  type("## Title");
  view.dispatch(view.state.tr.split(view.state.selection.from));
  view.dispatch(view.state.tr.setBlockType(view.state.selection.from, view.state.selection.from, view.state.schema.nodes.paragraph));
  type("- [ ] task one");
  assert.match(md(), /^## Title\n\n- \[ \] task one\n$/);
});

test("mark input rule turns **x** into bold", () => {
  api.open({ id: "03", markdown: "", focus: false });
  type("say **loud** now");
  assert.equal(md(), "say **loud** now\n");
  let bold = "";
  view.state.doc.descendants((n) => { if (n.isText && n.marks.some((m) => m.type.name === "strong")) bold += n.text; });
  assert.equal(bold, "loud");
});

test("templates insert inline into the current paragraph, or as blocks", () => {
  api.open({ id: "04", markdown: "Start\n", focus: false });
  view.dispatch(view.state.tr.setSelection(view.state.selection.constructor.atEnd(view.state.doc)));
  api.insertMarkdown(" **Expected:** ");
  assert.equal(md(), "Start **Expected:** \n");
  api.insertMarkdown("Steps:\n\n1. one\n2. two\n");
  assert.match(md(), /1\. one\n2\. two/);
});

test("insertMedia puts a picture in its own paragraph and keeps typing below it", () => {
  api.open({ id: "05", markdown: "Before\n", focus: false });
  view.dispatch(view.state.tr.setSelection(view.state.selection.constructor.atEnd(view.state.doc)));
  api.insertMedia({ kind: "image", src: "media/shot-001.png" });
  assert.equal(api.hasMedia("media/shot-001.png"), true);
  assert.equal(api.hasMedia("media/missing.png"), false);
  type("After");
  assert.equal(md(), "Before\n\n![](media/shot-001.png)\n\nAfter\n");
  api.insertMedia({ kind: "video", src: "media/clip-001.mp4", label: "Video 0:05" });
  assert.match(md(), /\[Video 0:05\]\(media\/clip-001\.mp4\)/);
});

test("colour and size marks write inline HTML", () => {
  api.open({ id: "06", markdown: "paint me\n", focus: false });
  api.selectAll();
  commands.color("#e5484d")(view.state, view.dispatch);
  commands.size("1.5em")(view.state, view.dispatch);
  const out = md();
  assert.match(out, /<span style="color:#e5484d">/);
  assert.match(out, /<span style="font-size:1.5em">/);
  assert.equal(toolbarState(view.state).color, "#e5484d");
  commands.color(null)(view.state, view.dispatch);
  assert.doesNotMatch(md(), /color:/);
});

test("list toggles switch kinds in place", () => {
  api.open({ id: "07", markdown: "- a\n- b\n", focus: false });
  view.dispatch(view.state.tr.setSelection(view.state.selection.constructor.atEnd(view.state.doc)));
  commands.checklist()(view.state, view.dispatch);
  assert.equal(md(), "- [ ] a\n- [ ] b\n");
  commands.numbers()(view.state, view.dispatch);
  assert.equal(md(), "1. a\n2. b\n");
});

test("coming back to an item keeps its undo history", () => {
  api.open({ id: "08", markdown: "x\n", focus: false });
  view.dispatch(view.state.tr.setSelection(view.state.selection.constructor.atEnd(view.state.doc)));
  type("yz");
  api.flush();
  const saved = changes().at(-1).markdown;
  api.open({ id: "09", markdown: "other\n", focus: false });
  api.open({ id: "08", markdown: saved, focus: false });
  api.undo();
  assert.equal(md(), "x\n");
});

test("an item changed on disk reloads instead of reusing the cached state", () => {
  api.open({ id: "10", markdown: "old\n", focus: false });
  api.open({ id: "11", markdown: "", focus: false });
  api.open({ id: "10", markdown: "new from an agent\n", focus: false });
  assert.equal(md(), "new from an agent\n");
});

test("pasted file bytes go to the app and come back as a picture", async () => {
  api.open({ id: "12", markdown: "", focus: false });
  const before = posted.length;
  const file = new window.File([new Uint8Array([137, 80, 78, 71])], "image.png", { type: "image/png" });
  const handled = view.someProp("handlePaste", (f) => f(view, { clipboardData: { files: [file] }, preventDefault() {} }));
  assert.equal(handled, true);
  await new Promise((r) => setTimeout(r, 30));
  const msg = posted.slice(before).find((m) => m.type === "media");
  assert.ok(msg, "media message posted");
  assert.equal(msg.base64, "iVBORw==");
  api.mediaSaved(msg.reqId, "media/shot-002.png");
  assert.match(md(), /!\[\]\(media\/shot-002\.png\)/);
});

test("a delayed pasted file cannot cross into another item", async () => {
  let release;
  const file = { type: "image/png", name: "slow.png", arrayBuffer: () => new Promise((r) => { release = r; }) };
  api.open({ id: "13", markdown: "source\n", context: 4, focus: false });
  const before = posted.length;
  view.someProp("handlePaste", (f) => f(view, { clipboardData: { files: [file] }, preventDefault() {} }));
  api.open({ id: "14", markdown: "destination\n", context: 4, focus: false });
  release(new Uint8Array([1, 2]).buffer);
  await new Promise((r) => setTimeout(r, 0));
  const msg = posted.slice(before).find((m) => m.type === "media");
  assert.equal(api.mediaSaved(msg.reqId, "media/image-001.png"), false);
  assert.equal(md(), "destination\n");
});

test("changing the item-lifetime context invalidates a delayed paste", async () => {
  let release;
  const file = { type: "image/png", name: "slow.png", arrayBuffer: () => new Promise((r) => { release = r; }) };
  api.open({ id: "15", markdown: "same item\n", context: 7, focus: false });
  const before = posted.length;
  view.someProp("handlePaste", (f) => f(view, { clipboardData: { files: [file] }, preventDefault() {} }));
  api.setContext(8);
  release(new Uint8Array([1, 2]).buffer);
  await new Promise((r) => setTimeout(r, 0));
  const msg = posted.slice(before).find((m) => m.type === "media");
  assert.equal(api.mediaSaved(msg.reqId, "media/image-001.png"), false);
  assert.equal(md(), "same item\n");
});

test("a session reset drops undo history even when item ids and text match", () => {
  api.open({ id: "1", markdown: "old session\n", context: 5, focus: false });
  api.selectAll();
  type("shared");
  api.takePending();
  api.reset();
  api.open({ id: "1", markdown: "shared\n", context: 6, focus: false });
  api.undo();
  assert.equal(md(), "shared\n");
});

test("takePending hands over an unsaved change exactly once", () => {
  api.open({ id: "20", markdown: "a\n", focus: false });
  view.dispatch(view.state.tr.setSelection(view.state.selection.constructor.atEnd(view.state.doc)));
  type("b");
  assert.deepEqual(api.takePending(), { id: "20", markdown: "ab\n" });
  assert.equal(api.takePending(), null);
  const before = changes().length;
  api.flush();
  assert.equal(changes().length, before, "nothing left for the timer to post");
});

test("moving to another item with the same picture name shows that item's picture", () => {
  const md = "Shot\n\n![](media/shot-001.png)\n\n[clip](media/clip-001.mp4)\n";
  api.open({ id: "21", markdown: md, base: "snagbook://item/21/", focus: false });
  const img = () => document.querySelector(".img-wrap img");
  assert.match(img().src, /item\/21\/media\/shot-001\.png/);
  api.open({ id: "22", markdown: md, base: "snagbook://item/22/", focus: false });
  assert.match(img().src, /item\/22\/media\/shot-001\.png/, "the picture still points at the previous item");
  const poster = document.querySelector(".video-card img");
  if (poster) assert.match(poster.src, /item\/22\//, "the video poster still points at the previous item");
  api.open({ id: "21", markdown: md, base: "snagbook://item/21/", focus: false });
  assert.match(img().src, /item\/21\/media\/shot-001\.png/, "coming back shows the first item's picture again");
});
