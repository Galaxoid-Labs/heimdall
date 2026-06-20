package heimdall

import "core:c"
import "core:strings"
import wv "webview"

// The webview/webview backend — the default (and currently only) implementation
// of the Backend vtable. All webview/webview specifics are confined to this file
// and the `webview` package: the C trampolines, the cstring request id, and the
// `wv.*` calls. Native backends will provide their own file implementing the
// same vtable.

// Backend-private state stored in app.backend.impl.
@(private = "file")
Webview_Backend :: struct {
	handle: wv.Webview,
}

INVOKE_BINDING :: "__heimdall_invoke"

// Construct the webview backend, create the window, install the vtable on the
// app, inject the shim, and bind the single invoke entry point. Returns false on
// failure.
webview_backend_create :: proc(app: ^App, debug: bool) -> bool {
	impl := new(Webview_Backend, app.registry_allocator)
	impl.handle = wv.create(c.int(1 if debug else 0), nil)
	if impl.handle == nil {
		free(impl, app.registry_allocator)
		return false
	}

	app.backend = Backend {
		impl      = impl,
		set_title = wvb_set_title,
		set_size  = wvb_set_size,
		window_op = wvb_window_op,
		navigate  = wvb_navigate,
		set_html  = wvb_set_html,
		init_js   = wvb_init_js,
		eval      = wvb_eval,
		reply     = wvb_reply,
		dispatch  = wvb_dispatch,
		run       = wvb_run,
		terminate = wvb_terminate,
		destroy   = wvb_destroy,
	}

	wv.init(impl.handle, SHIM_JS)
	wv.bind(impl.handle, INVOKE_BINDING, wvb_invoke_cb, app)
	return true
}

@(private = "file")
handle :: proc(app: ^App) -> wv.Webview {
	return (cast(^Webview_Backend)app.backend.impl).handle
}

// ---- vtable procs ---------------------------------------------------------

@(private = "file")
wvb_set_title :: proc(app: ^App, title: string) {
	wv.set_title(handle(app), strings.clone_to_cstring(title, context.temp_allocator))
}

@(private = "file")
wvb_set_size :: proc(app: ^App, width, height: int, fixed: bool) {
	hint: wv.Hint = .Fixed if fixed else .None
	wv.set_size(handle(app), c.int(width), c.int(height), hint)
}

@(private = "file")
wvb_navigate :: proc(app: ^App, url: string) {
	wv.navigate(handle(app), strings.clone_to_cstring(url, context.temp_allocator))
}

@(private = "file")
wvb_set_html :: proc(app: ^App, html: string) {
	wv.set_html(handle(app), strings.clone_to_cstring(html, context.temp_allocator))
}

@(private = "file")
wvb_init_js :: proc(app: ^App, js: string) {
	wv.init(handle(app), strings.clone_to_cstring(js, context.temp_allocator))
}

@(private = "file")
wvb_eval :: proc(app: ^App, js: string) {
	wv.eval(handle(app), strings.clone_to_cstring(js, context.temp_allocator))
}

@(private = "file")
wvb_reply :: proc(app: ^App, id: Request_Id, ok: bool, json: string) {
	status: c.int = 0 if ok else 1
	cjson := strings.clone_to_cstring(json, context.temp_allocator)
	wv.resolve(handle(app), transmute(cstring)id, status, cjson)
}

// webview/webview's C API has no window-state control (minimize/maximize/etc.),
// so most ops are no-ops on this fallback backend — full window control needs a
// native backend. Only Close maps (stop the loop).
@(private = "file")
wvb_window_op :: proc(app: ^App, op: Window_Op) {
	#partial switch op {
	case .Close:
		wv.terminate(handle(app))
	}
}

@(private = "file")
wvb_run :: proc(app: ^App) {
	wv.run(handle(app))
}

@(private = "file")
wvb_terminate :: proc(app: ^App) {
	wv.terminate(handle(app))
}

@(private = "file")
wvb_destroy :: proc(app: ^App) {
	wv.destroy(handle(app))
	free(app.backend.impl, app.registry_allocator)
}

// ---- C trampolines (this is the only place we cross into `proc "c"`) -------

// JS invoke. webview hands us (id, req_json, app). Restore context, forward to
// the backend-agnostic request handler, which replies via wvb_reply.
@(private = "file")
wvb_invoke_cb :: proc "c" (id: cstring, req: cstring, arg: rawptr) {
	app := cast(^App)arg
	context = app.ctx
	backend_on_request(app, transmute(Request_Id)id, string(req))
}

// UI-thread dispatch. We can't pass an Odin closure across the C boundary, so we
// box {app, fn, user} and unbox it here.
@(private = "file")
Dispatch_Box :: struct {
	app:  ^App,
	fn:   proc(app: ^App, user: rawptr),
	user: rawptr,
}

@(private = "file")
wvb_dispatch :: proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr) {
	box := new(Dispatch_Box, app.event_allocator)
	box^ = Dispatch_Box{app = app, fn = fn, user = user}
	wv.dispatch(handle(app), wvb_dispatch_cb, box)
}

@(private = "file")
wvb_dispatch_cb :: proc "c" (w: wv.Webview, arg: rawptr) {
	box := cast(^Dispatch_Box)arg
	context = box.app.ctx
	box.fn(box.app, box.user)
	free(box, box.app.event_allocator)
}
