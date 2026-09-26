// Ported from the macOS app's MarksTests, plus the file-format round trip.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as M from "../src/marks.js";

const mark = (tool, points, extra = {}) => ({ tool, points: points.map(([x, y]) => M.pt(x, y)), color: "#ff0000", width: 4, ...extra });

test("hit testing", () => {
  const ring = mark("ellipse", [[0, 0], [100, 50]]);
  assert.ok(M.hit(ring, M.pt(100, 25), 2));
  assert.ok(!M.hit(ring, M.pt(50, 25), 2), "the middle of a circle is not the circle");
  const box = mark("rect", [[10, 10], [60, 60]]);
  assert.ok(M.hit(box, M.pt(10, 30), 2));
  assert.ok(!M.hit(box, M.pt(35, 35), 2));
  const blur = mark("pixelate", [[10, 10], [60, 60]], { color: "#000000", width: 1 });
  assert.ok(M.hit(blur, M.pt(35, 35), 2), "a blur is solid");
  const arrow = mark("arrow", [[0, 0], [100, 0]]);
  assert.ok(M.hit(arrow, M.pt(50, 3), 2));
  assert.ok(!M.hit(arrow, M.pt(50, 20), 2));
  const pen = mark("pen", [[0, 0], [10, 10], [20, 0]]);
  assert.ok(M.hit(pen, M.pt(15, 5), 2));
});

test("constrain and counters", () => {
  assert.deepEqual(M.constrain(M.pt(0, 0), M.pt(30, -10), "rect"), M.pt(30, -30));
  const a = M.constrain(M.pt(0, 0), M.pt(10, 1), "arrow");
  assert.ok(Math.abs(a.y) < 1e-9);
  const doc = M.newDocument(100, 100);
  assert.equal(M.nextCounter(doc), 1);
  doc.marks.push(mark("counter", [[5, 5]], { number: 4 }));
  assert.equal(M.nextCounter(doc), 5);
});

test("the output box clamps the crop", () => {
  const d = M.newDocument(200, 100);
  assert.deepEqual(M.outputBox(d), { x: 0, y: 0, w: 200, h: 100 });
  d.crop = { x: 150, y: -20, w: 100, h: 60 };
  assert.deepEqual(M.outputBox(d), { x: 150, y: 0, w: 50, h: 40 });
  d.crop = { x: 500, y: 500, w: 10, h: 10 };
  assert.deepEqual(M.outputBox(d), { x: 0, y: 0, w: 200, h: 100 }, "a crop outside the picture is ignored");
});

test("companions and the file format round trip", () => {
  assert.deepEqual(M.companions("media/shot-001.png"), { orig: "media/shot-001.orig.png", marks: "media/shot-001.marks.json" });
  const d = M.newDocument(10, 20);
  d.marks.push({ tool: "text", points: [M.pt(1, 2)], color: "#fff", width: 18, text: "hi" });
  const json = M.encodeDocument(d);
  assert.ok(!json.includes("crop"), "no crop is left out, as the macOS app does");
  assert.deepEqual(M.parseDocument(json, 10, 20), d);
  assert.equal(M.parseDocument(json, 11, 20), null, "marks for another picture size are not used");
  assert.equal(M.parseDocument("{nope", 10, 20), null);
});

test("reads a marks file written by the macOS app", () => {
  const mac = `{
  "height" : 720,
  "marks" : [
    { "color" : "#ffcc00", "points" : [ { "x" : 10, "y" : 20 }, { "x" : 300, "y" : 22 } ], "tool" : "highlighter", "width" : 16 },
    { "color" : "#ff3b30", "number" : 1, "points" : [ { "x" : 50, "y" : 60 } ], "tool" : "counter", "width" : 4 }
  ],
  "version" : 1,
  "width" : 1280
}`;
  const d = M.parseDocument(mac, 1280, 720);
  assert.equal(d.marks.length, 2);
  assert.equal(M.nextCounter(d), 2);
});

test("simplify keeps the ends", () => {
  const pts = Array.from({ length: 101 }, (_, i) => M.pt(i * 0.1, 0));
  const s = M.simplify(pts, 1);
  assert.deepEqual(s[0], pts[0]);
  assert.deepEqual(s[s.length - 1], pts[pts.length - 1]);
  assert.ok(s.length < 15);
});

test("default sizes follow the picture", () => {
  assert.equal(M.defaultWidth(640, 480), 3);
  assert.equal(M.defaultWidth(2560, 1440), 8);
  assert.equal(M.defaultWidth(10000, 10000), 12);
  assert.equal(M.textSize(3), 18);
  assert.equal(M.textSize(8), 40);
});
