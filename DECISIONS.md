# Heimdall — Decisions Log

Decisions made during the build that aren't already settled in `CLAUDE.md` /
`DEVELOPMENT.md`. The user delegated these ("make them for me and note them").
Each entry: what was decided, why, and how to revisit.

---

## D1 — Vendoring webview/webview: build from source, commit the artifact

**Decided:** Vendor upstream `webview/webview` @ `0.12.0`
(commit `cbbdee44afff22867de9fd88a9fc8350d9bdd399`) into
`heimdall/webview/lib/upstream/` (header tree + `webview.cc` + LICENSE), build
`libwebview.a` from it, and commit the built `.a` alongside a
`lib/build_lib.sh` that reproduces it.

**Why:** No package manager in Odin → vendoring is idiomatic. Committing the
built `.a` means `git clone && odin build` works with no C++ build step for the
common case; the source + script are there for other arches / rebuilds.

**Revisit:** If the committed `.a` gets stale or we need universal/arm64+x86_64
binaries, regenerate via `build_lib.sh`. Bump the pinned commit in
`lib/upstream/VENDOR.txt`.

## D2 — C API binding corrections vs. the DEVELOPMENT.md sketch

**Decided:** In `webview.odin`, nearly every entry point returns
`webview_error_t` (bound as `Error`), not `void`/`Webview` as the doc sketch
showed. The bind callback is `proc "c" (id, req, arg)` (the doc said
`(seq, req, arg)`); `webview_return` is bound as `resolve(w, id, status, result)`.

**Why:** Matches the real 0.12.0 C API (`core/include/webview/api.h`). The
sketch in DEVELOPMENT.md predates pinning the version.

**Revisit:** None — this is just fidelity to upstream.

## D3 — Framework examples build with a collection; user apps stay collection-free

**Decided:** Examples in *this repo* build with `-collection:src=.` and import
the framework as `import hd "src:heimdall"` / `import wv "src:heimdall/webview"`.
Generated *user apps* keep the CLAUDE.md design: vendored `./heimdall/` subdir,
`import hd "heimdall"`, no collection.

**Why:** Odin disallows `..` in import paths, and repo examples live in
`examples/<name>/` (siblings of `heimdall/`), so a relative import can't reach
the framework. A collection rooted at the repo is the clean fix and doesn't
affect the user-facing convention. Within the framework, `package heimdall`
imports its `webview/` subpackage by plain relative `import "webview"`.

**Revisit:** None expected.

## D4 — Linux/Windows backends stubbed behind `when ODIN_OS`

**Decided:** `webview.odin` has Linux and Windows `foreign import` branches in
place but only the macOS branch is exercised/tested. The non-macOS branches are
only type-checked when building on those OSes, so they don't block macOS work;
their `libwebview.a`/`.lib` are not built yet.

**Why:** User asked to focus on macOS but keep Linux/Windows stubbed so the
structure exists and doesn't rot. `build_lib.sh` already has the Linux path;
Windows is Phase 7 territory.

**Revisit:** When we do the Linux pass: run `build_lib.sh` on Linux, add the
WebKitGTK pkg-config libs to the Linux `foreign import` block.

## D5 — `bridge_js.odin` renamed to `shim.odin` (Odin filename-suffix trap)

**Decided:** The JS shim const lives in `heimdall/shim.odin`, NOT the
`bridge_js.odin` name the DEVELOPMENT.md layout suggested.

**Why:** Odin uses trailing filename segments as build targets:
`name_<platform>.odin` / `name_<arch>.odin`. `js` is a valid target OS
(`ODIN_OS == .JS`, the WASM/JS backend), so a file named `*_js.odin` is compiled
*only* for the JS target and silently excluded everywhere else. `bridge_js.odin`
therefore vanished on macOS and `SHIM_JS` was "undeclared". Renaming to
`shim.odin` fixes it. (General rule for this repo: never end an Odin filename in
`_js`, `_wasm`, `_darwin`, `_linux`, `_windows`, etc., unless you mean the target
gate.)

**Revisit:** None — and update DEVELOPMENT.md's layout if we touch it.

## D6 — Headless probe harness + bun for frontend tooling

**Decided:** Bridge/runtime behavior is verified with a `examples/_probe/`
target: JS runs `invoke` on page load and reports results back through a final
`invoke` to an Odin handler that writes `/tmp/heimdall_probe.json` and exits.
This gives CI-checkable, click-free verification of the full round-trip. The
`_probe` prefix marks it as a test fixture, not a user-facing example.

For frontend tooling (templates, `dev`/`build` in Phase 5) we use **bun**
(installed, on PATH) per the root CLAUDE.md, not npm/node. Default template dev
command will be `bun run dev`, build `bun run build`.

**Revisit:** None.

## D7 — Prod asset serving: blocking core:net on a background thread

**Decided:** `server.odin` serves embedded assets over a loopback HTTP server
(`http://127.0.0.1:<random-free-port>`) using blocking `core:net` on one
dedicated background OS thread (accept loop, one response per connection,
SPA fallback to index.html for extension-less paths). Considered the `nbio`
async package; rejected for now.

**Why:** Connections are short-lived loopback requests over a read-only embedded
map. A thread-per-server with blocking accept is simpler, adds zero vendored
deps, and keeps an async event loop from tangling with the webview UI loop.
This is itself a stopgap: webview/webview has no custom-scheme handler, so we
use loopback instead of `app://` until the native backends (Phase 7).

**Revisit:** If we need many concurrent connections without a thread, or want to
fold IO into one loop, switch to `nbio`. The whole server goes away once `app://`
lands in Phase 7.

## D8 — should_quit veto deferred to Phase 7; hook timing fixed

**Decided:** `on_startup` runs in `run()` before navigation (a non-nil Error
aborts the run); `on_shutdown` runs after `wv.run()` returns (loop exit).
`should_quit` (veto a close) is kept on `App_Config` but is NOT enforced on the
bootstrap backend.

**Why:** webview/webview's C API exposes no window-close intercept, so there's no
event from which to call `should_quit` and cancel the close. That requires owning
the native window delegate (NSWindowDelegate `windowShouldClose:` on macOS),
which is the native-backend phase. Startup/shutdown need no such hook and work
now.

**Revisit:** Wire `should_quit` when the native macOS backend lands (Phase 7).

## D9 — Bridge/callbacks capture the caller's context

**Decided:** `create` stores `app.ctx = context` (the caller's context), not
`runtime.default_context()`. All FFI callbacks restore `app.ctx`.

**Why:** So a tracking allocator (or custom logger/allocator) set up in `main`
before `create` is also in effect inside the bridge/event/dispatch callbacks,
making leaks across the FFI boundary visible. Verified: `_probe_alloc` reports
0 leaks / 0 bad frees after 5 invoke round-trips + create/destroy.

**Revisit:** None.

## D10 — CLI is self-contained; `new` vendors the framework via a copy

**Decided:** The `cli/` package imports NOTHING from `heimdall/` (it duplicates
the small `Schema` structs in `cli/dts.odin`). `heimdall new` vendors the
framework by `cp -R`'ing a framework directory resolved from `--framework`, else
`$HEIMDALL_HOME/heimdall`, else error.

**Why:** Importing `heimdall` into the CLI would drag in the webview/webview
link deps (WebKit/Cocoa) for a tool that never opens a window. Keeping the CLI
free of native deps makes it a clean, portable binary. A shipped CLI would embed
the framework source; for now the `--framework`/`HEIMDALL_HOME` indirection is
the MVP path (noted as a follow-up to bake the template in).

**Revisit:** Bake the framework into the CLI binary (embedded template) so `new`
needs no external path.

## D11 — `new` templating uses token replacement, not fmt

**Decided:** Templates in `cmd_new.odin` use `__NAME__` / `__TITLE__` tokens
replaced via `strings.replace_all`, NOT `fmt.tprintf` verbs.

**Why:** Odin's `fmt` treats `{` as a format token (and `%` as a verb). Template
files are full of literal braces (Odin struct literals, JSON) and would be
mangled (`%!(MISSING CLOSE BRACE)`). Same gotcha bit the `.d.ts` generator — that
line is built with `strings.write_string` instead of a format string. General
rule: never run text containing `{`/`%` through Odin `fmt` as the format arg.

**Revisit:** None.

## D12 — Generated asset files carry `#+feature dynamic-literals`

**Decided:** Both generated files (`assets_gen.odin` from `embed`, and the dev
stub) start with `#+feature dynamic-literals`.

**Why:** Odin disables map/dynamic-array compound literals by default; the
generated `ASSETS := map[string]hd.Asset{...}` needs the per-file opt-in.

**Revisit:** None.

## D13 — `dev` writes a stub `assets_gen.odin` so dev builds compile

**Decided:** `heimdall dev` writes an empty-`ASSETS` `assets_gen.odin` if none
exists, before building.

**Why:** The template `main.odin` references `ASSETS` unconditionally (clean
user code, no `when` noise), but `ASSETS` only exists after `embed`. Dev uses
`dev_url` and ignores assets, so an empty stub is correct and lets dev builds
compile without a prior `build`.

**Revisit:** None.

## NOTE — `dev` watch loop is the least-verified command

The `new`/`build`/`embed`/`generate-bindings`/`doctor` commands are verified
end-to-end (scaffold → build → runnable binary that serves its embedded SPA over
loopback). `dev`'s build+launch path shares code with `build` and compiles, but
its live file-watch/relaunch loop and the frontend-dev-server lifecycle were not
exercised headlessly. Flagged for a manual pass.

## D14 — Phase 7: backend vtable seam implemented + proven; native impls stubbed

**Decided:** Phase 7's deliverable this pass is the **internal backend vtable**
(`backend.odin`), with the webview/webview implementation moved behind it
(`backend_webview.odin`) and the framework (`app`/`events`/`threading`/bridge)
refactored to call only `app.backend.*`. The three native backends
(`backend_darwin/linux/windows.odin`) are `#+build`-gated scaffolds with precise
implementation notes, NOT wired into `create`.

**Why:** A full, correct, *verified* hand-written WKWebView (objc) / WebKitGTK /
WebView2 (COM) backend is a multi-session effort; shipping unverified native
interop would be worse than shipping a proven seam. The vtable is the thing
DEVELOPMENT.md actually requires ("native backends slot in without touching the
bridge or user code"), and it is verified: all five probes (bridge, events,
assets, lifecycle, alloc) produce identical artifacts before and after the
refactor, and a fresh `new`+`build` still yields a working binary.

**What's confined to `backend_webview.odin` now:** every `wv.*` call, the C
`proc "c"` trampolines (invoke + dispatch), and the cstring request id (boxed as
the opaque `Request_Id`). The generic inbound-request flow is `backend_on_request`
in `backend.odin`.

**Revisit / remaining work:** implement one native backend end-to-end (macOS
first per the roadmap). — DONE for macOS, see D15.

## D15 — Native macOS WKWebView backend implemented & verified

**Decided:** `backend_darwin.odin` is a complete native backend (NSApplication +
NSWindow + WKWebView + a custom WKScriptMessageHandler + NSWindowDelegate),
selected with `-define:HEIMDALL_NATIVE=true` (CLI: `heimdall build --native`).
All five probes pass identically to the webview/webview backend.

**Key technical findings (the hard-won bits):**
- `intrinsics.objc_send` only accepts an `@(objc_class)`-typed receiver, so wrap
  every runtime `id` as `^OC` (a minimal NSObject view). You cannot redeclare
  `objc_msgSend` (the Odin runtime already declares it; redeclaration is a
  hard error) and `runtime.objc_msgSend` is unexported — the cast+intrinsic is
  the only clean path. Selectors must be compile-time literals; bool args must be
  typed (`bool(true)`, not `true`).
- `@(require) foreign import "system:WebKit.framework"` is REQUIRED — without
  `@(require)`, the framework is dead-stripped (we reference no C symbols from
  it, only runtime objc classes), so `WKWebViewConfiguration` comes back nil.
  This bit hard: the webview backend's WebKit link is dead-stripped under
  HEIMDALL_NATIVE because `webview_backend_create` is `when`-excluded/unreferenced.
- The native message channel is one-way, so it needs a different shim
  (`SHIM_JS_NATIVE`, id-correlated, evals `_resolve`/`_reject`) vs. the
  webview/webview shim (which gets a Promise from `webview_bind` directly).
- Main-thread hop uses `dispatch_async_f` (function-pointer libdispatch variant)
  — avoids needing to synthesize an Objective-C block from Odin.
- `should_quit` is now enforced on this backend via `windowShouldClose:`.

**Still TODO on macOS native:** Linux (WebKitGTK) and Windows (WebView2) remain
scaffolds. (The `app://` scheme is now done — see D16.)

## D16 — Native `app://` scheme handler (retires the loopback server on native)

**Decided:** The native macOS backend serves the embedded asset map over a custom
`app://` scheme via `WKURLSchemeHandler` (same handler object), instead of the
loopback HTTP server. `Backend.serves_assets` gates this: when true, `run`
navigates native+prod to `app://localhost/index.html` and never starts the
`Asset_Server`. webview/webview leaves `serves_assets` false (no custom-scheme C
API) and keeps using loopback. Verified: native `_probe_assets` reports
`origin: "app://localhost"` (vs. `http://127.0.0.1:<port>` on webview).

**Key finding:** you MUST reply with an **NSHTTPURLResponse (status 200 +
Content-Type header)**, not a bare `NSURLResponse`. With a bare response the main
document "loads" (didFinish succeeds) but WebKit never executes its scripts or
fetches subresources — `app.js` was simply never requested until the switch to
NSHTTPURLResponse.

**Scope note:** this is the *in-webview* `app://` scheme (serving content into the
view). It is unrelated to a system-registered `myapp://` URL scheme / deep
linking (which needs an `Info.plist` `CFBundleURLTypes` + a `.app` bundle +
`application:openURLs:`) — that remains future work (the `.app` bundle now exists,
see D17, but the `CFBundleURLTypes` + `on_open_url` hook are still TODO).

## D17 — `heimdall bundle`: macOS .app packaging + `[bundle]` config

**Decided:** `heimdall bundle` builds the release binary (native by default;
`--webview` to override) and assembles a `<DisplayName>.app` with
`Contents/{Info.plist, MacOS/<exe>, PkgInfo, Resources/AppIcon.icns}`. Config
lives in a `[bundle]` section of `heimdall.toml`; `identifier` (CFBundleIdentifier,
reverse-DNS) is REQUIRED and the command errors with guidance if it's missing.

**Implementation notes:**
- The flat TOML parser is now section-aware: `[bundle]` keys are namespaced
  `bundle.identifier` etc. (`config.odin`).
- Icon: `.icns` is copied as-is; a `.png` is converted to a full `.iconset`
  (10 sizes, 16→1024) via `sips`, then `iconutil -c icns`. Missing `sips`/icon
  is a warning, not a failure (the app bundles without an icon).
- `Info.plist` is generated XML (CFBundle{Name,DisplayName,Identifier,Executable,
  ShortVersionString,Version,PackageType}, LSMinimumSystemVersion,
  NSHighResolutionCapable, optional LSApplicationCategoryType + CFBundleIconFile).
- The release-build pipeline was extracted from `cmd_build` into a shared
  `build_binary(p, native, skip_frontend, out)` reused by `bundle`.

**Verified:** fresh `new` → `bundle` produces a `plutil -lint`-clean bundle that
launches as a real app via `open MyApp.app` (a LaunchServices-managed process);
the png→icns path yields a valid `ic12` `.icns`; missing `identifier` errors
cleanly.

**Still TODO (the deep-linking follow-on):** add `CFBundleURLTypes` to the plist
from a configured scheme + an `application:openURLs:` delegate surfaced as an
`on_open_url` hook, so `open myapp://path` reaches the Odin side. Also: `.dmg`;
AppImage/`.exe` for the other platforms. (Code signing is done — see D18.)

## D18 — Code signing + notarization + a reusable CI action

**Decided:** One `heimdall sign` command and one `[sign]` config section,
dispatching per host OS — macOS `codesign` (hardened runtime) + `xcrun notarytool`
+ `stapler`; Windows `signtool` (stubbed, Windows-only compile); Linux a no-op
(no OS-level signing requirement — the user's stated assumption, confirmed).
`heimdall bundle` gained `--sign` / `--adhoc` / `--notarize` so packaging+signing
is one step.

**UX kept uniform across platforms:** same command, same `[sign].identity`
(meaning "the signing identity" everywhere — macOS Developer ID name or `-` for
ad-hoc; Windows cert subject). Notarization is the one macOS-specific extra.

**Secrets discipline:** the TOML holds only non-secret cert *names*. The identity
and notarization creds resolve from env (`HEIMDALL_SIGN_IDENTITY`,
`HEIMDALL_NOTARY_PROFILE`, or `HEIMDALL_APPLE_ID`/`TEAM_ID`/`APP_PASSWORD`), so CI
injects them without committing anything.

**CI:** a reusable **composite GitHub Action** lives at the repo root
(`action.yml`) — installs Odin (`laytan/setup-odin`) + bun, builds the heimdall
CLI from `${{ github.action_path }}/cli`, optionally imports a `.p12` into a temp
keychain and stores notarytool creds, then runs the requested `heimdall` command.
`heimdall new` scaffolds a 3-line `release.yml` that just `uses:` the action.
Per-input `if:` guards mean the same action covers unsigned/ad-hoc/signed/notarized.

**Verified:** `heimdall bundle --adhoc` and `heimdall sign --adhoc` produce a
signature that independent `codesign --verify --strict` accepts ("valid on disk,
satisfies its Designated Requirement"; `Signature=adhoc`). No-identity errors with
guidance. Real Developer ID is the same code path (adds `--timestamp` +
entitlements); notarization + the Action are implemented and YAML-validated but
need a real Apple account / Actions runner to exercise (can't be done locally).
Ad-hoc signing needs no certificate, which is what makes the pipeline testable here.

## D19 — Config: common section + per-platform overrides

**Decided:** `heimdall.toml` packaging settings use a Tauri-style layout —
`[bundle]` / `[sign]` are common to all platforms; `[bundle.macos]` /
`[bundle.windows]` / `[bundle.linux]` (and `[sign.<platform>]`) override
per-platform. A setting resolves platform-first, falling back to the common
section, so users only repeat genuinely platform-specific values.

**Implementation:** `load_project` now collects all `section.key` pairs into a map
in one pass, then `resolve_project` reads each field via
`resolve(m, section, key, platform)` which tries `section.<plat>.key` then
`section.key`. The platform key comes from the CLI's host OS (`current_platform`),
since you bundle for a platform on that platform. Backward compatible: a flat
`[bundle]`/`[sign]` is treated entirely as common. Top-level project keys (name,
web_dir, dev_cmd, …) stay common-only.

**Verified:** with `[bundle] min_macos=10.13` + `[bundle.macos] min_macos=12.3`,
the generated Info.plist's `LSMinimumSystemVersion` is `12.3` (override wins);
`CFBundleIdentifier` set only in `[bundle]` resolves via the common fallback; a
`[bundle.windows]` value is ignored on macOS.

## D20 — Native backend is the default on macOS; menus added

**Decided:** On macOS the native WKWebView backend is now the DEFAULT. The define
flipped from opt-in `HEIMDALL_NATIVE` to opt-out `HEIMDALL_WEBVIEW`
(`app.odin`: `when ODIN_OS == .Darwin && !HEIMDALL_WEBVIEW`). CLI commands
(`dev`/`build`/`bundle`) default to native; `--webview` opts out. The endgame is
our own native shell on every platform (macOS done; Linux WebKitGTK + Windows
WebView2 still scaffolds), with webview/webview as the bootstrap until then.

**Why:** The native backend is the better experience — real menus, the `app://`
scheme (no loopback server), enforced `should_quit`. It's verified equivalent to
the webview backend on every probe, so making it default loses nothing.

**Native menus (same change):** `App_Config.menu: []Menu_Item` (`menu.odin`) +
the macOS implementation in `backend_darwin.odin`. Standard App/Edit/Window menus
are added automatically (Edit is what makes ⌘C/⌘V/⌘A work in WKWebView); custom
items emit a `"menu"` event `{ id }`, `role` items use standard selectors. Quit
routes through the run loop (clean shutdown + `should_quit`), not `terminate:`.
Verified end-to-end: a synthesized ⌘1 fired a custom item → `emit("menu",…)` →
JS `on("menu")` reported `{id:"probe.fire"}` (`examples/_probe_menu`).

**Also fixed:** `heimdall dev` now frees the dev port before starting and on exit
(the `bun run dev` child server was orphaned on kill, causing EADDRINUSE on the
next run). The webview/webview backend has no menus (by design) and ignores
`menu`.

## D21 — Native Linux backend (WebKitGTK); the default on Linux

**Decided:** `backend_linux.odin` is a hand-written native shell over
`webkit2gtk-4.1` + GTK 3, and the DEFAULT on Linux (`-define:HEIMDALL_WEBVIEW=true`
opts out), matching the macOS arrangement. It implements the same `Backend` vtable
as `backend_darwin.odin`, so the bridge / services / events / user code are
unchanged. Wired into `app.odin`:
`else when ODIN_OS == .Linux && !HEIMDALL_WEBVIEW { ok = linux_backend_create(...) }`.

**Why:** Same reasoning as the macOS native default (D20) — real menus, the
`app://` scheme (no loopback server), and an enforced `should_quit`. WebKitGTK is
the easiest of the three to bind: plain GObject/C via `foreign import`, no
Objective-C runtime or COM vtables.

**Mechanics:** GtkWindow + `webkit_web_view_new`; JS→Odin over a
`WebKitUserContentManager` script-message handler (`script-message-received::__heimdall_invoke`,
body read via `jsc_value_to_string`); shim injected at document-start; eval via
`webkit_web_view_evaluate_javascript`; main-thread hop via `g_idle_add`; event
loop a hand-rolled `g_main_context_iteration` so `terminate()` returns cleanly;
`app://` via `webkit_web_context_register_uri_scheme` (registered secure +
CORS-enabled so `location.origin` is `app://localhost`, like macOS);
`should_quit` via the window `delete-event`; menus as a GtkMenuBar (custom items
emit `"menu" { id }`, role items map to GTK/WebKit where one exists, accelerators
via a `GtkAccelGroup`). `WEBKIT_DISABLE_DMABUF_RENDERER=1` is set unless already
present (VM/NVIDIA blank-render workaround).

**Parity with macOS, where it makes sense:** the standard App/Edit/Window menus
macOS auto-adds are skipped on Linux — GTK menus are in-window and WebKitGTK
already supplies copy/paste + a context menu; macOS-only roles (About/Hide/Show
All/Zoom) are skipped too.

**Verified:** every `_probe*` produces the same result as macOS — invoke
round-trip (success + reject), `app://` origin `app://localhost`, threaded
`emit`/`on` ordering, `on_startup`/`on_shutdown` + `terminate`, zero leaks/bad
frees, and the menu `activate → emit("menu") → on("menu")` round-trip
(`{id:"probe.fire"}`). No keystroke-synthesis tool was available, so the menu chain
was confirmed by programmatically firing the item (temporary instrumentation,
since removed) rather than a synthesized accelerator. The webview/webview fallback
on Linux still needs a Linux-built `libwebview.a` (the vendored archive is macOS
arm64) — unaffected here because the native backend doesn't use it and Odin's DCE
drops the unused webview path.

## D22 — JS API: `window.heimdall` alias + a generated typed client

**Decided:** Two complementary front-end ergonomics, both additive (the original
`window.__HEIMDALL__` still works):

1. **Short alias** — the shim also exposes `window.heimdall` (= `window.__HEIMDALL__`).
   So `window.heimdall.invoke("svc.cmd", args)` / `.on(...)`.
2. **Generated typed client** — `generate-bindings` now emits a client *module*
   (`<base>.js` + `<base>.d.ts`, default `web/src/heimdall.gen`, set by `bindings`
   in `heimdall.toml`) with one object per service:
   `import { greeting } from "./heimdall.gen.js"; await greeting.greet({name})`.
   The `.js` calls `window.heimdall.invoke("greeting.greet", args)` under the hood;
   the `.d.ts` types args + `Promise<result>`. `on` is re-exported for events.

**Why:** `window.__HEIMDALL__.invoke("service.command", …)` is ugly on two axes —
the shouty global and the stringly-typed name. The alias fixes the first; the
typed client fixes both and gives editor autocomplete. Kept the proxy idea out
(the user chose alias + generated, no runtime magic).

**Best-DX wiring:** the client is generated by `heimdall new`, and **auto-regenerated
by `dev` (at startup) and `build` (before the frontend build)** when `bindings` is
set — so it's always present and in sync, and `git clone && heimdall build` works
even though the client is gitignored. The vanilla template imports it
(`./heimdall.gen.js`); the SvelteKit client lands at `web/src/lib/heimdall.gen`
(import via `$lib`). Schema builds reuse `ensure_assets_stub` so they compile
before assets exist.

**Format choice:** `.js` + `.d.ts` (not a single `.ts`) so it works in every
frontend — the vanilla template serves raw ESM (needs the real `.js`), and TS
projects pick up the sibling `.d.ts` from a `./heimdall.gen.js` import.

**Verified:** in a built app, both `greeting.greet({name})` (typed client) and
`window.heimdall.invoke(...)` (alias) round-trip (`{"greet":"Hello, Client"}`);
standalone `generate-bindings` and the `build` auto-regen safety-net both recreate
the client; all `_probe*` still pass after the shim change.

## D23 — SvelteKit frontend: delegate to `sv create`, configure as a static SPA

**Decided:** `heimdall new --frontend sveltekit` runs the official `sv create`
(template + TypeScript prompts stay interactive) and **configures the static
adapter during create** by passing `--add sveltekit-adapter=adapter:static`. Extra
add-ons (Tailwind, …) come from heimdall's repeatable **`--add`** flag, appended to
that same `sv create --add`. heimdall then adds a root `+layout` with
`export const ssr = false;` and a best-effort `fallback: 'index.html'` patch.
`--pm` (bun default, also npm/pnpm/yarn/deno) controls the runner + generated
`dev_cmd`/`build_cmd`; `dist_dir = web/build`.

> **Why the adapter must be set DURING create (not via `sv add` after):** an
> earlier version created without the adapter and added it afterward with
> `sv add sveltekit-adapter=adapter:static` — which kept `sv`'s interactive add-on
> menu. But when Tailwind is also installed, adding the adapter *after* leaves the
> project in a state where vite-plugin-svelte feeds the raw `+layout.svelte` source
> to Tailwind's CSS pipeline → `[@tailwindcss/vite] Invalid declaration: <script…>`
> in `heimdall dev`. The **identical final config** built via a single
> `sv create --add …adapter:static` works. The fix: force the adapter during
> create. Cost: `sv`'s add-on menu is skipped (passing `--add` makes it
> non-interactive), so add-ons are requested via heimdall's `--add` flag instead.
> (Verified: a single-create project matches the user's working `heimdall_sk` byte
> for byte; the post-`sv add` variant did not. NB: a headless-Chrome harness threw
> false positives — it errored even on the working project — so this was confirmed
> by config/state comparison + the user's real-browser testing, not the harness.)

**Why delegate** instead of an embedded snapshot: SvelteKit churns (the adapter
config recently moved from `svelte.config.js` into `vite.config.ts`), and `sv` is
the source of truth. Caret-range deps resolve fresh at install time; we only own
the adapter + SPA bits.

**SPA config — the key finding (from testing the `demo` template):** an earlier
attempt used `ssr = false` + `prerender = true`, which **fails** on any route with
server `actions`/`load` (`Cannot prerender pages with actions` — the demo's
`sverdle`). The correct config is `ssr = false` with a `fallback` page and **no**
forced prerender: every route becomes a client SPA route, server-only logic just
doesn't run (inherent to static embedding), and the build succeeds for any
template. Fallback name is `index.html` (not `200.html`) so the file heimdall
serves at `app://localhost/` always exists, including the minimal template where
nothing is prerendered. (Templates that prerender a home page show a harmless
SvelteKit "Overwriting index.html" notice.)

**Verified:** both `minimal` and `demo` templates (TS) scaffold → build → run on
the native Linux backend; the typed client at `$lib/heimdall.gen` round-trips
(`{"greet":"Hello, Min","path":"/"}` — note `path:"/"`, the SPA-router 404 fix).
The interactive flow was exercised headlessly via a temporary non-interactive flag
(since removed).

## D24 — Linux backend moved to GTK4 + libadwaita (from GTK3/webkit2gtk-4.1)

**Decided:** Rewrite `backend_linux.odin` against **GTK 4 + libadwaita +
`webkitgtk-6.0`** (was GTK 3 + `webkit2gtk-4.1`, per D21). Window uses an
`AdwHeaderBar` title bar; `adw_init()` makes the whole UI follow the system
light/dark preference automatically.

**Why:** the GTK3 title bar was always light even in system dark mode — GTK3 does
not follow the freedesktop `color-scheme` without a manual D-Bus portal query,
whereas GTK4/libadwaita (AdwStyleManager) follows it for free. The user wanted a
proper libadwaita title bar that respects dark mode. GTK4 is also the modern,
actively-developed stack.

**What changed (GTK3 → GTK4 API differences handled):**
- `gtk_init_check` → `adw_init`; `gtk_window_new(TOPLEVEL)` → `gtk_window_new()`;
  `gtk_container_add` → `gtk_window_set_child`; `gtk_widget_show_all` →
  `gtk_window_present`.
- Title bar: `gtk_window_set_titlebar(window, adw_header_bar_new())`.
- Close/veto: GTK4 removed `delete-event` → `close-request`.
- Script message: webkitgtk-6.0's `script-message-received` hands a **`JSCValue`**
  directly (4.1 handed a `WebKitJavascriptResult`); `register_script_message_handler`
  is 3-arg (world = NULL).
- Menus: GTK4 removed `GtkMenuBar`/`GtkMenuItem` → a **`GMenu` model rendered by
  `GtkPopoverMenuBar`**, actions in a `GSimpleActionGroup` (`hd.<id>`),
  accelerators on a `GtkShortcutController`, separators as GMenu sections.
- `app://` scheme + security-manager API is unchanged from 4.1 (reused as-is); the
  bridge/events/threading/lifecycle logic is otherwise identical.

**Deps:** dev — `webkitgtk6.0-devel libadwaita-devel gtk4-devel` (Fedora) /
`libwebkitgtk-6.0-dev libadwaita-1-dev libgtk-4-dev` (Debian). `heimdall doctor`
checks `pkg-config --exists webkitgtk-6.0 libadwaita-1 gtk4`. End users need the
**runtime** libs (the webview is a system dependency, Tauri-style) — `webkitgtk-6.0`
runtime is newer/less ubiquitous today than `webkit2gtk-4.1`, a tradeoff accepted
for the better UX; availability is improving.

**Linking note:** the GTK4 build links cleanly because the (macOS-only, Mach-O)
vendored `libwebview.a` is dead-code-eliminated when the native backend is the
default — so GTK3 and GTK4 never coexist in one binary.

**Verified:** all `_probe*` pass on GTK4 (invoke + reject, `app://localhost`
origin, threaded events, lifecycle, zero leaks, and the menu
`activate → emit("menu") → on("menu")` round-trip `{"id":"probe.fire"}`); `heimdall
doctor` green; dark-mode title bar follows the system (AdwHeaderBar + adw_init).

## D25 — Unified window-control API + built-in `win` service

**Decided:** A single platform-agnostic window API. Public Odin procs
(`window_minimize/maximize/unmaximize/show/hide/focus/center/close`,
`window_set_fullscreen/set_title/set_size`) plus `App_Config` initial-state fields
(`min_width/height`, `maximized`, `fullscreen`, `always_on_top`, `center`,
`hidden`). The frontend gets the same control via a built-in **reserved `win`
service** (`invoke("win.minimize")` / generated `win.minimize()`).

**Unified, switch-under-the-seam:** the whole op set collapses to ONE vtable entry
`Backend.window_op(app, Window_Op)`; each backend (darwin NSWindow, linux GTK4,
webview no-op) switches on the enum. Keeps the vtable lean (one pointer, not ~10)
and the public surface identical across platforms — per the user's directive.

**Best-effort ops:** `center` and `always_on_top` are no-ops under Wayland (a
client can't position/raise itself) but work on macOS; documented, not errors. The
webview/webview fallback only maps `Close` (its C API has no window-state control).

**Schema visibility:** `register_window_service` runs *before* the schema-dump
early return in `create`, so `win` appears in generated bindings (typed `win`
namespace) — its handlers only touch the backend at runtime, never in schema mode.

**Dropped:** the `frameless`/decorations option — users always get the native
platform titlebar (simpler, on-brand).

**Verified:** `examples/_probe_window` drives every `win.*` command and all
round-trip `ok`; full probe suite still green; `generate-bindings` emits the typed
`win` namespace. (macOS `dwn_window_op` written against NSWindow but not
compile-tested on this Linux box — Linux + webview verified here.)

## D26 — Linux bundling: `.deb` + `.rpm` via dpkg-deb / rpmbuild

**Decided:** On Linux, `heimdall bundle` emits **both** a `.deb` and a `.rpm` from
one staged `/usr` tree (binary → `/usr/bin`, a `.desktop` → `/usr/share/applications`,
optional `.png` icon → hicolor 256x256). `.deb` via `dpkg-deb --root-owner-group`
(no fakeroot); `.rpm` via `rpmbuild -bb` with a generated spec. cmd_bundle now
dispatches per-OS: `bundle_macos` (darwin file) / `bundle_linux` (linux file).

**Dependency handling:** the `.rpm` relies on rpmbuild's **automatic** ELF
shared-lib `Requires` (so the GTK4/WebKit/libadwaita runtime is detected with no
hardcoding). `dpkg-deb` does *not* auto-detect, so the `.deb` gets a default
`Depends: libwebkitgtk-6.0-4, libadwaita-1-0, libgtk-4-1`, overridable via
`[bundle.linux].deb_depends`.

**Config:** added `summary`, `description`, `maintainer`, `license`, `homepage`,
`deb_depends`, `rpm_requires` (all `[bundle]` + `[bundle.linux]`-overridable);
reused `category` as the freedesktop `Categories` on Linux. The `.desktop`/icon id
is `[bundle].identifier` (falls back to the binary name).

**Resilience:** missing `dpkg-deb` or `rpmbuild` skips just that format (with a
note) rather than failing — a Debian box gets the `.deb`, a Fedora box gets both.

**Gotcha:** `%{buildroot}` in the rpm spec's `%install` had to be written with
`strings.write_string`, not `fmt.sbprintf` — Odin's fmt treats BOTH `%` and `{` as
format tokens and mangled it.

**Verified:** scaffold → `heimdall bundle` produced a valid `.deb` (correct
Depends/Maintainer/contents) and `.rpm` whose auto-`Requires` include
`libwebkitgtk-6.0.so.4`, `libadwaita-1.so.0`, `libgtk-4.so.1`,
`libjavascriptcoregtk-6.0.so.1`. (macOS `.app` path unchanged, moved to
`cmd_bundle_darwin.odin`; not re-tested on this Linux box.)

## D27 — Scaffolds ship a default app icon (the Heimdall mark)

**Decided:** `heimdall new` writes a default `icon.png` (the Heimdall logo,
rendered from `docs/public/logo.svg`, embedded in the CLI via `#load("icon.png")`)
into every project, and the templates reference it: `App_Config.icon =
#load("icon.png")` and `[bundle].icon = "icon.png"`. So a fresh app looks finished
when packaged, and on macOS gets a Dock icon at dev time.

**Per-platform runtime reality (documented):** packaged/installed apps are iconed
everywhere (macOS `.icns`, Linux hicolor `512x512` + `.desktop`). At bare
`heimdall dev`: macOS sets the Dock icon from `App_Config.icon` (NSApp
`setApplicationIconImage`); **GTK4/Wayland has no per-window raw-bytes icon**, so
Linux dev windows show a generic icon (the installed `.desktop` icon is used once
packaged — same as every GTK4 app); Windows will set the window-class icon when
that backend lands.

**Also fixed (real bug surfaced here):** the `heimdall.toml` parser swallowed
**inline comments** — `icon = "icon.png"  # note` parsed the value *with* the
comment. `parse_toml_value` now takes a quoted value from between the quotes (and
truncates an unquoted value at `#`), so inline comments work.

**Verified:** scaffold → `heimdall bundle` puts the icon at
`/usr/share/icons/hicolor/512x512/apps/<id>.png` in both `.deb` and `.rpm` with
`.desktop` `Icon=<id>` resolving to it.

## D28 — macOS backend parity pass (resizable, web focus, accelerators)

**Decided:** Brought `backend_darwin.odin` up to parity with the Linux/Windows
backends on three window-behavior gaps:

- **`resizable`/`fixed` honored.** At create the window's style mask only sets the
  `NSWindowStyleMaskResizable` bit when `App_Config.resizable` is true (a fixed
  window also loses the green zoom/maximize button), and `dwn_set_size` toggles
  that bit per the `fixed` arg — matching Linux `gtk_window_set_resizable` and
  Windows `WS_THICKFRAME`/`WS_MAXIMIZEBOX`. `dwn_set_size` also no longer
  re-centers (Linux/Windows leave position unchanged on resize).
- **Initial web-content focus.** `dwn_run` (on show) and the `.Show`/`.Focus`
  window ops now `makeFirstResponder:` the WKWebView, so the user can type without
  clicking first — parity with Linux `grab_focus` / Windows `MoveFocus`.
- **Menu accelerators with web focus — verified.** With the web view holding
  first responder, a `Cmd+1` still triggered the menu item (`_probe_menu` reported
  `{id:"probe.fire"}`), confirming macOS routes Cmd-equivalents through the menu
  via the responder chain (no explicit forward needed, unlike Windows'
  `AcceleratorKeyPressed`→`TranslateAcceleratorW`).

**Verified:** all `_probe*` pass on macOS native, including `_probe_window` (every
window op `ok`) and `_probe_menu` (accelerator round-trip while web-focused).

## D29 — Typed event payloads in generated bindings

**Decided:** Events get optional typing the same way commands do — via an explicit
declaration the schema-dump can reflect. New API `event(app, name, T: typeid)`
records a name -> payload-type mapping in `app.events`; `generate-bindings` walks
it and emits a `HeimdallEvents` interface plus a generic
`on<K extends keyof HeimdallEvents>(name, handler)` overload, with a
`(name: string, handler)` fallback so undeclared events still type-check.

**Why this shape:** `emit(app, name, payload)` is called inline with no
registration point, so there's nothing to reflect. Rather than statically parse
`emit` call sites (the fragile path we rejected for commands), the user declares
the payload type once — mirroring `command()` — and the same `core:reflect` RTTI
produces the `.ts`. Fully additive: untyped `emit`/`on` are unchanged; not
declaring an event just falls back to `any`.

**Built-in:** the framework auto-declares the `menu` event (`Menu_Event{id}`) in
`create`, so generated bindings always type `on("menu", ...)`.

**Verified:** `generate-bindings` on `examples/hello` emits `HeimdallEvents` with
the auto `menu` and a user-declared `greeting.tick`; `tsc --strict` type-checks
the generated `.d.ts` clean, and a deliberate payload-type mismatch is correctly
rejected (TS2322). All `_probe*` still pass (incl. `_probe_alloc` 0 leaks — the
new `app.events` map is freed in `destroy`).

## D30 — Deep linking (custom URL scheme)

**Decided:** Apps can register a custom URL scheme (`myapp://…`) and receive the
opening URL. Two-place declaration: `App_Config.url_schemes` (runtime argv match)
+ `[bundle].schemes` in heimdall.toml (OS registration at bundle time). Delivery
is surfaced both ways — an `on_open_url(app, url)` Odin hook AND a typed
`open-url` event (auto-declared like `menu`).

**Registration** is wired into each bundler: macOS `CFBundleURLTypes`
(cmd_bundle_darwin), Linux `.desktop` `MimeType=x-scheme-handler/<s>` + `Exec …%u`
(cmd_bundle_linux), Windows `HKCR\<scheme>\shell\open\command` registry keys in
the Inno installer (cmd_bundle_windows).

**Delivery:**
- macOS: `NSApplicationDelegate application:openURLs:` (the shared handler is also
  the NSApp delegate). Cold-start AND already-running, single-instance free.
- Windows/Linux: cold-start URL via argv (`deliver_launch_url` scans `os.args`).
  The **already-running** case (forward to the live instance) needs
  single-instance IPC — deferred (user chose: ship the 80%, note clearly).

**Cold-start race fix:** a launch URL exists before the page does, so the
`open-url` event is queued (`app.pending_urls`) and flushed when the shim calls a
reserved `win.__ready` command on `DOMContentLoaded` — after the app's `on(...)`
handlers are registered. The Odin hook fires immediately. `win.__ready` is
underscore-prefixed and filtered out of generated bindings.

**Why declaration (not static emit-scan):** same rationale as commands/events —
explicit `url_schemes` is reflectable and robust; no source parsing.

**Verified:** `_probe_deeplink` confirms hook + queued typed event both receive
the URL; the macOS bundler emits a `plutil`-clean `CFBundleURLTypes` with the
configured schemes; a fresh scaffold builds. NOT verified headlessly: the full
LaunchServices `open myapp://` round-trip (needs an OS-registered bundle) and the
Windows/Linux argv path (those backends build on their own machines).
