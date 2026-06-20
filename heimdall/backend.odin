package heimdall

import "core:fmt"

// Internal backend abstraction — the seam that lets the native shell swap out
// without the bridge, services, events, or user code changing.
//
// Today the only implementation is `backend_webview.odin` (over webview/webview).
// The native backends — WKWebView (objc), WebKitGTK (C), WebView2 (COM) — will
// implement this same vtable in backend_darwin/linux/windows.odin. The framework
// only ever calls through `app.backend.*`; it never touches a concrete webview
// type.
//
// Two things flow the other way (backend -> framework), via the generic entry
// points at the bottom of this file: an inbound JS invoke (`backend_on_request`)
// and a UI-thread task the backend agreed to run (`backend_run_task`). Backends
// translate their native callbacks into these calls.

// Opaque per-request reply token. The backend defines what it really is (the
// webview backend stores the C `id` cstring); the framework treats it as a
// handle to pass back to `reply`.
Request_Id :: distinct rawptr

// The vtable. Every proc takes `^App` so implementations can reach their private
// state via `app.backend.impl`.
Backend :: struct {
	impl:      rawptr, // backend-private state (e.g. the webview handle)

	// True if the backend serves embedded assets itself (a custom app:// scheme),
	// so `run` should navigate to app://localhost/ instead of starting the
	// loopback Asset_Server. webview/webview has no custom-scheme API, so it
	// leaves this false and uses the loopback server.
	serves_assets: bool,

	set_title: proc(app: ^App, title: string),
	set_size:  proc(app: ^App, width, height: int, fixed: bool),

	// Window control (minimize/maximize/fullscreen/show/hide/focus/center/close).
	// One entry for the whole set; the per-platform switch lives in the backend.
	// Ops a platform can't honor (e.g. center/always-on-top under Wayland) no-op.
	window_op: proc(app: ^App, op: Window_Op),
	navigate:  proc(app: ^App, url: string),
	set_html:  proc(app: ^App, html: string),
	init_js:   proc(app: ^App, js: string), // inject before page load (the shim)
	eval:      proc(app: ^App, js: string), // run JS now (UI thread only)
	reply:     proc(app: ^App, id: Request_Id, ok: bool, json: string), // resolve/reject an invoke

	// Post a task to the UI thread. Safe to call from any thread.
	dispatch:  proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr),

	run:       proc(app: ^App), // run the event loop (blocks)
	terminate: proc(app: ^App), // stop the loop (thread-safe)
	destroy:   proc(app: ^App), // free backend resources
}

// ---- backend -> framework entry points ------------------------------------

// A backend calls this when JS invokes a command. `req_json` is the raw bind
// request (a JSON array `["service.command", args]`). Runs the thunk and replies
// through the backend. UI-thread, temp-allocated, freed per call.
backend_on_request :: proc(app: ^App, id: Request_Id, req_json: string) {
	context = app.ctx
	defer free_all(context.temp_allocator)

	name, args_json, perr := parse_request(req_json)
	if perr != nil {
		app.backend.reply(app, id, false, reject_json("malformed invoke request"))
		return
	}

	thunk, ok := app.registry[name]
	if !ok {
		app.backend.reply(app, id, false, reject_json(fmt.tprintf("unknown command: %s", name)))
		return
	}

	result_json, herr := thunk.invoke(thunk.state, thunk.handler, args_json, context.temp_allocator)
	if herr != nil {
		app.backend.reply(app, id, false, reject_json(fmt.tprintf("%v", herr)))
		return
	}
	app.backend.reply(app, id, true, result_json)
}
