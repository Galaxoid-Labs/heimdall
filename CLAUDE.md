# Heimdall — CLAUDE.md

> **Working name: `heimdall`.** Heimdall is the watchman who guards the Bifröst
> bridge — fitting for the thing that brokers every message between Odin and the
> web layer, and it ties cleanly to your existing **Bifrost** webview work. The
> name is a placeholder: to rename, find/replace `heimdall` / `Heimdall` /
> `hd` across the repo. (Alternates considered: Ratatoskr — but that's already a
> subsystem name inside Vör — Gjallarhorn, Bifrost-successor.)

A **lightweight Tauri**, in Odin. Users write their backend in Odin and their UI
in whatever web stack they like; Heimdall wires the two together, embeds the
frontend into a single native binary, and ships it. No Rust, no Cargo, no
`tauri.conf.json` sprawl, sub-second iteration.

This file is the project bible for Claude Code. Read it before touching anything.
Architecture-first: understand the three layers and the bridge contract before
writing a line. **The phased build plan, task checklists, and sequencing live in
`DEVELOPMENT.md`** — this file is the *what/why*, that one is the *how/when*.

---

## Status

**The MVP is built and working on macOS and Linux.** Design informed by **Wails v3** (we
lifted its service model, event bus, binding-gen strategy, and lifecycle hooks).

Done & verified (see `DECISIONS.md` for the full log, `docs/internals.md` for the
status table, headless self-tests under `examples/_probe*`):

- IPC bridge — services + `invoke` (JSON, compile-time-generated marshalling).
- Event bus — `emit` (Odin) / `on` (JS), thread-safe.
- Asset embed + serving — loopback server (webview backend) **and** a real
  `app://` `WKURLSchemeHandler` (native backend).
- Lifecycle hooks — `on_startup`, `on_shutdown`, `should_quit` (enforced natively).
- `heimdall` CLI — `new`, `dev`, `build`, `bundle`, `sign`, `embed`,
  `generate-bindings`, `doctor`, `docs`.
- Typed bindings — `generate-bindings` schema-dump → `.d.ts`.
- **Backend vtable** (`backend.odin`) — the seam every backend implements.
- **Native macOS WKWebView backend** (`backend_darwin.odin`, objc interop) — the
  **default** on macOS (`-define:HEIMDALL_WEBVIEW=true` opts out). Includes
  native menus (`menu.odin` + App_Config.menu).
- **Native Linux backend on GTK4 + libadwaita + webkitgtk-6.0**
  (`backend_linux.odin`, GObject/C interop) — the **default** on Linux. AdwHeaderBar
  title bar that follows the system light/dark theme (`adw_init`), custom `app://`
  scheme, `GtkPopoverMenuBar` menus, `should_quit` via `close-request`. All
  `_probe*` pass identically to macOS.
- macOS `.app` bundling + code signing + notarization + a reusable CI action.
- Docs site (VitePress, `docs/`) + branding.

### ► PICK UP HERE — next: native **Windows** backend (WebView2, COM)

macOS and Linux native backends are done. Windows (WebView2 via COM) is the last
and most tedious: hand-lay vtable structs, call through fn-ptrs, and **implement**
the completion/event-handler interfaces (vtable + QueryInterface + refcount).
Implement `heimdall/backend_windows.odin` against the `Backend` vtable
(`backend.odin`), using `backend_darwin.odin`/`backend_linux.odin` as references
and the **Windows section of `docs/platform_notes.md`** for the COM/WebView2 API
mapping. Wire it into `app.odin` selection
(`when ODIN_OS == .Windows && !HEIMDALL_WEBVIEW`) and verify with the probes
(`odin build examples/_probe -collection:src=.`; all `_probe*` should pass like
they do on macOS/Linux). The webview/webview backend is the fallback until then.

---

## Philosophy

- **Bring your own bundler.** We do not ship Node, npm, Vite, or a blessed
  framework. The user's frontend is a folder of static files (`dist/`). Whether
  that came from Vite, esbuild, SvelteKit's static adapter, or hand-written HTML
  is none of our business. This is the single most important scoping decision —
  it keeps Heimdall small and keeps us out of the JS toolchain treadmill.
- **The binary is the deliverable.** Frontend assets are embedded at compile time
  via `#load`. A shipped app is one executable with everything inside it. No
  sidecar `resources/` directory, no installer gymnastics.
- **The bridge is dumb on purpose.** Receive JSON, call an Odin proc, send JSON
  back. No async/await ceremony, no trait machinery. If you can describe it in
  one sentence, the implementation should be nearly that simple.
- **Honest about Odin.** Odin has no user-defined attributes with runtime
  reflection (no `@(my_custom_tag)` you can enumerate), and no proc-macros. So we
  do **not** fake Tauri's `#[command]` macro. Commands are registered with a
  parametric-polymorphic `command()` call that generates the JSON marshalling
  glue at compile time from the handler's own argument/return types. Type-safe,
  idiomatic, no magic the compiler will reject. Typed TS definitions come from a
  **schema-dump mode** that uses Odin's real RTTI (`core:reflect`) — see Binding
  Generation. This sidesteps the chicken-and-egg mess Wails v2 had.
- **Two directions, two mechanisms.** Request/response is `invoke` (JS asks Odin,
  awaits a result). Push is the **event bus** (`emit` from Odin, `on` in JS) for
  progress, background work, and state sync. Don't conflate them.
- **Fast inner loop.** `heimdall dev` should rebuild and relaunch in the time it
  takes Tauri to think about it. This is the main reason to do this in Odin.

---

## Mental model — three layers

```
┌─────────────────────────────────────────────────────┐
│  WEB LAYER  (user's frontend — any stack)            │
│    invoke("greeting.greet", {name}) ─postMessage─┐   │
│    on("file.progress", handler)  ◄──── eval ─────┼─┐ │
│    window.__HEIMDALL__ client (small JS shim)    │ │ │
└──────────────────────────────────────────────────┼─┼─┘
                                  request │ JSON    │ │ event
┌──────────────────────────────────────────▼────────┼─▼─┐
│  BRIDGE  (Odin)                                    │   │
│    dispatch(name,json) → unmarshal → handler       │   │
│                        → marshal  → eval _resolve ─┘   │
│    emit(name, payload) → queue → eval _event ─────────┘│
│    runs ON the UI thread; off-thread work marshals back│
└────────────────────────────────────────────┬──────────┘
                                              │
┌─────────────────────────────────────────────▼────────┐
│  NATIVE SHELL  (Odin + platform glue)                 │
│    Webview (WKWebView / WebKitGTK / WebView2)         │
│    Window · Menu · Tray (tray-odin) · Dialogs         │
│    Lifecycle: on_startup · on_shutdown · should_quit  │
│    app:// scheme handler → embedded asset tree         │
└──────────────────────────────────────────────────────┘
```

Web never touches the OS directly. Everything privileged goes through a
registered command. That boundary is the whole security/architecture story.

---

## Architecture

### Native shell

A thin per-platform layer behind one Odin interface. The public surface the user
sees is platform-agnostic:

```odin
App        :: struct { /* opaque; holds webview, window, service registry, event bus, ... */ }
App_Config :: struct {
    title:        string,
    width, height:int,
    resizable:    bool,
    dev_url:      string,  // e.g. "http://localhost:5173" — used only in dev builds
    icon:         []u8,    // embedded PNG

    // Initial window state (optional; best-effort per platform — center/always_on_top
    // are no-ops under Wayland). min_width/min_height, maximized, fullscreen,
    // always_on_top, center, hidden.
    min_width, min_height: int,
    maximized, fullscreen, always_on_top, center, hidden: bool,

    // Lifecycle hooks (all optional; nil == skip)
    on_startup:   proc(app: ^App) -> Error, // after webview init, before frontend loads
    on_shutdown:  proc(app: ^App),          // on close; clean up here
    should_quit:  proc(app: ^App) -> bool,  // return false to veto a quit/close
}

create  :: proc(cfg: App_Config) -> (^App, Error)
run     :: proc(app: ^App)                  // blocks; runs the platform event loop
destroy :: proc(app: ^App)

// Unified window control — one API, platform switch under the backend vtable
// (Backend.window_op). Also exposed to JS via the built-in reserved `win` service
// (invoke("win.minimize") / generated `win.minimize()`).
window_minimize/maximize/unmaximize/show/hide/focus/center/close :: proc(app: ^App)
window_set_fullscreen :: proc(app: ^App, on: bool)
window_set_title :: proc(app: ^App, title: string)
window_set_size  :: proc(app: ^App, width, height: int)
```

Internally, dispatch on `ODIN_OS` with `when`:

```odin
when ODIN_OS == .Darwin  { /* WKWebView via objc interop */ }
when ODIN_OS == .Linux   { /* WebKitGTK via foreign import C */ }
when ODIN_OS == .Windows { /* WebView2 via COM vtables */ }
```

Keep each backend in its own file (`backend_darwin.odin`, `backend_linux.odin`,
`backend_windows.odin`) gated by build-tag/`when`, all implementing the same
small internal vtable: `webview_create`, `webview_navigate`, `webview_eval`,
`webview_set_title`, `webview_on_message`, `run_loop`, `dispatch_main`.

### Webview backends

| Platform | API        | Binding approach                                   | Difficulty |
| -------- | ---------- | -------------------------------------------------- | ---------- |
| Linux    | WebKitGTK  | `foreign import` against `webkitgtk-6.0` (GTK4) + `libadwaita-1`; plain C / GObject | easy       |
| macOS    | WKWebView  | Odin Objective-C interop (`@(objc_class)`, `objc_send`) — same machinery as the Metal vendor bindings | medium     |
| Windows  | WebView2   | COM: hand-lay vtable structs, call through fn-ptrs, **implement** the completion/event handler interfaces yourself (vtable + QueryInterface + refcount) | tedious    |

Message channel per platform (this is how JS→Odin works):

- **WebKit / WebKitGTK:** `window.webkit.messageHandlers.<name>.postMessage(...)`,
  received via a registered script message handler.
- **WebView2:** `window.chrome.webview.postMessage(...)`, received via
  `add_WebMessageReceived`.

Odin→JS is always "evaluate this JS string in the page": `evaluateJavaScript:` /
`webkit_web_view_evaluate_javascript` / `ExecuteScript`. The bridge uses that to
resolve the JS-side promise (see below).

> **Bootstrap decision (see DEVELOPMENT.md).** We start on the tiny
> `webview/webview` C library rather than three hand-written native backends,
> because its `webview_bind`/`webview_return` already gives us the request/response
> path, `webview_init` injects our shim, `webview_eval` pushes events, and
> `webview_dispatch` is `dispatch_main`. We keep the internal backend vtable so
> native backends (for menus, tray, and a real `app://` scheme) can slot in later
> without changing the bridge or user code. The one early gap: webview/webview has
> no custom-scheme handler, so prod assets are served over a loopback HTTP server
> instead of `app://` until the native phase. Bifrost's backend may be vendorable
> when we get there.

### IPC bridge — services & commands

Commands are grouped under **services**: a named namespace backed by an Odin
struct that can hold state. This is lifted from Wails v3 and keeps real apps
organized — the service struct is a mini-backend, not just a static namespace.

**The contract.** A command is an Odin proc taking `(^Service, Args)` and
returning `(Result, Error)`, where `Args`/`Result` are JSON-marshalable Odin
types (or `()`):

```odin
import "core:encoding/json"

Greeting :: struct { prefix: string }                 // service state

Greet_Args   :: struct { name: string }
Greet_Result :: struct { message: string }

greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, Error) {
    return { message = fmt.tprintf("%s%s", s.prefix, args.name) }, nil
}
```

**Registration is parametric** — `command` is polymorphic over the service and
the handler's own arg/result types, so it generates the unmarshal/marshal glue at
compile time with no custom-attribute reflection:

```odin
service :: proc(app: ^App, name: string, state: ^$S) -> Service_Handle
command :: proc(svc: Service_Handle, name: string,
                handler: proc(s: ^$S, args: $A) -> ($R, Error))
```

Internally each command is a type-erased thunk keyed by `"service.command"`:
`raw_json -> json.unmarshal(into A) -> handler(state, A) -> json.marshal(R) -> raw_json`,
stored in the app's registry (`map[string]Thunk`).

Wiring an app:

```odin
main :: proc() {
    app, err := heimdall.create({
        title = "Demo", width = 900, height = 600,
        on_startup = on_startup, on_shutdown = on_shutdown,
    })
    if err != nil { /* ... */ }
    defer heimdall.destroy(app)

    greeting := Greeting{ prefix = "Hello, " }
    files    := File_Service{}

    g := heimdall.service(app, "greeting", &greeting)
    heimdall.command(g, "greet", greet)

    f := heimdall.service(app, "files", &files)
    heimdall.command(f, "read_file", read_file)

    heimdall.run(app)
}
```

**JS side** is a small shim injected before the page loads, exposed as
`window.__HEIMDALL__` with `invoke` (request/response) and `on` (events):

```js
const msg = await invoke("greeting.greet", { name: "Jake" });
// invoke("service.command", args) -> Promise:
//   generate an id, stash {resolve,reject} in a pending map,
//   postMessage({ id, name, args }),
//   Odin runs the command, then eval()s:
//     window.__HEIMDALL__._resolve(id, result)  // or _reject(id, errStr)
```

So the round trip is: `invoke` → postMessage → Odin dispatch → handler →
`eval("__HEIMDALL__._resolve(id, …)")` → promise resolves. One pending-map, one
id counter. That's the entire request/response path.

**Dev vs prod URL.** In a dev build the webview points at `dev_url`
(`http://localhost:5173`) so the user gets their bundler's HMR. In a release
build it points at `app://localhost/index.html` served from embedded assets. This
mirrors Tauri exactly and is the key DX win. Switch via build flag
(`-define:HEIMDALL_DEV=true`) or config.

### Threading

Webview callbacks fire on the **UI thread**, and `eval` must run there too. Any
command that does real work off-thread must marshal its result back before
touching the webview:

```odin
dispatch_main :: proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr)
```

Backends implement this with the platform's main-thread dispatch
(`dispatch_async(dispatch_get_main_queue())` on macOS, `g_idle_add` on GTK,
`PostMessage` to the UI window on Windows). The rule for handlers: **never call
`eval`/resolve from a worker thread — always hop through `dispatch_main` first.**
Document this loudly; it's the easiest thing to get subtly wrong.

### Events (pub/sub)

`invoke` is request/response. The **event bus** is the push direction — Odin
emitting to JS without being asked. Use for progress, background-task completion,
multi-window state sync. (Wails has this; our original design didn't — it's a
real gap to close.)

```odin
// Odin: emit with any JSON-marshalable payload
Progress :: struct { read, total: int }
heimdall.emit(app, "file.progress", Progress{ read = 512, total = 1000 })
```

```js
// JS: subscribe; returns an unsubscribe fn
const off = on("file.progress", (p) => updateBar(p.read, p.total));
// later: off()
```

**Implementation.** `emit` marshals the payload and pushes `{name, payload}` onto
an event queue. The UI-thread loop drains it and `eval`s
`__HEIMDALL__._event(name, payload)`, which fans out to registered `on` handlers.
Same UI-thread rule as the bridge: emitting from a worker thread must hop through
`dispatch_main`. Events are fire-and-forget — no ack, no return value. (Later: a
typed event registry so emitted payload types land in the generated `.d.ts`.)

### Binding generation (typed JS) — decided

The goal: typed `invoke`/`on` on the JS side via generated `.d.ts`, **without**
forcing it (untyped `invoke` must keep working).

Wails v2 did this with a runtime-reflection hack: build with a special flag, run
the binary so reflection could discover bindings, then generate — a chicken-and-egg
where you couldn't build without bindings or generate them without building. v3
moved to a static source analyzer. We take the cleaner-for-Odin middle path:

**`heimdall generate-bindings` runs the app in schema-dump mode.** A
`-define:HEIMDALL_SCHEMA=true` build, on `run`, instead of opening a window:

1. initializes services (so the registry is populated),
2. walks the registry; for each command, reads the `Args`/`Result` **typeids**
   captured at registration and introspects them via `core:reflect`
   (`struct_field_names` / `struct_field_types` / `struct_field_tags`),
3. emits a JSON schema of services → commands → field types,
4. the CLI turns that schema into `.d.ts`,
5. exits.

Why this works in Odin where the Wails v2 approach was painful: Odin has real RTTI
(`core:reflect`, `type_info_of`), the same machinery `core:encoding/json` already
uses to marshal — so the types we serialize and the types we document come from
one source of truth. And there's no chicken-and-egg here: untyped `invoke` works
the moment a command is registered; the `.d.ts` is purely additive.

> Alternative considered: static-parse the source with `core:odin/parser` (like
> Wails v3). Rejected for MVP — heavier to vendor than reusing the RTTI we already
> have at registration time.

### Asset embedding + `app://` scheme

Production assets are baked in. The CLI's `embed` step turns a `dist/` tree into
a generated Odin file:

```odin
// generated: assets_gen.odin
ASSETS := map[string]Asset {
    "index.html"      = { data = #load("dist/index.html"),     mime = "text/html" },
    "assets/app.js"   = { data = #load("dist/assets/app.js"),  mime = "text/javascript" },
    // ...
}
```

The scheme handler resolves `app://localhost/<path>` against `ASSETS`, returning
bytes + MIME. Serving from a custom scheme (not `file://`) sidesteps CORS/origin
headaches and gives a stable origin for `fetch`. Each backend registers it:
`WKURLSchemeHandler` / `webkit_web_context_register_uri_scheme` /
`AddWebResourceRequestedFilter` + `WebResourceRequested`.

### Window, menus, tray, dialogs

Thin native wrappers, all optional:

- **Menus:** `NSMenu` (macOS) / GTK menu / Win32 menus.
- **Tray:** reuse **tray-odin** (already cross-platform: macOS/Windows/Linux).
- **Dialogs:** native file open/save + message boxes per platform.

Keep these as separate, importable modules so a minimal app pays for none of them.

---

## The `heimdall` CLI

A single Odin binary. This is the user's primary touchpoint — make it pleasant.

| Command                         | What it does                                                                 |
| ------------------------------- | --------------------------------------------------------------------------- |
| `heimdall new <name>`           | Scaffold a project (`--frontend vanilla\|sveltekit`, `--pm bun\|npm\|pnpm\|yarn\|deno`). Wires the bridge, JS client + typed bindings, example command, vendored framework, CI. |
| `heimdall dev`                  | Start the frontend dev server (configurable cmd, default `bun run dev`), build the Odin app with `HEIMDALL_DEV=true`, launch pointing at the dev URL. Rebuild + relaunch Odin on change. |
| `heimdall build`                | Run the frontend build (`npm run build`), `embed` the output, compile Odin `-o:speed`, emit the final binary. Package with `heimdall bundle`. |
| `heimdall embed <dir> <out>`    | Standalone asset-embed step → generated `.odin`. Composable; `build` calls it. |
| `heimdall generate-bindings`    | Run the app in schema-dump mode (`core:reflect` over the service registry) and emit `.d.ts` for typed `invoke`/`on`. Optional — untyped `invoke` works without it. |
| `heimdall bundle`               | Platform packaging: macOS `.app` (sign/notarize) and Linux `.deb` + `.rpm` (Windows `.exe` later). |
| `heimdall doctor`               | Check toolchain: `odin` present, `node`/bundler present, platform webview deps (WebKitGTK headers, WebView2 runtime, Xcode CLT). Print actionable fixes. |

`new` flow target: **clone template → `cd` → `npm install` → `heimdall dev` →
window opens with a working `invoke` round-trip, in under a couple minutes.**

---

## Repo layout (the framework)

```
heimdall/
  heimdall/                 # the importable library package
    app.odin                # App, App_Config, lifecycle, create/run/destroy
    service.odin            # service() + command() registration, registry, thunks
    bridge.odin             # invoke dispatch, marshalling
    events.odin             # emit() + event queue; on() handler registry (JS side in shim)
    bridge_js.odin          # the injected __HEIMDALL__ JS shim (string const)
    schema.odin             # schema-dump mode: reflect over registry → JSON
    assets.odin             # Asset type, scheme-handler-facing lookup
    threading.odin          # dispatch_main + helpers
    errors.odin             # Error union
    backend_darwin.odin     # WKWebView (objc interop)
    backend_linux.odin      # GTK4 + libadwaita + webkitgtk-6.0 (foreign import)
    backend_windows.odin    # WebView2 (COM)  [last]
    menu/                   # optional native menus
    dialog/                 # optional native dialogs
  cli/                      # the `heimdall` CLI binary
    main.odin
    cmd_new.odin
    cmd_dev.odin
    cmd_build.odin
    cmd_embed.odin
    cmd_generate_bindings.odin
    cmd_doctor.odin
    templates/              # embedded starter templates (vanilla/svelte/react)
  examples/
    hello/                  # minimal: one service, one command, one button
    filebrowser/            # dialogs + fs service + progress events + a real-ish UI
  docs/
    architecture.md
    bridge_contract.md      # services, commands, invoke
    events_guide.md         # emit/on pub-sub patterns
    binding_generation.md   # schema-dump → .d.ts
    platform_notes.md       # objc / COM / WebKitGTK gotchas
  CLAUDE.md                 # this file
```

## Generated user app layout (`heimdall new`)

```
myapp/
  main.odin                 # package main;  import hd "heimdall"
  services.odin             # package main — user's service structs + command procs
  assets_gen.odin           # generated by `embed` (gitignored)
  heimdall/                 # vendored framework package (imported as ./heimdall subdir)
  web/                      # frontend (any stack); produces web/dist
    package.json
    src/heimdall.gen.{js,d.ts}  # typed client from `generate-bindings` (optional, gitignored)
    src/...
  heimdall.toml             # optional: title, size, icon, dev/build cmds
  build.sh                  # one-shot: npm build → heimdall embed → odin build
```

The user's Odin is the **root package** (no `src/` folder — in Odin the directory
name is the import name, so `src` is a bad package name). The framework is vendored
as the `./heimdall/` subdirectory and imported with `import hd "heimdall"` — no
collection flag, no `..`. (Larger apps can move the backend into a named folder and
use a `-collection` instead; the CLI injects the flag. Default template stays
collection-free.) Note: `web/src/` above is the *frontend's* source — that's the JS
bundler's convention, not an Odin package.

Keep `heimdall.toml` tiny — title, window size, icon path, `dev_cmd`,
`build_cmd`, `dist_dir`. Resist the urge to grow a config zoo.

---

## Build & toolchain

```
odin build cli -out:heimdall-cli -o:speed    # build the CLI (root `heimdall/` is the framework pkg)
odin run examples/hello                        # run an example directly
odin test heimdall                             # library tests
```

User app, under the hood of `heimdall build`:

```
(cd web && npm run build)                      # → web/dist
heimdall embed web/dist ./assets_gen.odin
odin build . -out:myapp -o:speed               # root package
```

Platform link deps (document in `doctor`):

- **Linux:** GTK4 + libadwaita + the GTK4 WebKit port — `webkitgtk-6.0`,
  `libadwaita-1`, `gtk4` dev packages.
- **macOS:** link `WebKit`, `Cocoa` frameworks; Xcode command-line tools.
- **Windows:** WebView2 loader (`WebView2Loader.dll`) + runtime; the Evergreen
  runtime ships on current Windows but verify in `doctor`.

---

## Odin conventions

- **`core:os` is the redesigned package** (dev-2026-03+): allocating procs take an
  explicit allocator (`os.read_entire_file(path, context.allocator)`), file
  handles are `^os.File`, errors are the `os.Error` union — check `err != nil`,
  not `ERROR_NONE`. Don't write against the old `core:os/old` API.
- **Errors:** a single `Error` union of enums for the library
  (`Bridge_Error`, `Webview_Error`, `Io_Error`, …). Propagate with `or_return`.
  Commands return `(Result, Error)`; `nil` Error == success.
- **No methods.** Procedures over data: `webview_navigate(wv, url)`, not
  `wv.navigate(url)`. Constructors are `create`/`init`, teardown `destroy`.
- **Foreign bindings** live in their backend file behind `when ODIN_OS == …`.
  C bindings via `foreign import` + `@(link_name=...)`; macOS via the objc
  interop attributes; never leak platform types into the public API.
- **Allocators:** the bridge hot path should avoid per-call heap churn where
  possible — prefer `context.temp_allocator` for transient JSON buffers and free
  per frame/message. Ship a tracking-allocator path in debug to catch leaks.
- **`@(require_results)`** on anything returning an Error or a handle.

---

## Roadmap / explicitly out of scope (for now)

In scope, later:

- Windows/WebView2 backend (after macOS+Linux).
- Typed **event** payloads in the generated `.d.ts` (commands are covered in MVP;
  events get typed signatures in a second pass).
- `bundle`: Windows `.exe` packaging (macOS `.app` + Linux `.deb`/`.rpm` done);
  AppImage; icons; more code-signing hooks.
- Auto-updater, multi-window, plugin registry.

(Services, the event bus, lifecycle hooks, and `generate-bindings` for commands
are **MVP**, not deferred — see Status.)

Out of scope (by design — keeps us lightweight):

- Shipping a bundled Node/npm or a mandated frontend framework.
- A `tauri.conf.json`-style mega-config.
- A native plugin marketplace. People can fork and extend.

---

## Decisions (from the Wails review) & remaining open questions

Decided:

1. **Services + invoke namespacing** — commands live under named, stateful
   services; JS calls `invoke("service.command", args)`. ✅
2. **Event bus** — `emit` (Odin) / `on` (JS), fire-and-forget, separate from
   `invoke`. ✅
3. **Binding generation** — schema-dump mode via `core:reflect`, optional, additive
   to untyped `invoke`. ✅
4. **Lifecycle hooks** — `on_startup` / `on_shutdown` / `should_quit` on
   `App_Config`. ✅

Still open:

5. **Relationship to Bifrost:** clean rewrite, or vendor Bifrost's existing
   backend abstraction when we reach the native-backend phase?
6. **Template frontends in `new`:** proposed vanilla (dependency-free, so
   `doctor`/`dev` works with zero npm) + one Svelte + one React. Confirm the set.
7. **Typed events:** ship typed event payloads in `.d.ts` for v1, or commands-only
   first and events in a second pass?

(Backend bootstrap is now decided — start on `webview/webview`, see DEVELOPMENT.md.)
