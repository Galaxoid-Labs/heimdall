#+build windows
package heimdall

// Native Windows backend — WebView2 via COM. NOT YET IMPLEMENTED (deliberately
// last — COM is the most tedious of the three). Until then, Windows runs on the
// webview/webview backend (backend_webview.odin). This file is the implementation
// plan; mirror backend_darwin.odin / backend_linux.odin for the vtable shape and
// the `g_*` global + `proc "c"` trampoline pattern.
//
// ════════════════════════════════════════════════════════════════════════════
//  START HERE — Windows backend implementation plan
// ════════════════════════════════════════════════════════════════════════════
//
// Goal: a `windows_backend_create(app, debug) -> bool` that fills the SAME
// `Backend` vtable as the other backends (set_title, set_size, window_op,
// navigate, set_html, init_js, eval, reply, dispatch, run, terminate, destroy)
// and sets `app.backend.serves_assets = true`. Then wire it into app.odin:
//     else when ODIN_OS == .Windows && !HEIMDALL_WEBVIEW {
//         ok = windows_backend_create(app, debug)
//     }
//
// Toolchain / linking
// -------------------
//   * WebView2 SDK — NuGet `Microsoft.Web.WebView2`. We hand-bind the COM
//     interfaces (none are in core:sys/windows), using `WebView2.h` only as the
//     reference for vtable layout + IIDs.
//   * Link `WebView2LoaderStatic.lib` (static — no WebView2Loader.dll to ship) for
//     `CreateCoreWebView2EnvironmentWithOptions`. The Evergreen *runtime* must be
//     present on the user's machine (it is on current Win10/11; `doctor` checks).
//   * `core:sys/windows` has the Win32 + COM basics (HWND, MSG, GUID, IUnknown,
//     HRESULT, S_OK, etc.). Use them; hand-declare only the WebView2 interfaces.
//
// The hard part: implementing COM callback objects in Odin
// --------------------------------------------------------
// WebView2's bootstrap + events take interfaces YOU implement. For each, lay out:
//   1. a vtable struct of `proc "stdcall"` fn-pointers — IUnknown first
//      (QueryInterface/AddRef/Release), then the interface's own methods,
//   2. an object struct: `{ vtable: ^The_Vtable, refs: u32, app: ^App, ... }`,
//   3. fill a single static vtable instance; QueryInterface returns the object
//      for IUnknown + the interface IID (else E_NOINTERFACE); AddRef/Release do
//      refcounting (these are short-lived; a no-op-ish refcount is fine).
// You'll need this for: the env + controller completion handlers, the
// WebMessageReceived handler, the WebResourceRequested handler, and
// AddScriptToExecuteOnDocumentCreated's completion handler.
//
// Phased plan (each phase ends at a passing probe — `odin run examples/_probe* -collection:src=.`)
// ----------------------------------------------------------------------------
// 1. WINDOW + LOOP: RegisterClassExW + CreateWindowExW + a WndProc; message loop
//    GetMessageW/TranslateMessage/DispatchMessageW for Backend.run. WM_SIZE keeps
//    the controller bounds in sync. (Opens an empty window.)
// 2. WEBVIEW2 BOOTSTRAP: CreateCoreWebView2EnvironmentWithOptions(handler) →
//    (in handler) environment->CreateCoreWebView2Controller(hwnd, handler2) →
//    (in handler2) controller->get_CoreWebView2(&webview); put_Bounds to the
//    client rect; controller->put_IsVisible(TRUE). Store env/controller/webview
//    in the backend struct. (Shows a page via navigate/set_html.)
//      - navigate  → webview->Navigate(url)
//      - set_html  → webview->NavigateToString(html)
// 3. BRIDGE: AddScriptToExecuteOnDocumentCreated(SHIM_JS_NATIVE with __CHANNEL__ =
//    WINDOWS_CHANNEL) injects the id-correlated shim at document start; channel is
//    `window.chrome.webview.postMessage(payload)`. add_WebMessageReceived(handler);
//    in Invoke, args->TryGetWebMessageAsString → the JSON `{i,n,a}` string →
//    rebuild `[name,args]` and call backend_on_request (mirror darwin_handle_message).
//    reply/eval → webview->ExecuteScript(js, nil). → _probe passes.
// 4. EVENTS + DISPATCH: Backend.dispatch posts a boxed {app,fn,user} to the UI
//    thread via PostMessageW(hwnd, WM_APP_DISPATCH, 0, box); WndProc unboxes,
//    sets context = app.ctx, runs fn, frees the box. (emit() already routes
//    through dispatch.) → _probe_events passes.
// 5. app:// SCHEME: register the custom scheme at ENV creation — EnvironmentOptions
//    via ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations(["app"]).
//    Then webview->AddWebResourceRequestedFilter(L"app://*", ALL) +
//    add_WebResourceRequested(handler). In Invoke: get the URI, map path → ASSETS
//    (trim leading '/', "" → index.html, SPA fallback), build an IStream over the
//    embedded bytes (SHCreateMemStream), environment->CreateWebResourceResponse(
//    stream, 200, "OK", "Content-Type: <mime>") and args->put_Response. `run`
//    navigates prod → "app://localhost/" (gated by serves_assets). → _probe_assets.
// 6. LIFECYCLE: WM_CLOSE → if cfg.should_quit != nil && !should_quit() return 0
//    (veto); else DestroyWindow → WM_DESTROY → PostQuitMessage(0). terminate →
//    PostQuitMessage / PostMessage a quit. on_startup/on_shutdown already handled
//    by app.run. → _probe_lifecycle + _probe_alloc (watch refcounts/handles).
// 7. WINDOW CONTROL: implement window_op (see window.odin's Window_Op):
//    Minimize/Maximize/Unmaximize → ShowWindow(SW_MINIMIZE/MAXIMIZE/RESTORE);
//    Show/Hide → ShowWindow(SW_SHOW/HIDE); Focus → SetForegroundWindow;
//    Center → SetWindowPos to a centered rect (GetSystemMetrics); Close → as WM_CLOSE;
//    Fullscreen_On/Off → save/restore WS_OVERLAPPEDWINDOW style + SetWindowPos to
//    the monitor rect (MONITORINFO). App_Config at create: min_width/height via
//    WM_GETMINMAXINFO; maximized (SW_MAXIMIZE); fullscreen; always_on_top
//    (SetWindowPos HWND_TOPMOST); center; hidden (skip the initial ShowWindow).
//    → _probe_window passes.
// 8. MENUS: build an HMENU from app.cfg.menu (CreateMenu/CreatePopupMenu/
//    AppendMenuW), SetMenu(hwnd, menu). WM_COMMAND → look up the item id → emit
//    "menu" {id} (custom) or run the role (Quit → close; Copy/Paste/etc. →
//    webview editing via ExecuteScript document.execCommand, or skip). Accelerators
//    via CreateAcceleratorTable + TranslateAcceleratorW in the loop. → _probe_menu.
// 9. WIRE-UP + TOOLING:
//    - app.odin: add the `when ODIN_OS == .Windows && !HEIMDALL_WEBVIEW` branch.
//    - doctor: check the WebView2 runtime (registry key
//      HKLM/HKCU\SOFTWARE\...\EdgeUpdate\Clients\{AA5FD9...} pv, or
//      GetAvailableCoreWebView2BrowserVersionString) + the loader lib.
//    - bundle: cmd_bundle_windows.odin (#+build windows) — package the .exe (+ a
//      .desktop-equiv is N/A; consider a .zip and/or MSI later) and signtool
//      hook (cmd_sign.odin already reserves the Windows path).
//    - docs: flip docs/platform_notes.md Windows section to IMPLEMENTED; update
//      internals.md, README/CLAUDE status, DEVELOPMENT.md Phase 7.
//
// Reply correlation, shim, and the `[name,args]` envelope are identical to macOS —
// reuse SHIM_JS_NATIVE and the darwin_handle_message logic verbatim.
//
// 10. CAPSTONE (once this backend works): REMOVE the vendored webview/webview
//     bootstrap ENTIRELY — all three platforms are native, which is strictly
//     better, so there's no --webview escape hatch to keep (decided). Delete
//     backend_webview.odin, the heimdall/webview package + libwebview.a +
//     build_lib.sh, the smoke example, the HEIMDALL_WEBVIEW define + every
//     --webview flag, and the create() else-fallback (native is the only backend).
//     Drops the C++ build dep and the committed binary; the framework becomes pure
//     Odin + the system webview.

// Substituted into SHIM_JS_NATIVE's __CHANNEL__ for the WebView2 message channel.
WINDOWS_CHANNEL :: "window.chrome.webview.postMessage(payload)"

WINDOWS_BACKEND_IMPLEMENTED :: false
