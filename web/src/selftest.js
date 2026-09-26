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
    const line = (pass ? "ok   " : "FAIL ") + what;
    lines.push(line);
    invoke("selftest_log", { line }).catch(() => {});
    if (!pass) ok = false;
  };
  const $ = (id) => document.getElementById(id);
  const snag = () => window.snag;
  const items = () => shell.view()?.session?.items || [];

  try {
    // SNAGBOOK_SELFTEST=fail: one check that must fail, to prove a failure reaches the exit status.
    if ((await invoke("selftest_mode")) === "fail") check(false, "negative control: this check fails on purpose");
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

    // 10. a screenshot: the frozen screen, cropped to a rectangle, marked up, into the note
    await shell.show(1);
    const nextMarked = () =>
      new Promise((resolve) => {
        const orig = shell.onMarked;
        shell.onMarked = async (p) => {
          shell.onMarked = orig;
          await orig(p);
          resolve(p);
        };
      });
    const base = () => `${location.protocol === "http:" || navigator.userAgent.includes("Windows") ? "http://snagbook.localhost" : "snagbook://localhost"}/item/1/`;
    const fetchText = (rel) => fetch(base() + rel + "?t=" + Date.now()).then((r) => (r.ok ? r.text() : null)).catch(() => null);
    const fetchSize = (rel) => fetch(base() + rel + "?t=" + Date.now()).then((r) => (r.ok ? r.arrayBuffer().then((x) => x.byteLength) : null)).catch(() => null);
    const pixel = async (rel, fx, fy) => {
      const img = new Image();
      img.crossOrigin = "anonymous";
      img.src = base() + rel + "?t=" + Date.now();
      if (!(await imageLoaded(img))) return null;
      const c = Object.assign(document.createElement("canvas"), { width: img.naturalWidth, height: img.naturalHeight });
      const g = c.getContext("2d");
      g.drawImage(img, 0, 0);
      return [...g.getImageData(Math.round(img.naturalWidth * fx), Math.round(img.naturalHeight * fy), 1, 1).data];
    };

    let marked = nextMarked();
    await invoke("selftest_markup_next", { script: "ring" });
    await invoke("start_screenshot");
    check(await until(() => invoke("capture_open")), "Screenshot opens the full-screen window");
    await invoke("finish_screenshot", { rect: { x: 0.1, y: 0.1, w: 0.25, h: 0.2 } });
    check(await until(() => invoke("markup_open")), "a new screenshot opens in the mark-up window");
    let m = await Promise.race([marked, sleep(10000).then(() => null)]);
    check(m?.id === 1 && m?.rel === "media/shot-001.png" && m.isNew && m.kept, "Done saves it into item 1 as media/shot-001.png: " + JSON.stringify(m));
    check(await until(async () => !(await invoke("capture_open")) && !(await invoke("markup_open"))), "the screenshot and mark-up windows close");
    await shell.flush();
    check((await invoke("read_note", { id: 1 })).includes("media/shot-001.png"), "the screenshot is in the note");
    const shot = [...document.querySelectorAll("#editor .img-wrap img")].find((i) => i.src.includes("shot-001"));
    const loaded = await imageLoaded(shot);
    const want = Math.round(screen.width * devicePixelRatio * 0.25);
    check(loaded && Math.abs(shot.naturalWidth - want) <= 1, `the screenshot is a quarter of the screen wide: ${shot?.naturalWidth} of ${want}`);
    const marks1 = JSON.parse((await fetchText("media/shot-001.marks.json")) || "null");
    check(marks1?.marks?.length === 1 && marks1.marks[0].tool === "ellipse" && marks1.width === want, "shot-001.marks.json holds the circle, in the macOS app's format");
    const origSize = await fetchSize("media/shot-001.orig.png");
    check(origSize > 0, "the untouched original is kept as shot-001.orig.png");
    const ring = await pixel("media/shot-001.png", 0.2, 0.5);
    check(ring && ring[0] > 200 && ring[1] < 110 && ring[2] < 110, "the circle is drawn into the picture: " + JSON.stringify(ring));

    // 10b. marking up a picture again keeps its marks and its original
    marked = nextMarked();
    await invoke("selftest_open_markup", { id: 1, rel: "media/shot-001.png", script: "count" });
    m = await Promise.race([marked, sleep(10000).then(() => null)]);
    check(m && !m.isNew && m.changed, "marking up an existing picture saves it again");
    const marks2 = JSON.parse((await fetchText("media/shot-001.marks.json")) || "null");
    check(marks2?.marks?.map((x) => x.tool).join() === "ellipse,counter" && marks2.marks[1].number === 1, "the new mark joins the old one: " + marks2?.marks?.map((x) => x.tool));
    check((await fetchSize("media/shot-001.orig.png")) === origSize, "the original is still the first one");

    // 10c. removing every mark puts the original back
    marked = nextMarked();
    await invoke("selftest_open_markup", { id: 1, rel: "media/shot-001.png", script: "clear" });
    await Promise.race([marked, sleep(10000)]);
    check((await fetchSize("media/shot-001.png")) === origSize && (await fetchSize("media/shot-001.orig.png")) === null && (await fetchText("media/shot-001.marks.json")) === null, "no marks: the picture is the original again, with no companions");

    // 10d. No Marks keeps a new screenshot as it is; Discard throws it away
    marked = nextMarked();
    await invoke("selftest_markup_next", { script: "skip" });
    await invoke("start_screenshot");
    await until(() => invoke("capture_open"));
    await invoke("finish_screenshot", { rect: { x: 0.5, y: 0.5, w: 0.2, h: 0.2 } });
    m = await Promise.race([marked, sleep(10000).then(() => null)]);
    await shell.flush();
    check(m?.rel === "media/shot-002.png" && m.kept && (await invoke("read_note", { id: 1 })).includes("media/shot-002.png") && (await fetchText("media/shot-002.marks.json")) === null, "No Marks keeps the screenshot without companions");
    marked = nextMarked();
    await invoke("selftest_markup_next", { script: "discard" });
    await invoke("start_screenshot");
    await until(() => invoke("capture_open"));
    await invoke("finish_screenshot", { rect: { x: 0.5, y: 0.1, w: 0.2, h: 0.2 } });
    m = await Promise.race([marked, sleep(10000).then(() => null)]);
    await shell.flush();
    check(m?.rel === "media/shot-003.png" && !m.kept && (await fetchSize("media/shot-003.png")) === null && !(await invoke("read_note", { id: 1 })).includes("shot-003"), "Discard throws the screenshot away");

    await invoke("start_screenshot");
    await until(() => invoke("capture_open"));
    await invoke("cancel_screenshot");
    check(await until(async () => !(await invoke("capture_open"))), "Esc closes the screenshot window");
    const media = items().find((i) => i.id === 1);
    await shell.refresh();
    check(items().find((i) => i.id === 1)?.images === media?.images, "a cancelled screenshot saves nothing");

    // 11. a recording: drag the area, a few seconds, Stop; the video and its companions
    await shell.show(1);
    const recorded = new Promise((resolve) => {
      const orig = shell.onCaptured;
      shell.onCaptured = async (p) => {
        await orig(p);
        if (p.kind === "video" || p.rel.includes("clip-")) resolve(p);
      };
    });
    await invoke("toggle_recording");
    check(await until(() => invoke("capture_open")), "Record opens the full-screen window to choose the area");
    await invoke("finish_screenshot", { rect: { x: 0.2, y: 0.2, w: 0.4, h: 0.3 } });
    check(await until(async () => (await invoke("recording_started")) != null), "recording starts when the area is chosen");
    check(await until(() => $("rec").textContent === "Stop"), "the Record button turns into Stop");
    let bar = null;
    await until(async () => (bar = await invoke("recbar_size")) != null && bar[1] < 80, 10000);
    check(bar && bar[1] < 80 && bar[0] > 150, "the timer window is a small bar: " + JSON.stringify(bar));
    await sleep(2600);
    await invoke("stop_recording");
    const rec = await Promise.race([recorded, sleep(20000).then(() => null)]);
    const video = await invoke("ffmpeg_found");
    const wantRel = video ? "media/clip-001.mp4" : "media/clip-001-contact.jpg";
    if (video) check(rec?.kind === "video" && rec?.rel === wantRel, "the recording is saved as " + wantRel + ": " + JSON.stringify(rec));
    else check(rec?.kind === "image" && rec?.rel === wantRel && /ffmpeg/.test(rec?.problem || ""), "without ffmpeg the contact sheet is saved, and the reason is given: " + JSON.stringify(rec));
    check((await invoke("read_note", { id: 1 })).includes(wantRel), "the recording is in the note");
    check(await until(() => $("rec").textContent === "Record"), "the button says Record again");
    const info = await fetch(base() + "media/clip-001.json").then((r) => r.json()).catch(() => null);
    check(info && info.duration >= 2.3 && info.duration <= 3.6, "clip-001.json gives the length: " + info?.duration);
    check(info?.stills?.length === 3 && info.stills[0].file === "clip-001-frames/0001.jpg", "one still a second beside it: " + info?.stills?.length);
    check(info?.width === Math.round(screen.width * devicePixelRatio * 0.4) - (Math.round(screen.width * devicePixelRatio * 0.4) % 2), "the video is the area's size: " + info?.width);
    if (video) {
      const poster = [...document.querySelectorAll("#editor .video-card img")].find((i) => i.src.includes("clip-001-frames"));
      check(await imageLoaded(poster), "the video card shows its first still");
    }
    const sheet = new Image();
    sheet.src = base() + "media/clip-001-contact.jpg";
    check(await imageLoaded(sheet), "the contact sheet is there");

    // 12. a session deleted from outside is closed, not written back
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
