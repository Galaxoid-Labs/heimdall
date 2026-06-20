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
- **A two-way bridge.** JS calls Odin and awaits a result (`invoke`); Odin pushes
  events to JS (`emit`/`on`). Plain JSON, both directions.
- **Fast inner loop.** `heimdall dev` rebuilds and relaunches in a blink.

---

## Get started

Needs [Odin](https://odin-lang.org/docs/install/) and a JS runtime —
[Node.js](https://nodejs.org) or [Bun](https://bun.sh) (`heimdall doctor` checks
your setup).

```sh
# Build the CLI. The root `heimdall/` is the framework package, so name the
# binary `heimdall-cli` and put it on PATH as `heimdall`.
odin build cli -out:heimdall-cli -o:speed
install -Dm755 heimdall-cli ~/.local/bin/heimdall

export HEIMDALL_HOME="$PWD"        # lets `new` find the framework to vendor
heimdall new myapp                 # vanilla frontend (or --frontend sveltekit)
cd myapp && heimdall dev           # a window opens, wired to Odin
```

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

## Commands — `invoke`

A **service** is a struct with state; a **command** is a proc over it. The JSON
marshalling is generated from your types at compile time.

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
// Untyped (always available): window.heimdall (alias of window.__HEIMDALL__)
const r = await window.heimdall.invoke("greeting.greet", { name: "Jake" })

// Typed client (generated from your Odin types; auto-kept-fresh by dev/build):
import { greeting } from "./heimdall.gen.js"
const { message } = await greeting.greet({ name: "Jake" })   // -> "Hello, Jake"
// a command that returns an error rejects the promise
```

---

## Events — `emit` / `on`

For the push direction (progress, background work, live updates). Fire-and-forget,
safe to emit from any thread.

```odin
hd.emit(app, "file.progress", Progress{read = 512, total = 1000})
```
```js
import { on } from "./heimdall.gen.js"   // or window.heimdall.on(...)
const off = on("file.progress", p => updateBar(p.read / p.total))
// off()  // unsubscribe
```

Want typed `invoke` in your editor? `heimdall generate-bindings` writes a typed
client (`heimdall.gen.js` + `.d.ts`) from your Odin types — `dev`/`build`
regenerate it automatically. Optional and additive; `window.heimdall.invoke` works
without it.

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
[Configuration](docs/guide/configuration.md) ·
[Packaging](docs/guide/packaging.md) ·
[CLI](docs/reference/cli.md) ·
[Internals](docs/internals.md).

> "Heimdall" is a working name — find/replace `heimdall` / `Heimdall` / `hd` to
> rename.
