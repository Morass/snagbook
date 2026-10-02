// Bundles the page into web/dist, which the app loads offline.
import { build } from "esbuild";
import { copyFileSync, mkdirSync, rmSync } from "node:fs";

const src = new URL("./src/", import.meta.url).pathname;
const out = new URL("./dist/", import.meta.url).pathname;
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
for (const page of ["app", "capture", "recbar", "annotate"]) {
  await build({
    entryPoints: [src + page + ".js"],
    bundle: true,
    minify: true,
    format: "iife",
    target: ["safari15", "chrome100"],
    outfile: out + page + ".js",
    legalComments: "eof",
  });
}
copyFileSync(src + "index.html", out + "index.html");
copyFileSync(src + "capture.html", out + "capture.html");
copyFileSync(src + "capture.css", out + "capture.css");
copyFileSync(src + "recbar.html", out + "recbar.html");
copyFileSync(src + "recbar.css", out + "recbar.css");
copyFileSync(src + "annotate.html", out + "annotate.html");
copyFileSync(src + "annotate.css", out + "annotate.css");
copyFileSync(src + "app.css", out + "app.css");
copyFileSync(src + "editor/editor.css", out + "editor.css");
console.log("built", out);
