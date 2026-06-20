// Package webview — thin Odin bindings to the webview/webview C API.
//
// Vendored upstream: webview/webview 0.12.0 (see lib/upstream/VENDOR.txt).
// Rebuild the static lib with lib/build_lib.sh.
//
// This is a *direct* binding: one Odin proc per C entry point, names matching
// the C `webview_*` functions with the prefix stripped (link_prefix). The
// framework (package heimdall) wraps these behind its internal backend vtable;
// user code never imports this package directly.
//
// FFI callback rule: any proc passed to `bind` or `dispatch` crosses the C
// boundary, so it MUST be `proc "c"` and MUST establish an Odin `context` (e.g.
// `context = runtime.default_context()` or a stored app context) before calling
// anything that touches an allocator, the logger, or temp storage.
package webview

import "core:c"

when ODIN_OS == .Darwin {
	// libc++ for the C++ implementation; WebKit + Cocoa for WKWebView.
	foreign import lib {
		"lib/libwebview.a",
		"system:c++",
		"system:WebKit.framework",
		"system:Cocoa.framework",
	}
} else when ODIN_OS == .Linux {
	// STUB (not yet exercised — macOS is the current focus).
	// Requires libwebview.a built against WebKitGTK 4.1 and its link deps.
	// Build the lib with lib/build_lib.sh on Linux, then add the pkg-config
	// libs here (or via -extra-linker-flags). See DEVELOPMENT.md Phase 0.
	foreign import lib {
		"lib/libwebview.a",
		"system:stdc++",
	}
} else when ODIN_OS == .Windows {
	// STUB (not yet exercised). Requires webview.lib + the WebView2 loader.
	// See DEVELOPMENT.md Phase 7 for the native WebView2 path.
	foreign import lib {
		"lib/webview.lib",
	}
}

// Opaque handle (C `webview_t`).
Webview :: distinct rawptr

// Mirrors C `webview_error_t`. `.Ok` (0) is success; negatives are failures,
// positives are informational. The framework maps non-Ok values into its own
// Error union.
Error :: enum c.int {
	Missing_Dependency = -5,
	Canceled           = -4,
	Invalid_State      = -3,
	Invalid_Argument   = -2,
	Unspecified        = -1,
	Ok                 = 0,
	Duplicate          = 1,
	Not_Found          = 2,
}

// Window size hints (C `webview_hint_t`).
Hint :: enum c.int {
	None  = 0, // width/height are the default size
	Min   = 1, // width/height are minimum bounds
	Max   = 2, // width/height are maximum bounds
	Fixed = 3, // window size cannot be changed by the user
}

// Native handle kinds (C `webview_native_handle_kind_t`).
Native_Handle_Kind :: enum c.int {
	UI_Window           = 0, // NSWindow* / GtkWindow* / HWND
	UI_Widget           = 1, // NSView*   / GtkWidget* / HWND
	Browser_Controller  = 2, // WKWebView* / WebKitWebView* / ICoreWebView2Controller*
}

// Version info struct (C `webview_version_info_t`). Layout must match upstream.
Version :: struct {
	major:    c.uint,
	minor:    c.uint,
	patch:    c.uint,
}

Version_Info :: struct {
	version:        Version,
	version_number: [32]c.char,
	pre_release:    [48]c.char,
	build_metadata: [48]c.char,
}

// FFI callback signatures — both must be `proc "c"`.
//
// Dispatch_Proc runs on the UI thread (see `dispatch`).
Dispatch_Proc :: #type proc "c" (w: Webview, arg: rawptr)
// Bind_Proc receives a request: `id` correlates the call (pass back to
// `resolve`), `req` is a JSON array string of the JS call arguments.
Bind_Proc :: #type proc "c" (id: cstring, req: cstring, arg: rawptr)

@(default_calling_convention = "c", link_prefix = "webview_")
foreign lib {
	// Create a webview. `debug` enables devtools/inspector where supported.
	// `window` may be nil (webview creates its own window) or a native handle.
	create :: proc(debug: c.int, window: rawptr) -> Webview ---

	// Destroy and free the webview.
	destroy :: proc(w: Webview) -> Error ---

	// Run the main event loop until the window is closed. Blocks.
	run :: proc(w: Webview) -> Error ---

	// Stop the event loop. Thread-safe — one of two calls safe off-UI-thread.
	terminate :: proc(w: Webview) -> Error ---

	// Post `fn` to run on the UI thread. Thread-safe — the other off-thread-safe
	// call. This is the foundation of the framework's dispatch_main.
	dispatch :: proc(w: Webview, fn: Dispatch_Proc, arg: rawptr) -> Error ---

	// Native window handle (NSWindow* on macOS).
	get_window :: proc(w: Webview) -> rawptr ---

	// Native handle of the requested kind.
	get_native_handle :: proc(w: Webview, kind: Native_Handle_Kind) -> rawptr ---

	set_title :: proc(w: Webview, title: cstring) -> Error ---
	set_size  :: proc(w: Webview, width, height: c.int, hints: Hint) -> Error ---
	navigate  :: proc(w: Webview, url: cstring) -> Error ---
	set_html  :: proc(w: Webview, html: cstring) -> Error ---

	// Inject JS to run on every page load, before the page's own scripts.
	// Used to install the __HEIMDALL__ shim.
	init :: proc(w: Webview, js: cstring) -> Error ---

	// Evaluate JS in the current page. Used to push events / resolve promises.
	// UI-thread only.
	eval :: proc(w: Webview, js: cstring) -> Error ---

	// Bind a native callback callable from JS as `window.<name>(...)`, returning
	// a Promise. `fn` receives (id, req_json, arg); reply with `resolve`.
	bind :: proc(w: Webview, name: cstring, fn: Bind_Proc, arg: rawptr) -> Error ---

	// Remove a binding.
	unbind :: proc(w: Webview, name: cstring) -> Error ---

	// Version info for the linked library.
	version :: proc() -> ^Version_Info ---
}

// `webview_return` — `return` is an Odin keyword, so bind it under a new name.
// status 0 resolves the JS Promise, non-zero rejects it; `result` is JSON.
@(default_calling_convention = "c")
foreign lib {
	@(link_name = "webview_return")
	resolve :: proc(w: Webview, id: cstring, status: c.int, result: cstring) ---
}
