# Snagbook

**A notebook for testing sessions: numbered findings, each with a note and screenshots, kept as plain folders anyone can read.**

<p align="center"><img src="docs/images/notebook.png" alt="The Snagbook window: a list of findings on the left, the selected finding's note with a screenshot on the right" width="820"></p>

When you play-test a game or click through an app, the findings pile up faster than you can write them down. Snagbook keeps one window open beside what you are testing. Every finding is an item with a title, a note and its pictures; a screenshot is one key press and a drag away, and it lands in the note you are writing.

- **Start a session** for one sitting of testing.
- **Add an item** per finding, type what happened, press a key to grab a screenshot.
- **Hand it off**: one click copies a short text that points whoever fixes things at the session.

Everything is saved as ordinary files as you type: a folder per session, a folder per item, Markdown notes and PNG pictures. There is nothing to export.

It runs on Linux and Windows.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [A tour](#a-tour)
- [Keys](#keys)
- [Settings](#settings)
- [What it touches](#what-it-touches)
- [Limits](#limits)
- [Building from source](#building-from-source)
- [License](#license)

## Install

Download the package for your system from the [Releases](../../releases) page:

- **Debian, Ubuntu and relatives:** `sudo apt install ./Snagbook_0.1.0_amd64.deb`
- **Any other Linux:** the `.AppImage`. Make it executable (`chmod +x Snagbook_0.1.0_amd64.AppImage`) and run it.
- **Windows:** the `Snagbook_0.1.0_x64-setup.exe` installer.

Or build it yourself; see [Building from source](#building-from-source).

## Quick start

1. Open Snagbook and press **New Session**. The first item, *Item 1*, is ready and its title is selected: type what the finding is about and press Enter.
2. Type the note. Paste or drop pictures into it.
3. Press **Ctrl+Alt+S** anywhere, drag a rectangle around what matters, and let go. The picture goes into the note.
4. **Ctrl+N** starts the next item.
5. When you are done, press **Copy Hand-off** and paste the text wherever the fixing happens.

## A tour

### Sessions

A session is one sitting of testing. The name at the top of the list (click it) switches between recent sessions, starts a new one, renames this one, or opens a session folder from anywhere else, for example one a colleague shared. A session is named after the time it started until you give it a name.

### Items and notes

Each finding is an item, numbered in order. Click an item or use the arrow keys in the list to move between them; drag an item to reorder it; right-click it to rename it, show its folder or delete it. Deleting moves the item's folder to the Trash. On a drive without a Trash (a network share, for example), Snagbook asks before deleting it for good.

The note is a small word processor: headings, bold and italic, colours, lists, checklists, quotes, links and code. It is saved as Markdown while you type.

The buttons above the note (**Bug**, **Expected**, **Steps**, **Idea**) type a ready-made start, such as `**Bug:** ` or a numbered list of steps, where the cursor is. Ctrl+1 to Ctrl+9 do the same without the mouse, and you can change the buttons in Settings.

### Screenshots

Press **Ctrl+Alt+S** in any app, or the **Screenshot** button. The screen under the mouse freezes, you drag a rectangle over it, and the picture is saved into the item you are looking at and put in its note at the cursor. Enter takes the whole screen; Esc cancels. Because the screen is frozen first, nothing that moves while you drag ends up in the picture.

Pictures you paste or drop into a note are saved into the item as well.

### Hand-off

**Copy Hand-off** copies a short text for whoever reads the session next, a colleague or a coding assistant: a header you can write yourself (Settings), with the session's folder filled in. Every session also keeps a `README.md` with the header and every item's note in order, so the whole session is one file to read.

## Keys

| Key | What it does |
|---|---|
| Ctrl+Alt+S | Screenshot, from any app |
| Ctrl+Alt+N | New item, from any app (brings the notebook forward) |
| Ctrl+Alt+B | Show or hide the notebook, from any app |
| Ctrl+N | New item |
| Ctrl+Shift+N | New session |
| Ctrl+O | Switch session |
| Ctrl+Shift+C | Copy hand-off |
| Ctrl+1 … Ctrl+9 | Type a template |
| Ctrl+, | Settings |
| ↑ ↓ in the list | Previous / next item |
| Delete in the list | Delete the item |

The three "from any app" keys can be changed or switched off in Settings. Hover over a button to see its key.

## Settings

Open them from the session menu or with Ctrl+,:

- **Sessions folder**: where new sessions are made (`~/Snagbook` to start with; `~` is your home folder).
- **New session folder name**: built from `{hash}` (eight random letters and digits) and the date and time, `{yyyy} {MM} {dd} {HH} {mm}`.
- **Copy Hand-off copies** the header, or only the path of the session's `README.md`.
- **Keep the notebook above other windows.**
- **Shortcuts that work in any app.**
- **Header for every session**, with the placeholders `{session}`, `{readme}`, `{date}` and `{items}`. One session can have its own header instead (session menu, *Edit Header…*).
- **Templates**: the buttons above the note.

The settings are a JSON file you can also edit by hand: `~/.config/Snagbook/config.json` on Linux, `%APPDATA%\Snagbook\config.json` on Windows. If Snagbook cannot read it, it says so and does not overwrite it.

## What it touches

- **Your sessions folder**, and any session folder you open. A session looks like this:

  ```
  1a2b3c4d_25-09-2026/
    README.md            the header and every item's note
    session.json         the order, titles and numbers of the items
    01-main-menu/
      notes.md           the note, in Markdown
      media/             shot-001.png, image-001.png, …
  ```

  Folders renamed or removed by hand are noticed the next time the session opens; a session whose folder is deleted while it is open is closed, never written back.
- **Its settings file** (above).
- **The Trash**, when you delete an item.
- **The clipboard**, only when you press Copy Hand-off.
- **The screen**, only when you take a screenshot, and only the monitor under the mouse. The picture stays in memory until you choose the rectangle; only the part you chose is saved.

Snagbook makes no network connections. Links in notes open in your browser when you click them.

## Limits

- **Wayland** (the default on recent Ubuntu and Fedora): shortcuts cannot work from other apps, because Wayland does not let programs listen for keys globally. Use the keys inside the window, or bind a key in your desktop's settings to run Snagbook. Screenshots go through your desktop's screen-sharing permission, which may ask each time.
- **Windows** builds are made and tested less than the Linux ones.
- There is no mark-up of pictures and no screen recording yet.

## Building from source

You need [Rust](https://rustup.rs), [Node.js](https://nodejs.org) 20 or newer, and on Linux the WebKitGTK and PipeWire development packages. On Debian or Ubuntu:

```sh
sudo apt install build-essential libwebkit2gtk-4.1-dev libxdo-dev libssl-dev \
  libayatana-appindicator3-dev librsvg2-dev libpipewire-0.3-dev libspa-0.2-dev libclang-dev
```

Then:

```sh
npm ci
npm run build:web
npx tauri build            # packages land in target/release/bundle/
```

## License

[MIT](LICENSE): use it, change it, share it, sell it. Keep the copyright notice.
