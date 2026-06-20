#+build windows
package heimdall

// Native Windows backend — WebView2 via COM. NOT YET IMPLEMENTED, and deliberately
// last (CLAUDE.md): COM is the most tedious of the three. The framework currently
// runs on the webview/webview backend (backend_webview.odin); this file marks where
// the native implementation goes and is not wired into `create`.
//
// To implement, fill in a `windows_backend_create(app, debug)` that builds the
// same `Backend` vtable as `webview_backend_create`, backed by WebView2:
//
//   * Win32 window (RegisterClass/CreateWindow) + message loop — window, Backend.run
//   * CreateCoreWebView2Environment / CreateCoreWebView2Controller — bootstrap
//     (hand-lay the COM vtable structs, call through fn-ptrs, and IMPLEMENT the
//     completion-handler interfaces yourself: vtable + QueryInterface + AddRef/Release)
//   * ICoreWebView2:
//       - add_WebMessageReceived           — JS -> Odin
//         (window.chrome.webview.postMessage)
//       - AddScriptToExecuteOnDocumentCreated (SHIM_JS) — inject the shim
//       - ExecuteScript                     — Backend.eval / reply / events
//   * PostMessage to the UI window          — Backend.dispatch (main-thread hop)
//   * AddWebResourceRequestedFilter + WebResourceRequested — serve embedded
//     ASSETS on a custom scheme (replaces the loopback Asset_Server)
//   * WM_CLOSE handling                      — lets should_quit veto a close
//
// Link deps: WebView2 loader (WebView2Loader.dll) + the Evergreen runtime
// (present on current Windows; verify in `doctor`). See docs/platform_notes.md.
// Reply correlation: same id-based shim note as Darwin.

WINDOWS_BACKEND_IMPLEMENTED :: false
