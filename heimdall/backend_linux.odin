#+build linux
package heimdall

// Native Linux backend — WebKitGTK via `foreign import` C / GObject. NOT YET
// IMPLEMENTED. The framework currently runs on the webview/webview backend
// (backend_webview.odin); this file marks where the native implementation goes
// and is not wired into `create`.
//
// To implement, fill in a `linux_backend_create(app, debug)` that builds the
// same `Backend` vtable as `webview_backend_create`, backed by libwebkit2gtk-4.1:
//
//   * gtk_init / GtkWindow                          — window + lifecycle
//   * gtk_main / g_main_loop                         — Backend.run
//   * webkit_web_view_new                            — the web view
//   * WebKitUserContentManager
//       - webkit_user_content_manager_register_script_message_handler("__heimdall_invoke")
//         + "script-message-received" signal         — JS -> Odin
//         (window.webkit.messageHandlers.__heimdall_invoke.postMessage)
//       - webkit_user_content_manager_add_script (SHIM_JS, at document start)
//   * webkit_web_view_evaluate_javascript            — Backend.eval / reply / events
//   * g_idle_add                                     — Backend.dispatch (main-thread hop)
//   * webkit_web_context_register_uri_scheme("app")  — serve embedded ASSETS
//     (replaces the loopback Asset_Server)
//   * GtkWindow "delete-event"                        — lets should_quit veto a close
//
// Link deps: libwebkit2gtk-4.1 (`pkg-config --libs webkit2gtk-4.1`) + gtk. See
// docs/platform_notes.md. Reply correlation: same id-based shim note as Darwin.
//
// ── START HERE (next session) ───────────────────────────────────────────────
// 1. Reference: backend_darwin.odin — mirror its structure 1:1 (Linux_Backend
//    state, the Dispatch_Box trampoline, backend_on_request, dwn_*-style vtable
//    procs). The webview C lib's source (heimdall/webview/lib/upstream) also has
//    a working WebKitGTK backend in C to crib from.
// 2. Use the native shim SHIM_JS_NATIVE with LINUX_CHANNEL substituted for
//    __CHANNEL__ (see shim.odin / how backend_darwin uses DARWIN_CHANNEL).
// 3. Reply path: eval `window.__HEIMDALL__._resolve(id, result)` / `._reject`.
// 4. Wire into app.odin:
//      when ODIN_OS == .Linux && !HEIMDALL_WEBVIEW {
//          ok = linux_backend_create(app, debug)
//      }
//    and set app.backend.serves_assets = true (for the app:// scheme).
// 5. Verify: `odin run examples/_probe -collection:src=.` and the other
//    examples/_probe* — they must produce the same /tmp/*.json as on macOS.

// Substituted into SHIM_JS_NATIVE's __CHANNEL__ (WebKitGTK uses the same
// messageHandlers API as Cocoa's WKScriptMessageHandler).
LINUX_CHANNEL :: "window.webkit.messageHandlers.__heimdall_invoke.postMessage(payload)"
