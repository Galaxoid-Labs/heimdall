# Internals

For people working *on* Heimdall (not building apps with it). For the full design
rationale see [`CLAUDE.md`](https://github.com/galaxoid-labs/heimdall/blob/main/CLAUDE.md);
for the phased build plan,
[`DEVELOPMENT.md`](https://github.com/galaxoid-labs/heimdall/blob/main/DEVELOPMENT.md);
for specific decisions and their tradeoffs,
[`DECISIONS.md`](https://github.com/galaxoid-labs/heimdall/blob/main/DECISIONS.md).

## Layout

```
heimdall/
  heimdall/                  # the framework package
    app.odin                 # App, App_Config, lifecycle, create/run/destroy
    service.odin             # service()/command() registration + thunks
    bridge.odin              # request parsing/encoding (backend-agnostic)
    backend.odin             # the Backend vtable + inbound-request flow
    backend_darwin.odin      # native macOS WKWebView implementation (objc interop)
    backend_linux.odin       # native GTK4 + libadwaita + webkitgtk-6.0 backend
    backend_windows.odin     # native WebView2 backend (COM)
    events.odin              # emit() event bus
    threading.odin           # dispatch_main, terminate
    shim.odin                # the injected JS client (window.heimdall)
    schema.odin              # schema-dump mode (reflect -> JSON) for typed bindings
    assets.odin              # Asset type + MIME guessing
    server.odin              # loopback static server (unused fallback seam — see below)
    errors.odin              # the Error union
  cli/                       # the `heimdall` CLI (self-contained, no framework import)
  examples/                  # hello and headless _probe* self-tests
  docs/
  .claude/skills/            # Claude Code skills (heimdall + odin-lang)
```

The `.claude/skills/` are the single source: active when working in this repo,
shipped in `heimdall-framework.tar.gz` (the `framework` release job), and copied
into `<project>/.claude/skills/` by `heimdall new`. To refresh the Odin skill,
replace `.claude/skills/odin-lang/`; the heimdall skill is authored here.

## The backend vtable

The framework only ever talks to `app.backend.*` — a `Backend` struct of procs
(`backend.odin`). This is the seam between the bridge/services/events/user code and
the per-platform native shell: each platform fills in the same vtable.

- **`backend_darwin.odin`** — a hand-written native macOS shell (NSApplication +
  NSWindow + WKWebView + a runtime-registered `WKScriptMessageHandler` +
  `NSWindowDelegate`), via Objective-C interop. The macOS backend. Serves assets
  over a custom `app://`
  `WKURLSchemeHandler` (no loopback server) and enforces `should_quit`.
- **`backend_linux.odin`** — a hand-written native Linux shell on **GTK4 +
  libadwaita + webkitgtk-6.0** (GtkWindow + AdwHeaderBar + WebKitWebView + a
  `WebKitUserContentManager` script-message handler), via plain GObject/C
  `foreign import`. The Linux backend. `adw_init` makes the title bar follow the
  system light/dark theme. Serves
  assets over a custom `app://` scheme (no loopback server), enforces `should_quit`
  via the window `close-request`, and renders the user's menus as a
  `GtkPopoverMenuBar` (GMenu + actions).
- **`backend_windows.odin`** — native WebView2 backend via hand-laid COM vtables.
  Serves assets over a custom `app://` scheme (registered through
  `ICoreWebView2EnvironmentOptions4`), enforces `should_quit` via `WM_CLOSE`,
  renders the user's menus as an `HMENU` (with an accelerator table), and uses
  `DwmSetWindowAttribute` for the modern Win11 title bar (rounded corners +
  immersive dark mode that follows the system theme). See
  [`platform_notes.md`](platform_notes.md).

Two things flow back into the framework: `backend_on_request` (an inbound JS
`invoke`) and the proc handed to `dispatch` (a UI-thread task). Backends translate
their native callbacks into those.

The loopback static server in `server.odin` is now an **unused fallback seam**: a
backend that can't register a custom `app://` scheme would serve prod assets over
it instead. All three current native backends register `app://` directly, so none
of them use it.

## Status

| Area | State |
| --- | --- |
| Bridge: services + `invoke` | ✅ |
| Event bus (`emit`/`on`) + threading | ✅ |
| Asset embed + serving (`app://`) | ✅ |
| Lifecycle hooks, errors, allocator hygiene | ✅ |
| CLI: new/dev/build/bundle/sign/embed/generate-bindings/doctor | ✅ (`dev` watch loop lightly tested) |
| Typed bindings (`generate-bindings`) — commands + events | ✅ |
| Native macOS WKWebView backend | ✅ |
| Native Linux backend (GTK4 + libadwaita + webkitgtk-6.0) | ✅ |
| Native Windows backend (WebView2 / COM) | ✅ |
| Native menus (custom + role + custom-event items; macOS adds App/Edit/Window) | ✅ macOS + Linux + Windows |
| macOS `.app` bundling + code signing + notarization | ✅ (notarization needs a real Apple account to exercise) |
| Windows installer (Inno Setup `.exe`) + portable `.zip` + `signtool` signing | ✅ |
| Deep linking (`myapp://`) — registration + delivery | ✅ macOS full; Win/Linux cold-start (single-instance forwarding ⏳) |
| `.dmg`, AppImage, tray, native dialogs | ⏳ future |

## How verification works

Runtime behavior is checked by headless probes under `examples/_probe*`. Each runs
the bridge from JS on page load, reports results back through a final `invoke`, and
writes a JSON artifact to `/tmp` — so they're CI-checkable without a human clicking.

- `_probe` — invoke round-trip + reject path
- `_probe_events` — events emitted from a worker thread, in order
- `_probe_assets` — asset serving over `app://`
- `_probe_lifecycle` — `on_startup` / `on_shutdown` via `terminate`
- `_probe_alloc` — zero leaks / bad frees under a tracking allocator
- `_probe_window` — every window-control op round-trips
- `_probe_menu` — native menu accelerator → `emit("menu")` → `on("menu")`
- `_probe_deeplink` — cold-start URL queue → `win.__ready` → typed `on("open-url")`
  + the `on_open_url` hook

Plus unit/fuzz tests for the bridge (`heimdall/bridge_test.odin`): ~5,000 random +
hostile JSON inputs through the real inbound path, asserting it never crashes and
always replies exactly once.

```sh
odin test heimdall                          # bridge fuzz/robustness tests
odin run examples/_probe -collection:src=.  # a probe against the platform backend
```

All probes produce identical artifacts on every platform — same user code,
different native shell.

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
- Odin gotchas that bit us (see `DECISIONS.md`): filename suffixes like `_js` are
  build-target gates; `fmt` treats `{` as a token (don't pass literal braces as a
  format); generated map-literal files need `#+feature dynamic-literals`.

## License

Heimdall is [MIT licensed](https://github.com/galaxoid-labs/heimdall/blob/main/LICENSE)
(© 2026 Galaxoid Labs); contributions are accepted under the same license.
Vendored third-party code — e.g. the Microsoft WebView2 loader under
`heimdall/webview2/` — retains its own license.
