<p align="center">
  <img src="docs/public/logo.svg" width="92" alt="Heimdall">
</p>

<h1 align="center">Heimdall</h1>

**Native desktop apps with an Odin backend and a web frontend.**

Write your logic in [Odin](https://odin-lang.org) and your UI in any web stack.
Heimdall bridges the two, embeds the frontend into the executable, and ships a
single native binary. Like Tauri or Electron — but small, fast, and Odin all the
way down.

```odin
greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
    return {message = fmt.tprintf("Hello, %s", args.name)}, nil
}
```
```js
import { greeting } from "./heimdall.gen.js"           // typed client (generated)
const { message } = await greeting.greet({ name: "Jake" })
```

---

## Why

- **Bring your own frontend.** Your UI is a folder of static files. No bundler,
  framework, or `node_modules` is shipped for you.
- **One file to ship.** The frontend is baked into the binary at compile time.
- **A typed bridge.** Call Odin commands and subscribe to events from JS through a
  generated, fully-typed client — args, results, and event payloads checked from
  your Odin types. (Plain JSON underneath; an untyped escape hatch is always there.)
- **Fast inner loop.** `heimdall dev` rebuilds and relaunches in a blink.

---

## Get started

> ⚠️ **Pre-release:** prebuilt binaries aren't published yet, so the installers
> below won't fetch anything until the first release. For now, build the CLI from
> source — see [Getting Started](docs/guide/getting-started.md#build-from-source).

Install heimdall (downloads a prebuilt CLI + the framework into `~/.heimdall`):

```sh
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/galaxoid-labs/heimdall/main/install.sh | sh
```
```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/galaxoid-labs/heimdall/main/install.ps1 | iex
```

Then (open a new terminal first, or `. ~/.heimdall/env`):

```sh
heimdall new myapp                 # vanilla frontend (or --frontend sveltekit)
cd myapp && heimdall dev           # a window opens, wired to Odin
```

**Supported platforms:** macOS (Apple Silicon), Linux (x86_64 + arm64), Windows
(x86_64). Other platforms (Intel Mac, Windows ARM) — build the CLI from source;
it's pure Odin.

You still need [Odin](https://odin-lang.org/docs/install/) and a JS runtime
([Node.js](https://nodejs.org) or [Bun](https://bun.sh)) to *build* apps —
`heimdall doctor` checks everything.

Pick a frontend with `--frontend`: `vanilla` (dependency-free, offline) or
`sveltekit` (runs the official `sv create` — you pick template + TypeScript — and
heimdall wires it for static embedding). Choose a package manager with
`--pm bun|npm|pnpm|yarn|deno` (default bun; vanilla is dependency-free so any
works). SvelteKit also takes `--add <sv-addon>` (repeatable) for Svelte add-ons,
e.g. `--add tailwindcss=plugins:typography`; heimdall adds the static adapter
itself — don't add `sveltekit-adapter`.

Edit your Odin or frontend and `dev` reloads. Ship with `heimdall build` (a single
binary) or `heimdall bundle` (a macOS `.app`, `.deb` + `.rpm` on Linux, or an Inno
Setup installer `.exe` on Windows).

---

## How it works

```
WEB  (your frontend)   invoke("svc.cmd", {...})  ──►   BRIDGE (Odin)
  window.heimdall       on("event", handler)      ◄──   your procs
```

The web layer never touches the OS. Anything privileged goes through a **command**
you register in Odin — that boundary is the whole security model.

---

## Commands

A **service** is a struct with state; a **command** is a proc over it, callable
from JS. The JSON marshalling is generated from your types at compile time.

```odin
// services.odin
Greeting     :: struct { prefix: string }       // service state
Greet_Args   :: struct { name: string }         // input from JS
Greet_Result :: struct { message: string }      // result to JS

greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
    return {message = fmt.tprintf("%s%s", s.prefix, args.name)}, nil
}
```

```odin
// main.odin
app, _ := hd.create(hd.App_Config{title = "My App", width = 900, height = 600, assets = ASSETS})
defer hd.destroy(app)

greeting := Greeting{prefix = "Hello, "}
g := hd.service(app, "greeting", &greeting)
hd.command(g, "greet", greet)

hd.run(app)
```

```js
// Recommended: the typed client, generated from your Odin types
// (heimdall new/dev/build keep it fresh):
import { greeting } from "./heimdall.gen.js"
const { message } = await greeting.greet({ name: "Jake" })   // typed -> "Hello, Jake"
// a command that returns an error rejects the promise

// No build step? window.heimdall.invoke("greeting.greet", { name }) works too (untyped).
```

---

## Events

The push direction (progress, background work, live updates) — Odin sends data to
JS without being asked. Fire-and-forget, safe to emit from any thread.

```odin
hd.emit(app, "file.progress", Progress{read = 512, total = 1000})
```
```js
import { on } from "./heimdall.gen.js"   // or window.heimdall.on(...)
const off = on("file.progress", p => updateBar(p.read / p.total))
// off()  // unsubscribe
```

Want typed `invoke` **and** `on` in your editor? `heimdall generate-bindings`
writes a typed client (`heimdall.gen.js` + `.d.ts`) from your Odin types —
`dev`/`build` regenerate it automatically. Commands are typed from their
arg/result structs; events are typed when you declare the payload with
`hd.event(app, "name", T)`. Optional and additive; `window.heimdall.invoke` works
without it.

---

## Deep linking — `myapp://`

Open your app from a custom URL scheme. Declare the scheme and handle incoming
URLs via an Odin hook and/or a typed `open-url` event:

```odin
hd.create(hd.App_Config{
    url_schemes = {"myapp"},
    on_open_url = proc(app: ^hd.App, url: string) { route(url) },
})
```
```js
on("open-url", e => router.navigate(e.url))
```

Register it with the OS via `[bundle].schemes` in `heimdall.toml`; `heimdall
bundle` wires up macOS `CFBundleURLTypes`, the Linux `.desktop` handler, and the
Windows registry. All three platforms handle both cold-start and the
already-running case (single-instance forwarding to the live instance). See
[docs/guide/deep-linking.md](docs/guide/deep-linking.md).

---

## Window control

One unified API across platforms — set initial state in `App_Config` (`min_width`,
`maximized`, `fullscreen`, `always_on_top`, `center`, `hidden`), and drive the
window at runtime from Odin or the frontend.

```odin
hd.window_minimize(app);  hd.window_set_fullscreen(app, true);  hd.window_set_title(app, "…")
```
```js
import { win } from "./heimdall.gen.js"   // built-in `win` service
await win.minimize();  await win.maximize();  await win.close()
```

See [docs/guide/window.md](docs/guide/window.md). (Some ops are best-effort under
Wayland — e.g. `center`/`always_on_top`.)

---

## Paths

One cross-platform API for the OS's per-app directories — config, data, cache, and
log — namespaced by your app and created on first access. No branching on OS.

```odin
cfg := hd.config_dir(app)                          // also data_dir / cache_dir / log_dir
db  := hd.app_path(app, .Data, "db/store.sqlite")  // file path inside it; makes parents
```
```js
import { paths } from "./heimdall.gen.js"   // built-in `paths` service
const dir = (await paths.config()).path
```

Set `app_id` in `App_Config` to name the directories (falls back to a sanitized
`title`). See [docs/guide/paths.md](docs/guide/paths.md).

---

## Build & ship

```sh
heimdall build                     # single binary, assets embedded -> ./myapp
heimdall bundle                    # macOS .app, Linux .deb + .rpm, Windows installer .exe
heimdall bundle --sign --notarize  # Developer ID signing + Apple notarization (macOS)
```

Code signing is needed on macOS/Windows, never on Linux. `heimdall new` scaffolds
a GitHub Actions workflow for signed releases — see [`docs/ci.md`](docs/ci.md).

---

## CLI

| Command | What it does |
| --- | --- |
| `new <name>` | Scaffold a project (`--frontend vanilla\|sveltekit`, `--pm …`, `--add <sv-addon>`). |
| `dev` | Run the dev server + app; reload on change. |
| `build` | Frontend build → embed → compile a release binary. |
| `bundle` | Package the app — macOS `.app` (`--sign`/`--notarize`), Linux `.deb` + `.rpm`, or Windows installer `.exe` + `.zip`. |
| `sign [target]` | Code-sign an app. |
| `generate-bindings` | Emit a typed JS client (`.js`+`.d.ts`) from your command types. |
| `doctor` | Check the toolchain and platform deps. |

---

## Config — `heimdall.toml`

Optional and small. Packaging lives under `[bundle]` / `[sign]`, with per-platform
overrides so you only repeat what actually differs.

```toml
name = "myapp"

[bundle]                              # common to every platform
identifier   = "com.example.myapp"    # required to bundle
version      = "1.0.0"
display_name = "My App"
icon         = "icon.png"             # auto-converted to .icns

[bundle.macos]                        # macOS-only overrides
min_macos = "12.0"

[sign.macos]
identity = "Developer ID Application: Name (TEAMID)"
```

Settings resolve platform-first, then common. Secrets stay out of the file —
signing/notarization credentials come from environment variables.

---

## Status

Runs natively on **macOS** (WKWebView), **Linux** (GTK4 + libadwaita + WebKitGTK),
and **Windows** (WebView2 / COM) — one native backend per platform, no fallback.
Full breakdown, repo layout, and how the tests work:
**[docs/internals.md](docs/internals.md)**.

## Docs

Full docs live in **[`docs/`](docs/guide/getting-started.md)** (a
[VitePress](https://vitepress.dev) site — `bun install && bun run docs:dev`):
[Getting Started](docs/guide/getting-started.md) ·
[Commands](docs/guide/commands.md) ·
[Events](docs/guide/events.md) ·
[Window](docs/guide/window.md) ·
[Paths](docs/guide/paths.md) ·
[Deep linking](docs/guide/deep-linking.md) ·
[Configuration](docs/guide/configuration.md) ·
[Packaging](docs/guide/packaging.md) ·
[CLI](docs/reference/cli.md) ·
[Internals](docs/internals.md).

## License

Heimdall is released under the [MIT License](LICENSE) — © 2026 Galaxoid Labs.
Use it in open-source or commercial apps; the binaries you build are yours.

Vendored third-party components keep their own licenses — notably the Microsoft
WebView2 loader under [`heimdall/webview2/`](heimdall/webview2/).

> "Heimdall" is a working name — find/replace `heimdall` / `Heimdall` / `hd` to
> rename.
