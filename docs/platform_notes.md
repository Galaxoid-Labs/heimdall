# Platform notes

Per-platform interop gotchas for the native backends. Until those land, the
framework runs on the **webview/webview** C library (`heimdall/backend_webview.odin`),
which hides all three platforms behind one C API. These notes are for the people
implementing `backend_darwin.odin` / `backend_linux.odin` / `backend_windows.odin`.

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

webview/webview's `webview_bind` gives each call a C `id` string we pass straight
back to `webview_return` — so `Request_Id` is that cstring. The native message
channels (`WKScriptMessage`, WebKitGTK script messages, `WebMessageReceived`)
have **no** built-in id. So the native shim must:

1. generate an id, stash `{resolve, reject}` in a pending map,
2. `postMessage({ id, name, args })`,
3. have Odin `eval` back `__HEIMDALL__._resolve(id, result)` / `_reject(id, err)`.

That is a **different shim** than the webview/webview one (which relies on
`webview_bind` returning a Promise directly). Gate the shim string per backend.

## macOS — WKWebView (Objective-C interop) — IMPLEMENTED

`backend_darwin.odin`. The default on macOS (`-define:HEIMDALL_WEBVIEW=true`
forces the webview/webview backend instead). Notes from
the implementation:

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

## Linux — GTK4 + libadwaita + WebKitGTK (`foreign import` C / GObject) — IMPLEMENTED

`backend_linux.odin`, built against **GTK 4 + libadwaita + `webkitgtk-6.0`**. The
default on Linux (`-define:HEIMDALL_WEBVIEW=true` forces the webview/webview
backend instead). It implements the same `Backend` vtable as the macOS backend,
with no Objective-C/COM machinery — just GObject functions and signals.

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
- Verify: `odin build examples/_probe -collection:src=.` (native is the default)
  → `/tmp/heimdall_probe.json`. All `_probe*` pass exactly like macOS, including
  `app://` origin, threaded events, `should_quit`, zero leaks, and the menu
  `activate → emit("menu") → on("menu")` round-trip.

## Windows — WebView2 (COM) — deliberately last

**The full implementation plan lives in `heimdall/backend_windows.odin`** (a phased
"START HERE" block). Summary of the API mapping:

- COM with no language support: hand-lay the vtable structs, call through
  function pointers, and **implement** the completion/event-handler interfaces
  yourself (vtable of `proc "stdcall"` + `QueryInterface` + `AddRef`/`Release`).
  `core:sys/windows` has the Win32 + COM basics; hand-declare only the WebView2
  interfaces (use `WebView2.h` for vtable layout + IIDs).
- Window + loop: `RegisterClassExW` / `CreateWindowExW` + a `WndProc` + a
  `GetMessageW` loop (`Backend.run`); `WM_SIZE` resizes the controller.
- Bootstrap (async, hand-written handlers): `CreateCoreWebView2EnvironmentWithOptions`
  → `CreateCoreWebView2Controller(hwnd)` → `get_CoreWebView2`.
- Message channel: `add_WebMessageReceived` ← `window.chrome.webview.postMessage`.
- Inject the shim: `AddScriptToExecuteOnDocumentCreated` (`SHIM_JS_NATIVE`,
  `__CHANNEL__` = `window.chrome.webview.postMessage(payload)`).
- Eval / reply / events: `ExecuteScript`.
- Main-thread hop (`Backend.dispatch`): `PostMessageW` a boxed task to the UI window.
- `app://` scheme: register it at env creation via
  `ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations`, then
  `AddWebResourceRequestedFilter("app://*")` + `add_WebResourceRequested` →
  `CreateWebResourceResponse` over an `IStream` of the embedded bytes + MIME.
- Window control (`window_op`) + `App_Config` state: `ShowWindow`,
  `WM_GETMINMAXINFO` (min size), `SetWindowPos` (center / topmost / fullscreen).
- Menus: `HMENU` (`CreateMenu`/`AppendMenuW`) + `WM_COMMAND` → emit `"menu"`;
  accelerators via `CreateAcceleratorTable` + `TranslateAcceleratorW`.
- `should_quit`: `WM_CLOSE` returns 0 to veto, else `DestroyWindow` → `PostQuitMessage`.
- Link: `WebView2LoaderStatic.lib` (static; no DLL to ship) + the Evergreen
  runtime on the user's machine (verify in `doctor`).
- Packaging: a `cmd_bundle_windows.odin` for the `.exe` (+ zip/MSI later) and the
  `signtool` hook (`cmd_sign.odin` reserves the Windows path).

Each phase ends at a passing probe (`examples/_probe*`), exactly like macOS/Linux.
