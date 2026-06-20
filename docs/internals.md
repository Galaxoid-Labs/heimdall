# Internals

For people working *on* Heimdall (not building apps with it). For the full design
rationale see [`CLAUDE.md`](https://github.com/ismyhc/heimdall/blob/main/CLAUDE.md);
for the phased build plan,
[`DEVELOPMENT.md`](https://github.com/ismyhc/heimdall/blob/main/DEVELOPMENT.md);
for specific decisions and their tradeoffs,
[`DECISIONS.md`](https://github.com/ismyhc/heimdall/blob/main/DECISIONS.md).

## Layout

```
heimdall/
  heimdall/                  # the framework package
    app.odin                 # App, App_Config, lifecycle, create/run/destroy
    service.odin             # service()/command() registration + thunks
    bridge.odin              # request parsing/encoding (backend-agnostic)
    backend.odin             # the Backend vtable + inbound-request flow
    backend_webview.odin     # webview/webview implementation of the vtable
    backend_darwin.odin      # native macOS WKWebView implementation (objc interop)
    backend_linux.odin       # native WebKitGTK scaffold
    backend_windows.odin     # native WebView2 scaffold
    events.odin              # emit() event bus
    threading.odin           # dispatch_main, terminate
    shim.odin                # the injected __HEIMDALL__ JS client(s)
    schema.odin              # schema-dump mode (reflect -> JSON) for typed bindings
    assets.odin              # Asset type + MIME guessing
    server.odin              # loopback static server (prod assets, webview backend)
    errors.odin              # the Error union
    webview/                 # Odin bindings to the vendored webview/webview C lib
  cli/                       # the `heimdall` CLI (self-contained, no framework import)
  examples/                  # hello, smoke, and headless _probe* self-tests
  docs/
```

## The backend vtable

The framework only ever talks to `app.backend.*` — a `Backend` struct of procs
(`backend.odin`). This is the seam that lets the native shell swap out without the
bridge, services, events, or user code changing.

- **`backend_webview.odin`** — the default, over the cross-platform
  [webview/webview](https://github.com/webview/webview) C library. All
  webview-specifics (the C trampolines, the cstring request id) live here.
- **`backend_darwin.odin`** — a hand-written native macOS shell (NSApplication +
  NSWindow + WKWebView + a runtime-registered `WKScriptMessageHandler` +
  `NSWindowDelegate`), via Objective-C interop. Selected with
  the default on macOS (`-define:HEIMDALL_WEBVIEW=true` opts out). Serves assets
  over a custom `app://`
  `WKURLSchemeHandler` (no loopback server) and enforces `should_quit`.
- **`backend_linux.odin` / `backend_windows.odin`** — `#+build`-gated scaffolds
  with implementation notes; not yet wired in. See
  [`platform_notes.md`](platform_notes.md).

Two things flow back into the framework: `backend_on_request` (an inbound JS
`invoke`) and the proc handed to `dispatch` (a UI-thread task). Backends translate
their native callbacks into those.

## Status

| Area | State |
| --- | --- |
| Bridge: services + `invoke` | ✅ |
| Event bus (`emit`/`on`) + threading | ✅ |
| Asset embed + serving (loopback + `app://`) | ✅ |
| Lifecycle hooks, errors, allocator hygiene | ✅ |
| CLI: new/dev/build/bundle/sign/embed/generate-bindings/doctor | ✅ (`dev` watch loop lightly tested) |
| Typed bindings (`generate-bindings`) | ✅ |
| Native macOS WKWebView backend | ✅ |
| Native menus (App/Edit/Window + custom, role + custom-event items) | ✅ macOS |
| macOS `.app` bundling + code signing + notarization | ✅ (notarization needs a real Apple account to exercise) |
| Native Linux (WebKitGTK) / Windows (WebView2) | ⏳ scaffolded |
| Deep linking (`myapp://`), `.dmg`, Windows `signtool` | ⏳ future |

## How verification works

Runtime behavior is checked by headless probes under `examples/_probe*`. Each runs
the bridge from JS on page load, reports results back through a final `invoke`, and
writes a JSON artifact to `/tmp` — so they're CI-checkable without a human clicking.

- `_probe` — invoke round-trip + reject path
- `_probe_events` — events emitted from a worker thread, in order
- `_probe_assets` — asset serving (loopback on webview, `app://` on native)
- `_probe_lifecycle` — `on_startup` / `on_shutdown` via `terminate`
- `_probe_alloc` — zero leaks / bad frees under a tracking allocator

Run one against a backend:

```sh
odin run examples/_probe -collection:src=.                               # native (default on macOS)
odin run examples/_probe -collection:src=. -define:HEIMDALL_WEBVIEW=true  # webview backend
```

All probes produce identical artifacts on both backends — same user code, different
native shell.

## Branding

The mark is the **Bifröst bridge between two pillars** (the Odin and web realms
Heimdall guards) with a watch-point above — it doubles as a runic **H**. Palette:
midnight indigo base + **gold** accent (Heimdall the golden), with a faint
aurora glow / Bifröst ribbon nodding to the rainbow bridge.

- `docs/public/logo.svg` — the mark (gold gradient, transparent; nav + hero).
- `docs/public/favicon.svg` — the mark on a midnight tile (favicon).
- `docs/.vitepress/theme/custom.css` — the color variables and hero glow.

## Keeping docs current

**Docs are updated in the same change as the code.** After any behavior, API,
CLI, or config change, update the relevant pages before the work is done — don't
let the docs drift:

- user-facing changes → `docs/guide/`, `docs/reference/cli.md`, and the root
  `README.md`;
- architecture / backends / status / tests → this file (and
  `platform_notes.md`);
- packaging / signing / CI → `docs/guide/packaging.md`, `docs/ci.md`;
- notable decisions → `DECISIONS.md`.

The docs site is [VitePress](https://vitepress.dev):

```sh
bun install
bun run docs:dev      # local preview at http://localhost:5173
bun run docs:build    # production build — FAILS on dead links, so this also
                      # validates cross-page links
```

`bun run docs:build` is the check to run before committing doc changes. The site
deploys to GitHub Pages via `.github/workflows/docs.yml` (enable in repo Settings
→ Pages → Source: "GitHub Actions").

## Build conventions

- Framework examples build with `-collection:src=.` and import
  `hd "src:heimdall"`. Generated user apps vendor the framework into `./heimdall/`
  and import `hd "heimdall"` (no collection).
- The static `libwebview.a` is committed under `heimdall/webview/lib/`; rebuild it
  from the vendored upstream with `heimdall/webview/lib/build_lib.sh`.
- Odin gotchas that bit us (see `DECISIONS.md`): filename suffixes like `_js` are
  build-target gates; `fmt` treats `{` as a token (don't pass literal braces as a
  format); generated map-literal files need `#+feature dynamic-literals`.
