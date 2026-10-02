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
  const sessionArgs = (id) => ({ sessionId: shell.view().session.id, openToken: shell.view().session.openToken, itemToken: items().find((item) => item.id === id)?.itemToken, id });

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

    // 3. typed text reaches notes.md by itself, without switching items
    snag().typeText("The logo overlaps the Start button.");
    check(await until(async () => (await invoke("read_note", sessionArgs(1))).includes("The logo overlaps the Start button."), 5000), "typed text reaches notes.md by itself");

    // 4. a template button types its text
    document.querySelector("#templates .template")?.click();
    await shell.flush();
    check((await invoke("read_note", sessionArgs(1))).includes("**Bug:**"), "the Bug template inserts **Bug:**");

    // 5. a pasted picture is saved and shown through the snagbook: scheme
    const saved1 = await invoke("save_media", { ...sessionArgs(1), base64: RED, mime: "image/png", name: "" });
    const rel1 = saved1.rel;
    check(rel1 === "media/image-001.png", "a pasted picture is saved as media/image-001.png: " + rel1);
    snag().insertMedia({ kind: "image", src: rel1 });
    await shell.flush();
    await invoke("capture_filed", { ack: saved1.ack, inserted: true });
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
    const saved2 = await invoke("save_media", { ...sessionArgs(2), base64: GREEN, mime: "image/png", name: "" });
    const rel2 = saved2.rel;
    snag().insertMedia({ kind: "image", src: rel2 });
    await shell.flush();
    await invoke("capture_filed", { ack: saved2.ack, inserted: true });
    check(rel2 === rel1, "both items call their picture " + rel2);
    await shell.show(1);
    check(await until(() => /\/item\/1\.\d+\//.test(img()?.src || "")), "item 1 shows its own picture after switching back");
    await shell.show(2);
    check(await until(() => /\/item\/2\.\d+\//.test(img()?.src || "")), "item 2 shows its own picture");

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
    check(m?.id === 1 && m?.rel === "media/shot-001.png" && m.isNew && m.kept && m.sessionPath === shell.view().session.path, "Done saves it into item 1 as media/shot-001.png with its session path: " + JSON.stringify(m));
    check(await until(async () => !(await invoke("capture_open")) && !(await invoke("markup_open"))), "the screenshot and mark-up windows close");
    await shell.flush();
    check((await invoke("read_note", sessionArgs(1))).includes("media/shot-001.png"), "the screenshot is in the note");
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

    // 10a. a see-through mark lets the picture show through, drawn by the real canvas
    {
      const { renderDocument } = await import("./markrender.js");
      const white = Object.assign(document.createElement("canvas"), { width: 100, height: 60 });
      const w = white.getContext("2d");
      w.fillStyle = "#ffffff";
      w.fillRect(0, 0, 100, 60);
      const doc = { version: 1, width: 100, height: 60, crop: null, marks: [{ tool: "rect", points: [{ x: 20, y: 10 }, { x: 80, y: 50 }], color: "#ff0000", width: 8 }] };
      const px = () => [...renderDocument(doc, white, (a, b) => Object.assign(document.createElement("canvas"), { width: a, height: b })).getContext("2d").getImageData(20, 30, 1, 1).data];
      const solid = px();
      doc.marks[0].opacity = 0.4;
      const faint = px();
      check(solid[1] < 40 && faint[0] > 245 && faint[1] > 130 && faint[1] < 180, `a 40% mark is pink over white, a solid one red: ${solid} / ${faint}`);
      // A see-through highlighter still tints: black under it stays black.
      w.fillStyle = "#000000";
      w.fillRect(0, 0, 100, 60);
      const hl = { version: 1, width: 100, height: 60, crop: null, marks: [{ tool: "highlighter", points: [{ x: 10, y: 30 }, { x: 90, y: 30 }], color: "#ffd60a", width: 24, opacity: 0.5 }] };
      const under = [...renderDocument(hl, white, (a, b) => Object.assign(document.createElement("canvas"), { width: a, height: b })).getContext("2d").getImageData(50, 30, 1, 1).data];
      check(under[0] < 8 && under[1] < 8 && under[2] < 8, `a half see-through highlighter leaves black text black: ${under}`);
    }

    // 10a'. double-clicking a picture in the note opens it in the mark-up window
    {
      const pic = [...document.querySelectorAll("#editor .img-wrap")].find((w) => w.querySelector("img")?.src.includes("shot-001"));
      pic?.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true, detail: 2 }));
      check(await until(() => invoke("markup_open"), 5000), "double-clicking a picture in the note opens the mark-up window" + (pic ? "" : " (no picture found)"));
      await invoke("skip_markup").catch(() => {});
      await until(async () => !(await invoke("markup_open")));
    }

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
    check(m?.rel === "media/shot-002.png" && m.kept && (await invoke("read_note", sessionArgs(1))).includes("media/shot-002.png") && (await fetchText("media/shot-002.marks.json")) === null, "No Marks keeps the screenshot without companions");
    marked = nextMarked();
    await invoke("selftest_markup_next", { script: "discard" });
    await invoke("start_screenshot");
    await until(() => invoke("capture_open"));
    await invoke("finish_screenshot", { rect: { x: 0.5, y: 0.1, w: 0.2, h: 0.2 } });
    m = await Promise.race([marked, sleep(10000).then(() => null)]);
    await shell.flush();
    check(m?.rel === "media/shot-003.png" && !m.kept && (await fetchSize("media/shot-003.png")) === null && !(await invoke("read_note", sessionArgs(1))).includes("shot-003"), "Discard throws the screenshot away");

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
    const pastedMedia = await invoke("save_media", { ...sessionArgs(1), base64: "AAAA", mime: "video/mp4", name: "" });
    const pasted = pastedMedia.rel;
    await invoke("capture_filed", { ack: pastedMedia.ack, inserted: false });
    check(pasted === "media/clip-002.mp4", "a video pasted during the recording gets its own name: " + pasted);
    // Renaming the item while it records: its folder keeps its name until the recording ends.
    const folderBefore = items().find((i) => i.id === 1)?.folder;
    await invoke("rename_item", { ...sessionArgs(1), expectedTitle: items().find((i) => i.id === 1)?.title, title: "Recorded item" });
    await shell.refresh();
    check(items().find((i) => i.id === 1)?.folder === folderBefore, "renaming an item while it records keeps its folder for now: " + folderBefore);
    let bar = null;
    await until(async () => (bar = await invoke("recbar_size")) != null && bar[1] < 80, 10000);
    check(bar && bar[1] < 80 && bar[0] > 150, "the timer window is a small bar: " + JSON.stringify(bar));
    await sleep(2600);
    const startedAt = await invoke("recording_started");
    await invoke("stop_recording");
    const stoppedAt = Date.now();
    const expected = (stoppedAt - startedAt) / 1000;
    // A first run of a freshly installed ffmpeg can be slow (a virus scan); the recorder
    // itself gives ffmpeg a minute.
    const rec = await Promise.race([recorded, sleep(120000).then(() => null)]);
    lines.push(`note the recording was finished ${((Date.now() - stoppedAt) / 1000).toFixed(1)}s after Stop`);
    const video = await invoke("ffmpeg_found");
    const wantRel = video ? "media/clip-001.mp4" : "media/clip-001-contact.jpg";
    if (video) check(rec?.kind === "video" && rec?.rel === wantRel && rec?.sessionPath === shell.view().session.path, "the recording is saved as " + wantRel + " with its session path: " + JSON.stringify(rec));
    else check(rec?.kind === "image" && rec?.rel === wantRel && /ffmpeg/.test(rec?.problem || ""), "without ffmpeg the contact sheet is saved, and the reason is given: " + JSON.stringify(rec));
    check((await invoke("read_note", sessionArgs(1))).includes(wantRel), "the recording is in the note");
    check(await until(() => $("rec").textContent === "Record"), "the button says Record again");
    await shell.refresh();
    const captureTrace = await invoke("selftest_capture_trace");
    check(/recorded-item/.test(items().find((i) => i.id === 1)?.folder || ""), "after the recording the folder follows the new title: " + items().find((i) => i.id === 1)?.folder + "; " + captureTrace);
    const info = await fetch(base() + "media/clip-001.json").then((r) => r.json()).catch(() => null);
    check(info && Math.abs(info.duration - expected) < 0.8, `clip-001.json gives the length: ${info?.duration}s for ${expected.toFixed(2)}s between Record and Stop`);
    check(info?.stills?.length === Math.min(60, Math.floor(info.duration) + 1) && info.stills[0].file === "clip-001-frames/0001.jpg", `one still a second beside it: ${info?.stills?.length} for ${info?.duration}s`);
    check(info?.width === Math.round(screen.width * devicePixelRatio * 0.4) - (Math.round(screen.width * devicePixelRatio * 0.4) % 2), "the video is the area's size: " + info?.width);
    if (video) {
      const poster = [...document.querySelectorAll("#editor .video-card img")].find((i) => i.src.includes("clip-001-frames"));
      check(await imageLoaded(poster), "the video card shows its first still");
    }
    const sheet = new Image();
    sheet.src = base() + "media/clip-001-contact.jpg";
    check(await imageLoaded(sheet), "the contact sheet is there");

    // 11b. a recording still going when another session is opened goes into its own note
    await shell.show(1);
    await invoke("toggle_recording");
    await until(() => invoke("capture_open"));
    await invoke("finish_screenshot", { rect: { x: 0.2, y: 0.2, w: 0.3, h: 0.3 } });
    check(await until(async () => (await invoke("recording_started")) != null), "a second recording starts");
    const refused = await invoke("delete_item", { ...sessionArgs(1), permanently: true }).then(() => "deleted", (e) => String(e));
    check(/still being saved/.test(refused), "an item being recorded is not deleted: " + refused);
    await sleep(1500);
    await shell.newSession();
    const other = shell.view().session.path;
    await invoke("stop_recording");
    check(await until(() => $("rec").textContent === "Record", 120000), "the button says Record once it is finished");
    await sleep(500);
    check(!(await invoke("read_note", sessionArgs(1))).includes("clip-"), "the session opened meanwhile gets no link");
    await shell.openSession(path);
    const back = await invoke("read_note", sessionArgs(1));
    check(/\]\(media\/clip-003\.(mp4|webm)\)|clip-003-contact/.test(back), "the recording is at the end of its own item's note: " + JSON.stringify(back.slice(-50)));
    check(other !== path, "(two sessions were used)");

    // 12. the session menu deletes the whole folder, then an outside deletion is noticed too
    await shell.openSession(path);
    const deleting = shell.deleteSession();
    check(await until(() => !$('modal').hidden), "deleting a session asks first");
    $('modal').querySelector('button[data-value="true"]')?.click();
    await until(() => shell.view().session === null || !$('modal').hidden);
    if (!$('modal').hidden) $('modal').querySelector('button[data-value="true"]')?.click();
    await deleting;
    check(shell.view().session === null, "deleting a session returns to the start screen");
    check(!(await invoke("list_sessions")).some((s) => s.path === path), "the deleted session is gone from the session list");

    await shell.newSession();
    const outside = shell.view().session.path;
    await invoke("selftest_delete_session");
    await shell.refresh();
    check(shell.view().session === null, "a session deleted from outside is closed");
    check(!$("empty").hidden, "the start screen is shown");
    const list = await invoke("list_sessions");
    check(!list.some((s) => s.path === outside), "and it is gone from the session list");
  } catch (e) {
    check(false, "self-test threw: " + (e?.message || e));
  }
  await invoke("selftest_done", { ok, lines });
}
