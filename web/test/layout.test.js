import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/editor.css", import.meta.url), "utf8");
const rule = (sel) => css.match(new RegExp(`(^|\\n)${sel.replace(/\./g, "\\.")}\\s*\\{([^}]*)\\}`))?.[2] ?? "";

test("note text starts at the left edge with the title, not centred in a wide window", () => {
  const body = rule(".ProseMirror");
  assert.ok(body, "the .ProseMirror rule exists");
  assert.doesNotMatch(body, /margin[^;]*\bauto\b/, "an auto horizontal margin centres the column and leaves a gap on the left");
  assert.match(body, /padding:\s*\d+px 28px/, "left padding matches the 28px title inset");
});
