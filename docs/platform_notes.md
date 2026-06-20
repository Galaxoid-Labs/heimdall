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

## Linux — WebKitGTK (`foreign import` C / GObject) — NEXT UP

**Getting started.** Implement `heimdall/backend_linux.odin` (currently a
`#+build linux` scaffold) following `heimdall/backend_darwin.odin` as the
reference — same `Backend` vtable, same `Dispatch_Box` trampoline pattern, same
`backend_on_request` callback. Then add the selection branch to `app.odin`:
`when ODIN_OS == .Linux && !HEIMDALL_WEBVIEW { ok = linux_backend_create(...) }`
and set `app.backend.serves_assets = true` (for the `app://` path).

- Toolchain: install the WebKitGTK dev package (`libwebkit2gtk-4.1-dev` +
  GTK 3 dev) and `pkg-config`. `heimdall doctor` already checks
  `pkg-config --exists webkit2gtk-4.1` on Linux.
- Linking: `foreign import` with the pkg-config libs. webkit2gtk is a C/GObject
  API, so no objc/COM machinery — closest of the three to a plain C binding.
- Verify: `odin run examples/_probe -collection:src=.` (native is selected by
  default once wired) → writes `/tmp/heimdall_probe.json`. All five `_probe*`
  should pass exactly like macOS. The webview/webview backend is the fallback
  until this lands, so the app already runs on Linux today.
- The native shim is `SHIM_JS_NATIVE` (id-correlated, like macOS); substitute the
  Linux message-channel post expression for `__CHANNEL__`
  (`window.webkit.messageHandlers.__heimdall_invoke.postMessage(...)` — same as
  Cocoa's WKScriptMessageHandler).

- Bind against `libwebkit2gtk-4.1` (`pkg-config --cflags --libs webkit2gtk-4.1`).
- Message channel: `webkit_user_content_manager_register_script_message_handler`
  + the `script-message-received` signal.
- Inject the shim: `webkit_user_content_manager_add_script` (document-start).
- Eval: `webkit_web_view_evaluate_javascript`.
- Main-thread hop: `g_idle_add`.
- Custom scheme: `webkit_web_context_register_uri_scheme("app", ...)`.
- `should_quit`: GtkWindow `delete-event` (return TRUE to veto).

## Windows — WebView2 (COM) — deliberately last

- COM with no language support: hand-lay the vtable structs, call through
  function pointers, and **implement** the completion/event-handler interfaces
  yourself (vtable + `QueryInterface` + `AddRef`/`Release`).
- Bootstrap: `CreateCoreWebView2Environment` → `CreateCoreWebView2Controller`
  (both async — that's where the hand-written completion handlers come in).
- Message channel: `add_WebMessageReceived` → `window.chrome.webview.postMessage`.
- Inject the shim: `AddScriptToExecuteOnDocumentCreated`.
- Eval: `ExecuteScript`.
- Main-thread hop: `PostMessage` to the UI window.
- Custom scheme: `AddWebResourceRequestedFilter` + `WebResourceRequested`.
- Link: WebView2 loader (`WebView2Loader.dll`) + the Evergreen runtime.
