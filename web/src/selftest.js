// End-to-end checks inside the real window, run with SNAGBOOK_SELFTEST=1 and a throwaway
// SNAGBOOK_CONFIG and HOME. They click the real page, read the real files through the app's
// own commands, and load pictures through the real snagbook: scheme.

const RED = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4o6GBFTEMLQkAe3tLAfuiUfAAAAAASUVORK5CYII=";
const GREEN = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGPQWGCDFTEMLQkAYT9BAZjEcQwAAAAASUVORK5CYII=";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function until(fn, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      if (await fn()) return true;
    } catch {}
    await sleep(50);
  }
  return false;
}

function imageLoaded(img) {
  return new Promise((resolve) => {
    if (!img) return resolve(false);
    if (img.complete) return resolve(img.naturalWidth > 0);
    img.addEventListener("load", () => resolve(img.naturalWidth > 0), { once: true });
    img.addEventListener("error", () => resolve(false), { once: true });
    setTimeout(() => resolve(img.naturalWidth > 0), 3000);
  });
}

export async function runSelfTest(shell, invoke) {
  const lines = [];
  let ok = true;
  const check = (pass, what) => {
    lines.push((pass ? "ok   " : "FAIL ") + what);
    if (!pass) ok = false;
  };
  const $ = (id) => document.getElementById(id);
  const snag = () => window.snag;
  const items = () => shell.view()?.session?.items || [];

  try {
    await until(() => shell.editorIsReady());
    check(shell.editorIsReady(), "the editor page is ready");

    // 1. a session and its first item
    await shell.newSession();
    const path = shell.view()?.session?.path || "";
    check(/[0-9a-f]{8}_\d\d-\d\d-\d{4}$/.test(path), "new session folder is hash_dd-mm-yyyy: " + path);
    check(items().length === 1 && items()[0].title === "Item 1", "a new session starts with Item 1");

    // 2. renaming through the title field renames the folder
    const t = $("item-title");
    t.focus();
    t.value = "Main menu";
    t.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    check(await until(() => items()[0]?.folder === "01-main-menu"), "typing a title renames the item's folder");

    // 3. typed text reaches notes.md
    snag().typeText("The logo overlaps the Start button.");
    await shell.flush();
    check((await invoke("read_note", { id: 1 })).includes("The logo overlaps the Start button."), "typed text reaches notes.md");

    // 4. a template button types its text
    document.querySelector("#templates .template")?.click();
    await shell.flush();
    check((await invoke("read_note", { id: 1 })).includes("**Bug:**"), "the Bug template inserts **Bug:**");

    // 5. a pasted picture is saved and shown through the snagbook: scheme
    const rel1 = await invoke("save_media", { id: 1, base64: RED, mime: "image/png", name: "" });
    check(rel1 === "media/image-001.png", "a pasted picture is saved as media/image-001.png: " + rel1);
    snag().insertMedia({ kind: "image", src: rel1 });
    await shell.flush();
    await shell.refresh();
    const img = () => document.querySelector("#editor .img-wrap img");
    check(await imageLoaded(img()), "the picture loads in the editor");
    check(items()[0].images === 1, "the sidebar counts the picture");
    const missing = new Image();
    missing.src = img().src.replace("image-001", "image-999");
    check(!(await imageLoaded(missing)), "negative control: a missing picture does not load");

    // 6. New Item, and two items whose pictures share a name show their own
    $("new-item").click();
    check(await until(() => items().length === 2 && shell.selected() === 2), "New Item adds item 2 and selects it");
    const rel2 = await invoke("save_media", { id: 2, base64: GREEN, mime: "image/png", name: "" });
    snag().insertMedia({ kind: "image", src: rel2 });
    await shell.flush();
    check(rel2 === rel1, "both items call their picture " + rel2);
    await shell.show(1);
    check(await until(() => img()?.src.includes("/item/1/")), "item 1 shows its own picture after switching back");
    await shell.show(2);
    check(await until(() => img()?.src.includes("/item/2/")), "item 2 shows its own picture");

    // 7. arrow keys move through the list
    $("items").focus();
    $("items").dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }));
    check(await until(() => shell.selected() === 1), "arrow up selects the item above");

    // 8. delete the last item and the next one takes its number back
    const del = shell.deleteItem(2);
    check(await until(() => !$("modal").hidden), "delete asks first");
    $("modal").querySelector('button[data-value="true"]')?.click();
    await until(() => items().length === 1 || !$("modal").hidden);
    if (!$("modal").hidden) {
      // The drive had no Trash: the second question is whether to delete for good.
      lines.push("note the Trash was unavailable: " + $("modal").querySelector("p")?.textContent);
      $("modal").querySelector('button[data-value="true"]')?.click();
    }
    await del;
    check(await until(() => items().length === 1), "delete removes the item");
    $("new-item").click();
    check(await until(() => items().length === 2 && items()[1].id === 2), "deleting from the end gives the number back");

    // 9. hand-off
    const text = await shell.copyHandoff();
    check(text.includes(path), "Copy Hand-off names the session folder");

    // 10. a session deleted from outside is closed, not written back
    await invoke("selftest_delete_session");
    await shell.refresh();
    check(shell.view().session === null, "a session deleted from outside is closed");
    check(!$("empty").hidden, "the start screen is shown");
    const list = await invoke("list_sessions");
    check(!list.some((s) => s.path === path), "and it is gone from the session list");
  } catch (e) {
    check(false, "self-test threw: " + (e?.message || e));
  }
  await invoke("selftest_done", { ok, lines });
}
