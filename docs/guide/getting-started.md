# Getting Started

## Prerequisites

- [Odin](https://odin-lang.org/docs/install/)
- A JS runtime for the frontend — [Node.js](https://nodejs.org) or [Bun](https://bun.sh)
  (pick yours with `heimdall new --pm`; the default starter needs no dependencies).
- **Platform webview deps** (the native backend links the system webview):
  - **macOS** — Xcode command-line tools (WebKit/Cocoa).
  - **Linux** — GTK4 + libadwaita + the GTK4 WebKit port:
    - Fedora: `sudo dnf install webkitgtk6.0-devel libadwaita-devel gtk4-devel`
    - Debian/Ubuntu: `sudo apt install libwebkitgtk-6.0-dev libadwaita-1-dev libgtk-4-dev`
  - **Windows** — the WebView2 runtime (ships with Win10/11). To produce an
    installer with `heimdall bundle`, [Inno Setup 6](https://jrsoftware.org/isinfo.php)
    (`winget install JRSoftware.InnoSetup6`); optional.

Run `heimdall doctor` anytime to check your toolchain and platform dependencies,
or `heimdall docs` to open this documentation locally in your browser.

## Install heimdall

::: warning Pre-release
The prebuilt binaries aren't published yet, so the one-liners below won't fetch
anything until the first release is out. For now, [build from source](#build-from-source).
:::

The installer downloads a prebuilt CLI and the framework into `~/.heimdall` and
sets `PATH` + `HEIMDALL_HOME` for you.

```sh
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/galaxoid-labs/heimdall/main/install.sh | sh
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/galaxoid-labs/heimdall/main/install.ps1 | iex
```

Open a new terminal afterward (or `. ~/.heimdall/env`). Pin a version with
`HEIMDALL_VERSION=v0.1.0`, change the location with `HEIMDALL_HOME`, or skip the
profile edits with `HEIMDALL_NO_MODIFY_PATH=1`.

### Supported platforms

Prebuilt CLI binaries are published for:

| OS | Architectures |
| --- | --- |
| macOS | Apple Silicon (arm64) |
| Linux | x86_64, arm64 |
| Windows | x86_64 |

Intel macOS and Windows on ARM aren't built (Windows ARM isn't an Odin target
yet). On an unsupported platform, [build the CLI from source](#build-from-source) —
it's pure Odin and compiles wherever Odin runs. Either way you also need Odin +
[Bun](https://bun.sh) installed to *build apps* (the CLI shells out to them);
run `heimdall doctor` to check.

### Build from source

The CLI is self-contained (just needs Odin) and compiles on any platform Odin
supports. From a clone of the repo:

```sh
odin build cli -out:heimdall-cli -o:speed
install -Dm755 heimdall-cli ~/.local/bin/heimdall
export HEIMDALL_HOME="$PWD"   # so `new` finds the framework to vendor
```

## Create an app

```sh
# Scaffold — vendors the framework + a frontend into ./myapp
heimdall new myapp                      # vanilla (default)
#   heimdall new myapp --frontend sveltekit            # interactive SvelteKit
#   heimdall new myapp --frontend sveltekit --pm pnpm  # …with a different PM

# Run it — a window opens with a button wired to Odin
cd myapp
heimdall dev
```

Edit your Odin or your frontend and `heimdall dev` reloads. (`heimdall new` finds
the framework via `HEIMDALL_HOME`, which the installer set; or pass `--framework`.)

## Dev console (web inspector)

Right-click → **Inspect Element** opens the platform web inspector (Safari Web
Inspector on macOS, WebKitGTK inspector on Linux, Edge DevTools on Windows).

It's controlled by `App_Config.devtools`, a build/config setting (not a runtime
JS switch):

```odin
hd.create(hd.App_Config{
    devtools = .Auto,   // default: on in `heimdall dev`, off in `heimdall build`
    // devtools = .On,  // force on — even in a release build
    // devtools = .Off, // force off — even in dev
})
```

`.Auto` is the zero value, so you get the inspector during `heimdall dev` and a
clean release with no extra config. Use `.On` to debug a shipped build, `.Off` to
lock it down while developing.

## Choosing a frontend

`--frontend` selects the scaffold:

- **`vanilla`** (default) — a dependency-free, Bun-served static frontend. No
  `node_modules`, works offline, instant. Great for small apps or as a starting
  point. (`dev` uses a tiny Bun static server; there's no HMR — refresh to see
  changes.)
- **`sveltekit`** — delegates to the official [`sv create`](https://svelte.dev/docs/cli):
  you pick the template and TypeScript/JSDoc interactively, and heimdall configures
  it for static embedding (`@sveltejs/adapter-static`, `ssr = false`, an
  `index.html` SPA fallback) and points `heimdall.toml` at `web/build`. You get
  full **Vite HMR** in `heimdall dev`. Options:
  - `--pm bun|npm|pnpm|yarn|deno` — package manager (default `bun`).
  - `--add <sv-addon>` (repeatable) — Svelte add-ons (Tailwind, Prettier, …), e.g.
    `--add tailwindcss=plugins:typography --add eslint`. heimdall adds the static
    adapter automatically — **don't add `sveltekit-adapter` yourself** (it must be
    configured during create, which heimdall handles).

  The typed client lands at `web/src/lib/heimdall.gen` — import it via
  `import { greeting } from "$lib/heimdall.gen.js"`.

  > heimdall must set the adapter **during** `sv create` (passing it via `--add`),
  > because adding it afterward leaves the project in a state that breaks Tailwind's
  > dev server. A side effect: the interactive add-on *menu* is skipped, so request
  > add-ons with heimdall's `--add` flag instead.

Because the app ships as static files inside the binary, SSR-only SvelteKit
features (server `load`, form actions) don't apply — it builds as a client SPA.
(With the **demo** template you'll see a harmless `Overwriting index.html` notice,
and its `sverdle` game's server actions won't function — but it builds and runs.)

## Project structure

```
myapp/
  main.odin            # creates the app, registers services, runs
  services.odin        # your services + command procs
  heimdall/            # the vendored framework (import hd "heimdall")
  web/                 # your frontend → web/dist
    index.html
    src/main.js
    src/heimdall.gen.js # generated typed client (+ .d.ts); regenerated by dev/build
  icon.png             # default app icon (the Heimdall mark) — replace with your own
  heimdall.toml        # optional config (window, packaging, signing, bindings)
  .github/workflows/   # a release workflow (signed builds)
```

The frontend is whatever produces a static build directory (`web/dist` for
vanilla, `web/build` for SvelteKit). heimdall only cares about three
`heimdall.toml` keys — `dev_cmd`, `build_cmd`, and `dist_dir` — so you can swap in
any bundler (Vite, esbuild, …) by changing those.

## Ship it

```sh
heimdall build                     # single binary with assets embedded
heimdall bundle                    # macOS .app, Linux .deb + .rpm, or Windows installer .exe
heimdall bundle --sign --notarize  # signed, notarized .app for distribution (macOS)
```

Next: [Commands](./commands.md) and [Events](./events.md).
