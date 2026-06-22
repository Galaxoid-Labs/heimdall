# Platform notes

Per-platform interop gotchas for the native backends. The framework uses one
hand-written native backend per platform — `backend_darwin.odin` (macOS),
`backend_linux.odin` (Linux), and `backend_windows.odin` (Windows) — and this file
documents the interop each one relies on.

## The backend vtable

Every backend fills in the same `Backend` struct (`heimdall/backend.odin`):

| vtable proc | what it must do |
| --- | --- |
| `set_title` / `set_size` | window chrome |
| `navigate` / `set_html` | load content |
| `init_js` | inject `SHIM_JS` **before** page load (document-start) |
| `eval` | run JS in the current page (UI thread only) |
| `reply` | resolve/reject an invoke, given its `Request_Id` |
| `dispatch` | run a proc on the UI thread (safe from any thread) — the main-thread hop |
| `run` / `terminate` / `destroy` | event loop + teardown |

Two calls flow **back** into the framework: `backend_on_request(app, id, req_json)`
when JS invokes a command, and the proc handed to `dispatch` when it runs.

### Request id correlation

The native message channels (`WKScriptMessage`, WebKitGTK script messages,
`WebMessageReceived`) have **no** built-in request id. So the shim must:

1. generate an id, stash `{resolve, reject}` in a pending map,
2. `postMessage({ id, name, args })`,
3. have Odin `eval` back `window.heimdall._resolve(id, result)` / `_reject(id, err)`.

This is the id-correlated `SHIM_JS_NATIVE` injected at document-start by every
backend.

## macOS — WKWebView (Objective-C interop) — IMPLEMENTED

`backend_darwin.odin`. The macOS backend. Notes from the implementation:

- objc calls go through `intrinsics.objc_send`, which requires an `@(objc_class)`
  receiver type — so every runtime `id` is cast to `^OC` (a minimal NSObject
  view). You CANNOT redeclare `objc_msgSend` as a foreign proc (the Odin runtime
  already declares it) and `runtime.objc_msgSend` isn't exported, so the cast +
  intrinsic is the way. Selectors must be compile-time string literals.
- Message channel: `WKUserContentController addScriptMessageHandler:name:` +
  `window.webkit.messageHandlers.__heimdall_invoke.postMessage(<string>)`. We
  post a JSON *string* so the message `body` is an NSString (read via
  `UTF8String`), not an NSDictionary.
- Shim: a separate id-correlated shim (`SHIM_JS_NATIVE`) since the channel is
  one-way — invoke stashes a pending map and Odin evals `_resolve`/`_reject`.
  Injected as a `WKUserScript` at document start.
- Main-thread hop: `dispatch_async_f(&_dispatch_main_q, ctx, fn)` — the
  function-pointer libdispatch variant, so no Objective-C block is needed.
- Event loop: hand-rolled `nextEventMatchingMask:untilDate:inMode:dequeue:` +
  `sendEvent:` so `terminate()` can flip a flag and return cleanly.
- `should_quit`: `NSWindowDelegate windowShouldClose:` (same object as the
  message handler) — returns NO to veto, else ends the loop.
- Linking: `@(require) foreign import "system:WebKit.framework"` (and Cocoa) —
  `@(require)` is essential: with no referenced C symbols the framework would
  otherwise be dead-stripped.
- `app://` scheme (retires the loopback `Asset_Server` on native): the same
  handler object implements `WKURLSchemeHandler`, registered with
  `setURLSchemeHandler:forURLScheme:"app"` on the config BEFORE the webview is
  created. In `-webView:startURLSchemeTask:` we look up the path in the embedded
  asset map and reply with an **NSHTTPURLResponse (status 200 + Content-Type
  header)** — a bare `NSURLResponse` is NOT enough for WebKit to execute a
  main-frame document (it loads but never runs scripts / fetches subresources).
  `run` navigates native+prod to `app://localhost/index.html` instead of starting
  the loopback server (gated by `Backend.serves_assets`).
- Dev console (`App_Config.devtools`): enabled via KVC
  `developerExtrasEnabled` on the config's `WKPreferences` + `setInspectable:`
  (macOS 13.3+, guarded by `respondsToSelector:`). Linux uses
  `webkit_settings_set_enable_developer_extras`; Windows
  `ICoreWebView2Settings.AreDevToolsEnabled`. All three receive the resolved
  on/off bool from `create` (Auto = on in dev / off in release).
- **Webview lives in a container NSView — do NOT set it as the window's
  `contentView` directly.** When the Web Inspector is docked, WebKit reparents and
  wraps the content view; if that's the raw `WKWebView`, the title-bar inset is
  lost — the traffic lights get covered and stop responding. So we install a plain
  container `NSView` as the content view and add the webview as an autoresizing
  subview. (This is also what lets `App_Config.titlebar = .Transparent` extend
  content under the title bar cleanly.) Don't "simplify" this back.
- **Dock-icon reopen:** `NSApplicationDelegate
  applicationShouldHandleReopen:hasVisibleWindows:` (same shared handler object)
  deminiaturizes + refocuses the window, so clicking the Dock icon restores a
  minimized window — AppKit won't do it for a custom-managed window on its own.
  Note: reopen events are delivered by LaunchServices, so this fires for a bundled
  `.app`; a bare `heimdall dev` binary may not get it.
- **Title bar (`App_Config.titlebar`):** `.Transparent` adds
  `NSWindowStyleMaskFullSizeContentView` + `titlebarAppearsTransparent = YES`
  (title text + traffic lights kept, top strip stays natively draggable). There is
  deliberately no fully-chrome-less style — WKWebView has no `-webkit-app-region`
  and we expose no drag hook, so a frameless window would be un-draggable.
- **WebGPU (`App_Config.webgpu`):** enabled by flipping the private `WKPreferences`
  "WebGPU" feature via `_features` + `_setEnabled:forFeature:`, guarded by
  `respondsToSelector:` (safe no-op where absent). Recent WebKit enables it by
  default. Needs a secure context — `app://` should report `isSecureContext`.

## Linux — GTK4 + libadwaita + WebKitGTK (`foreign import` C / GObject) — IMPLEMENTED

`backend_linux.odin`, built against **GTK 4 + libadwaita + `webkitgtk-6.0`**. The
Linux backend. It implements the same `Backend` vtable as the macOS backend, with
no Objective-C/COM machinery — just GObject functions and signals.

**Why GTK4/libadwaita (not GTK3/webkit2gtk-4.1):** `adw_init()` makes the whole UI
follow the system light/dark preference automatically (AdwStyleManager), so the
**AdwHeaderBar title bar matches the user's theme** with zero extra work. GTK3 did
*not* follow the freedesktop `color-scheme` without a manual D-Bus portal query.

- Linking: one `foreign import` over the pkg-config libs (`gtk-4`, `adwaita-1`,
  `webkitgtk-6.0`, `javascriptcoregtk-6.0`, `gobject-2.0`, `glib-2.0`, `gio-2.0`).
  All GObject handles are modeled as `rawptr`. `heimdall doctor` checks
  `pkg-config --exists webkitgtk-6.0 libadwaita-1 gtk4`.
- Window + theme: `adw_init()` → `gtk_window_new()` →
  `gtk_window_set_titlebar(window, adw_header_bar_new())` for the themed,
  dark-mode-following title bar.
- Message channel: `webkit_user_content_manager_register_script_message_handler`
  (3-arg in GTK4, world = NULL) + the per-name
  `script-message-received::__heimdall_invoke` signal. In webkitgtk-6.0 the handler
  receives a **`JSCValue`** directly → `jsc_value_to_string` (g_free the result).
  Shim: `SHIM_JS_NATIVE` (id-correlated, like macOS), injected at document-start.
- Eval / reply / events: `webkit_web_view_evaluate_javascript` (length `-1`).
- Main-thread hop: `g_idle_add` (thread-safe). Event loop is a hand-rolled
  `for running { g_main_context_iteration(nil, TRUE) }` so `terminate()` can flip a
  flag and return cleanly. (We keep this manual loop rather than `g_application_run`
  so the lifecycle matches the other backends.)
- `app://` scheme (retires the loopback `Asset_Server`): the API is the same as
  4.1 — `webkit_web_view_get_context()` → `webkit_web_context_register_uri_scheme`,
  responding with `g_memory_input_stream_new_from_data` over the embedded bytes +
  MIME (or a 404 `GError`). Registered **secure + CORS-enabled** so
  `location.origin` is `app://localhost`. `run` navigates native+prod to
  `app://localhost/` (gated by `Backend.serves_assets`).
- `should_quit`: GtkWindow **`close-request`** (GTK4 replaced `delete-event`)
  returns TRUE to veto, else ends the loop. `terminate()` flips the flag via
  `g_idle_add`.
- Menus: GTK4 removed `GtkMenuBar`, so the user's `App_Config.menu` becomes a
  **`GMenu` model rendered by a `GtkPopoverMenuBar`**, with actions in a
  `GSimpleActionGroup` (inserted as `hd.<id>`) and accelerators on a
  `GtkShortcutController`. Custom items emit `"menu" { id }`; role items map to
  GTK/WebKit (`Quit`, the Edit commands via `webkit_web_view_execute_editing_command`,
  `Minimize`); separators become GMenu sections. macOS-only roles and the auto
  App/Edit/Window menus are skipped.
- DMABUF: `WEBKIT_DISABLE_DMABUF_RENDERER=1` is set (unless already present) to
  avoid blank/crashing renders on some VM/NVIDIA setups.
- Runtime deps: a shipped app dynamically links the GTK4 WebKit stack, so end
  users need the **runtime** libs (`webkitgtk-6.0`, GTK4, libadwaita) — not the
  `-devel` packages. This is the Tauri model (the webview engine is a system lib).
- WebGPU (`App_Config.webgpu`): enabled via the WebKitGTK runtime feature API —
  `webkit_settings_get_all_features()`, match a feature whose
  `webkit_feature_get_identifier` is `"WebGPU"`, then
  `webkit_settings_set_feature_enabled(settings, feature, TRUE)`. No-op if the
  installed build doesn't expose it (experimental). **Untested** — verify on Linux.
- Verify: `odin build examples/_probe -collection:src=.` (native is the default)
  → `/tmp/heimdall_probe.json`. All `_probe*` pass exactly like macOS, including
  `app://` origin, threaded events, `should_quit`, zero leaks, and the menu
  `activate → emit("menu") → on("menu")` round-trip.

## Windows — WebView2 (COM) — IMPLEMENTED

`backend_windows.odin`, built against the **WebView2** SDK. The Windows backend. It
implements the same `Backend` vtable as macOS/Linux. All `_probe*` pass identically
to the other platforms (bridge, threaded events, `app://` origin, lifecycle, zero
leaks, window control, and the menu `accelerator → emit("menu") → on("menu")`
round-trip).

- **COM by hand** (no language support): every consumed WebView2 interface is a
  struct whose first field is a `^Vtbl`; the vtable lists methods in order, with
  the slots we never call typed `rawptr` so the offsets of the ones we do call stay
  exact (slot orders + IIDs taken from `WebView2.h`). The interfaces we *implement*
  (the env/controller completion handlers, `WebMessageReceived`,
  `WebResourceRequested`, `AddScript…` completion, and `ICoreWebView2EnvironmentOptions`
  /`…Options4`/`…CustomSchemeRegistration`) share a `Com_Base` layout (vtable ptr +
  IID) with a generic `QueryInterface` and no-op refcount (they're singletons in
  the backend struct, freed at `destroy`).
- **Window + loop:** `RegisterClassExW` / `CreateWindowExW` + a `WndProc` + a
  `GetMessageW`/`TranslateMessage`/`DispatchMessageW` loop (`Backend.run`); `WM_SIZE`
  keeps the controller bounds in sync.
- **Bootstrap is async:** `CreateCoreWebView2EnvironmentWithOptions` (STA, after
  `CoInitializeEx`) → (handler) `CreateCoreWebView2Controller(hwnd)` → (handler)
  `get_CoreWebView2`. The completion handlers fire on the message loop, so the shim,
  message channel, `app://` filter, and the **initial navigation are deferred** until
  the controller is ready (`navigate`/`set_html` before then are queued).
  - **Gotcha:** `ICoreWebView2EnvironmentOptions::get_TargetCompatibleBrowserVersion`
    must return a real version string (`CORE_WEBVIEW_TARGET_PRODUCT_VERSION`, e.g.
    `"144.0.3719.77"`), not empty — an empty value makes env creation fail with
    `E_INVALIDARG`. Bump `WEBVIEW2_TARGET_VERSION` when the vendored loader updates.
- **Message channel:** `add_WebMessageReceived` ← `window.chrome.webview.postMessage`;
  `TryGetWebMessageAsString` (the shim posts a JSON string). Shim injected via
  `AddScriptToExecuteOnDocumentCreated` (`SHIM_JS_NATIVE`, `__CHANNEL__` =
  `WINDOWS_CHANNEL`).
- **Eval / reply / events:** `ExecuteScript`. Strings cross the boundary as UTF-16
  (`win.utf8_to_wstring` / `win.wstring_to_utf8`).
- **Main-thread hop (`Backend.dispatch`):** `PostMessageW(WM_APP_DISPATCH)` a boxed
  task to the UI window; `WndProc` unboxes and runs it. Thread-safe, so `emit()` /
  `terminate()` route through it.
- **`app://` scheme:** registered at env creation via our implemented
  `ICoreWebView2EnvironmentOptions4::GetCustomSchemeRegistrations` (one
  `CustomSchemeRegistration` for `"app"`, `TreatAsSecure`), then
  `AddWebResourceRequestedFilter("app://*", ALL)` + `add_WebResourceRequested` →
  look up the path in the embedded asset map → `SHCreateMemStream` over the bytes →
  `CreateWebResourceResponse(stream, 200, "OK", "Content-Type: …")` (or 404). `run`
  navigates prod → `app://localhost/` (gated by `serves_assets`).
- **Window control (`window_op`) + `App_Config` state:** `ShowWindow`,
  `WM_GETMINMAXINFO` (min size), `SetWindowPos` (center / topmost), and
  borderless-fullscreen by saving/restoring the style + rect over the monitor rect.
- **Menus:** `HMENU` (`CreateMenu`/`CreatePopupMenu`/`AppendMenuW`) → `WM_COMMAND` →
  emit `"menu"` (custom) or run the role (Quit → close; edit roles via
  `document.execCommand`; Minimize); accelerators via `CreateAcceleratorTableW` +
  `TranslateAcceleratorW` in the loop. Like Linux, only the user's menus are rendered.
- **Accelerators with web focus:** `TranslateAcceleratorW` in the message loop only
  fires while the *top-level* window has focus — once the user clicks into the page,
  the WebView2 child eats the keys. So we also implement `add_AcceleratorKeyPressed`
  on the controller: it fires before the page sees the key, and we run it through the
  same `TranslateAcceleratorW(hwnd, accel, …)` and set `Handled` if it matched. This
  makes host menu shortcuts work regardless of focus (GTK gets this free from its
  shortcut controller; macOS from the responder chain).
- **DevTools / focus:** DevTools (F12 / right-click *Inspect*) are gated to dev
  builds via `ICoreWebView2Settings::put_AreDevToolsEnabled(debug)` — WebView2
  defaults them ON, so release builds must turn them off (matches the other
  backends' developer-extras gating). On show, `controller->MoveFocus(PROGRAMMATIC)`
  gives the web content initial keyboard focus (Linux uses `grab_focus`).
- **`should_quit`:** `WM_CLOSE` returns 0 to veto, else `DestroyWindow` →
  `WM_DESTROY` → `PostQuitMessage`. `terminate` / `window_op` Close post a private
  `WM_APP_QUIT` (programmatic close, no veto).
- **Modern title bar:** `DwmSetWindowAttribute` with `DWMWA_WINDOW_CORNER_PREFERENCE`
  (rounded) and `DWMWA_USE_IMMERSIVE_DARK_MODE` driven by the system
  `AppsUseLightTheme` setting, re-applied on `WM_SETTINGCHANGE` so it tracks live
  theme switches — the Windows analogue of libadwaita's `AdwStyleManager`.
  (`App_Config.titlebar` is macOS-only and ignored here — Windows keeps this native
  bar.)
- **WebGPU (`App_Config.webgpu`):** Chromium gates it behind a flag, so the
  environment-options `get_AdditionalBrowserArguments` getter returns
  `--enable-unsafe-webgpu` when set (a dedicated `get_browser_args`, split from the
  shared empty-string getter so it doesn't also affect `get_Language`). Works on a
  recent Evergreen runtime. **Untested** — verify on Windows.
- **Window icon:** `App_Config.icon` (PNG bytes) is decoded at runtime via GDI+
  (`GdipCreateBitmapFromStream` over an `SHCreateMemStream` of the bytes →
  `GdipCreateHICONFromBitmap`) and set as the small + large window icon
  (`WM_SETICON`) — the title-bar/taskbar analogue of the macOS Dock icon. Links
  `Gdiplus.lib`.
- **Link:** `WebView2LoaderStatic.lib` is **vendored** at
  `heimdall/webview2/WebView2LoaderStatic.lib` (static — no `WebView2Loader.dll` to
  ship) and `foreign import`ed by relative path; `Shlwapi.lib` for `SHCreateMemStream`;
  Ole32/User32/Dwmapi/Advapi32 come from `core:sys/windows`. The Evergreen
  **runtime** must be present on the user's machine (it is on current Win10/11;
  `heimdall doctor` reads its version from the EdgeUpdate registry key).
- **Packaging:** `cmd_bundle_windows.odin` builds an **Inno Setup installer**
  (`<App>-<version>-Setup.exe`) plus a portable `.zip` fallback. The app `.exe` is
  self-contained (no DLLs to stage); `build_binary` embeds the app icon + version
  as a Win32 resource via `rc.exe` (png→ico generated in-process) and links
  `-subsystem:windows`. Optionally Authenticode-signs the exe + installer
  (`signtool`, cert subject from `[sign.windows] identity`). `heimdall doctor`
  reports the build-time tooling (Inno Setup `iscc`, Windows SDK `rc.exe`) as
  optional; only the WebView2 runtime is required to *run* a shipped app.

## Deep linking — per-platform delivery

How a `myapp://…` URL reaches the running app (see the
[Deep linking guide](guide/deep-linking.md) for the user-facing API).

- **Registration** (all platforms, at bundle time, from `[bundle].schemes`):
  macOS `CFBundleURLTypes` in `Info.plist`; Linux `MimeType=x-scheme-handler/<s>`
  in the `.desktop` (Exec gets `%u`), activated by `update-desktop-database` in
  the package post-install; Windows `HKCR\<scheme>\shell\open\command` registry
  keys in the Inno installer.
- **macOS delivery:** `NSApplicationDelegate application:openURLs:` (the shared
  handler object is also set as the NSApp delegate). Fires on cold-start AND while
  already running — LaunchServices reuses the live instance, so single-instance is
  free. macOS skips argv parsing.
- **Windows / Linux delivery:** the URL arrives as a command-line argument
  (`%1` / `%u`). `deliver_launch_url` (deeplink.odin) scans `os.args` for a
  `<scheme>://` arg at startup.
- **Linux already-running (single-instance):** `backend_linux.odin` reproduces
  the macOS "reuse the live instance" behavior with an **AF_UNIX socket** at
  `$XDG_RUNTIME_DIR/heimdall-<app_id>.sock`. The first instance binds + listens
  and services connections on the GLib main loop (`g_unix_fd_add`); a later
  launch connects, writes its launch URL, and `os.exit(0)`s — the primary reads
  it, focuses its window, and calls `deliver_open_url`. A re-launch with no URL
  just focuses the existing window. A stale socket (after a crash) is detected
  (connect refused) and replaced. Only engaged when `App_Config.url_schemes` is
  set; the socket is unlinked on clean shutdown.
- **Windows already-running (single-instance):** `backend_windows.odin`
  (`windows_single_instance`) reproduces the same behavior with a **named mutex**
  (`Global\heimdall-<app_id>`). The first instance creates it and becomes the
  primary; a later launch sees `ERROR_ALREADY_EXISTS`, `FindWindowW`s the primary
  by its **per-app window class** (`HeimdallWindowClass-<app_id>`), forwards its
  launch URL via **`WM_COPYDATA`** (after `AllowSetForegroundWindow` so the primary
  may raise itself), and `os.exit(0)`s without opening a window. The primary's
  wndproc receives the `WM_COPYDATA`, restores/foregrounds the window, and calls
  `deliver_open_url`. Only engaged when `App_Config.url_schemes` is set; the mutex
  is closed on shutdown.
- **Frontend timing:** a cold-start URL is known before the page exists, so the
  `open-url` event is queued and flushed when the shim calls the reserved
  `win.__ready` command on `DOMContentLoaded` (after the app's `on(...)` handlers
  are registered). The `on_open_url` Odin hook always fires immediately.
