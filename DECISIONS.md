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
