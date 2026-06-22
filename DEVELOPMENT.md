# Heimdall — DEVELOPMENT.md

The **build ledger + invariants**. `CLAUDE.md` is the *what/why* (architecture,
contracts); `DECISIONS.md` is the decision log (why things are the way they are);
this file is the *how/when* — what's built, the rules that don't change, and
what's left. The live next-step list is the **► PICK UP HERE** section of
`CLAUDE.md`.

---

## Package & layout rules (read before scaffolding)

- **No `src/` package folder.** In Odin the directory name *is* the import name,
  so name packages for what they are.
- The framework package is `heimdall` (folder `heimdall/`). A generated app
  **vendors** its own copy as the `./heimdall/` subdir and imports it with
  `import hd "heimdall"` — no collection flag, no `..`. (No package manager in
  Odin, so vendoring is the portable choice: `git clone myapp && heimdall build`
  works with only the CLI installed.)
- The user's Odin is the **root package** (`main.odin` + `services.odin` +
  generated `assets_gen.odin`). The frontend lives in `web/` → `web/dist`.
- Larger apps can move the framework to a named folder and use a collection
  (`-collection:deps=deps`, `import hd "deps:heimdall"`); the CLI injects the flag.
  Default template stays collection-free.

Full file-by-file layout: `docs/internals.md`.

---

## Build ledger (all done)

The MVP and the native capstone are complete on **macOS, Linux, and Windows**.
Each runtime behavior has a headless self-test in `examples/_probe*` (writes a
JSON artifact to `/tmp`); all pass identically on every platform.

| Phase | What | State |
| --- | --- | --- |
| 0 | Skeleton + a window opens | ✅ |
| 1 | Bridge: services + `command()` + `invoke` round-trip (+ reject) | ✅ |
| 2 | Event bus (`emit`/`on`) + `dispatch_main` threading | ✅ |
| 3 | Asset embed + serving | ✅ |
| 4 | Lifecycle hooks, `Error` union, allocator hygiene | ✅ |
| 5 | CLI: `new`/`dev`/`build`/`embed`/`doctor` | ✅ |
| 6 | Typed bindings — schema-dump → `.d.ts` (commands + events) | ✅ |
| 7 | Backend vtable + **native backends** (WKWebView / WebKitGTK / WebView2) | ✅ |

Post-MVP, also done: window-control API + built-in `win` service; native menus;
deep linking (`myapp://`, cold-start everywhere + already-running single-instance
forwarding on all three platforms); dev
console toggle (`App_Config.devtools`); `bundle` (macOS `.app` + sign/notarize,
Linux `.deb`/`.rpm`, Windows Inno installer + `signtool`); one-line installers +
release workflow; VitePress docs site + branding.

> **History.** The project bootstrapped on the `webview/webview` C library behind
> the `Backend` vtable to get the bridge working fast, then replaced it with a
> hand-written native backend per platform. The bootstrap (and its `--webview`
> flag / `HEIMDALL_WEBVIEW` define) has been removed; the vtable seam remains.

---

## Remaining work

None blocking. In rough priority:

- **Tray** (reuse `tray-odin`) + **native dialogs** (file open/save, message box).
- `.dmg`, AppImage; auto-updater; multi-window.

---

## Platform verification (Linux + Windows)

Recent work was implemented and run **only on macOS**. The items below touch
shared or platform code and need a check on Linux and Windows. (The Linux/Windows
native backends themselves were built on those machines; this is the delta since.)

Build & smoke (both platforms):
- [ ] `odin build cli` compiles (has platform-specific `cmd_bundle_*` /
      `cmd_doctor_*`); `heimdall doctor` is sane.
- [ ] `heimdall new` → `dev` → window opens, greet round-trips; `heimdall build`
      runs.
- [ ] Run every `examples/_probe*` → expected `/tmp/*.json` (bridge, events,
      assets `app://`, lifecycle, alloc 0-leak, window, menu, deeplink).

Specific deltas to confirm:
- [ ] **Global rename (D32/D33):** the bridge works via `window.heimdall`; the
      `__HEIMDALL__` alias is gone. Backend reply strings were edited here but not
      compiled/run on these platforms (they're JS string literals — `_probe`
      covers them).
- [ ] **Typed events (D29):** `generate-bindings` emits `HeimdallEvents` incl.
      `menu` + `open-url`.
- [ ] **Paths (D42):** the `paths.odin` `base_dir` switch only compiles/runs the
      host branch on each OS — macOS exercises `~/Library/*`, but the **XDG branch
      (Linux)** and **`%APPDATA%`/`%LOCALAPPDATA%` branch (Windows)** are untested
      here. On each platform run `odin test heimdall` (the sandboxed `paths_test`)
      and confirm `hd.config_dir/data_dir/cache_dir/log_dir(app)` resolve to the
      expected OS locations, are namespaced by `app_id`, and are created. Also
      check the built-in `paths` JS service (`await paths.config()` → `{path}`).
- [ ] **WebGPU (D43):** `App_Config.webgpu = true` — only the macOS backend
      compiles on the dev machine; the **Linux** (`webkit_settings_get_all_features`
      + `set_feature_enabled`) and **Windows** (`get_browser_args` →
      `--enable-unsafe-webgpu`) paths are written blind. On each platform: confirm
      it compiles, then load a WebGPU page (`navigator.gpu` truthy / a small
      `requestAdapter()` test) with `webgpu = true` vs `false`. Verify the exact
      feature identifier is `"WebGPU"` on Linux/WebKitGTK and macOS/WebKit (adjust
      the string match if the engine names it differently).
      - **Secure context (all platforms, esp. macOS):** `navigator.gpu` (and
        `crypto.subtle`, service workers) only exist in a secure context. Confirm
        `window.isSecureContext === true` on the `app://localhost/` page. Linux
        (`register_uri_scheme_as_secure`) and Windows (`TreatAsSecure`) mark it
        secure explicitly; macOS relies on WebKit treating the `WKURLSchemeHandler`
        `app://` scheme as trustworthy — if `isSecureContext` is false there,
        WebGPU is unavailable regardless of the `webgpu` flag and the scheme needs
        a secure-context fix.
- [ ] **Dev console (D34):** dev build shows the inspector, release hides it;
      `devtools = .On` forces it on in a release build, `.Off` off in dev.
      (Linux: WebKitGTK inspector; Windows: Edge DevTools.)
- [ ] **Deep linking (D30):** `[bundle].schemes` registers (Linux `.desktop`
      MimeType + `update-desktop-database`; Windows installer registry). Cold-start
      on a NOT-running *installed* app: `xdg-open myapp://x` / `start myapp://x`
      fires `on_open_url` + the `open-url` event. Already-running now forwards to
      the live instance (single-instance) on all three platforms — verify on an
      installed build that no second window appears.
- [ ] **Packaging:** Linux `.deb`/`.rpm` install + launch (scheme works
      post-install); Windows Inno `.exe` + portable `.zip`, `--sign` via signtool.
- [ ] **Installers:** `install.sh` on Linux (only file://-tested on macOS);
      `install.ps1` on Windows (never run or parse-checked here).
- [ ] **Release workflow** (`release.yml`): the first tag run will reveal any
      CLI cross-build issues.

## Cross-cutting invariants (keep these true)

- No `eval` / `resolve` / `emit` off the UI thread without `dispatch_main`.
- FFI callbacks are `proc "c"` and restore the Odin `context` (`app.ctx`) before
  touching an allocator/logger.
- `@(require_results)` on anything returning an `Error` or a handle.
- `core:os` (redesigned): explicit allocators, `^os.File`, `os.Error` (check
  `err != nil`); never `core:os/old`.
- No methods — procedures over data; `create`/`destroy` naming.
- All backends fill the same `Backend` vtable; the bridge/services/events/user
  code never branch on OS.
- Update the docs in the same change as the code (see `docs/internals.md` →
  "Keeping docs current").
