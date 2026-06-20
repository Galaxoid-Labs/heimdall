package heimdall

// Window control — a unified, platform-agnostic API. The public procs and the
// built-in `win` service below never branch on OS; each backend implements the
// single `window_op` vtable entry (see backend.odin) for its platform, so the
// switch-on-platform lives entirely under the seam.
//
// Two ways to drive the window:
//   * from Odin — `window_minimize(app)`, `window_set_fullscreen(app, true)`, …
//   * from JS   — the built-in `win` service: `invoke("win.minimize")` or, with
//                 generated bindings, `import { win } from "./heimdall.gen.js"`
//                 then `win.minimize()`.
//
// Some operations can't be honored on every platform (e.g. Wayland forbids a
// client from positioning or always-on-topping its own window) — those degrade
// to a no-op rather than erroring. See docs/platform_notes.md.

// The set of window operations a backend must handle in `window_op`.
Window_Op :: enum {
	Minimize,
	Maximize,
	Unmaximize,
	Fullscreen_On,
	Fullscreen_Off,
	Show,
	Hide,
	Focus,
	Center,
	Close,
}

// ---- public Odin API ------------------------------------------------------

window_minimize :: proc(app: ^App) {win_do(app, .Minimize)}
window_maximize :: proc(app: ^App) {win_do(app, .Maximize)}
window_unmaximize :: proc(app: ^App) {win_do(app, .Unmaximize)}
window_show :: proc(app: ^App) {win_do(app, .Show)}
window_hide :: proc(app: ^App) {win_do(app, .Hide)}
window_focus :: proc(app: ^App) {win_do(app, .Focus)}
window_center :: proc(app: ^App) {win_do(app, .Center)}

window_set_fullscreen :: proc(app: ^App, on: bool) {
	win_do(app, .Fullscreen_On if on else .Fullscreen_Off)
}

window_set_title :: proc(app: ^App, title: string) {
	if !app.backend_ready {return}
	app.backend.set_title(app, title)
}

window_set_size :: proc(app: ^App, width, height: int) {
	if !app.backend_ready {return}
	app.backend.set_size(app, width, height, !app.cfg.resizable)
}

// Close the window — honors `should_quit` (a vetoed close is a no-op), then ends
// the event loop so `run` returns (and `on_shutdown` fires), matching the
// behavior of the user clicking the window's close button.
window_close :: proc(app: ^App) {
	if app.cfg.should_quit != nil && !app.cfg.should_quit(app) {return}
	win_do(app, .Close)
}

@(private = "file")
win_do :: proc(app: ^App, op: Window_Op) {
	if !app.backend_ready {return} // no shell in schema-dump mode
	app.backend.window_op(app, op)
}

// ---- built-in `win` service (window control from the frontend) ------------
//
// Registered automatically in `create`. Exposed to JS as `invoke("win.<cmd>")`
// and, with generated bindings, as the `win` namespace. The name `win` is
// RESERVED — don't register your own service called `win`.

@(private = "file")
Win_Empty :: struct {}
@(private = "file")
Win_On :: struct {
	on: bool,
}
@(private = "file")
Win_Title :: struct {
	title: string,
}
@(private = "file")
Win_Size :: struct {
	width:  int,
	height: int,
}

@(private = "file")
win_c_minimize :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_minimize(app);return {}, nil}
@(private = "file")
win_c_maximize :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_maximize(app);return {}, nil}
@(private = "file")
win_c_unmaximize :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_unmaximize(app);return {}, nil}
@(private = "file")
win_c_show :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_show(app);return {}, nil}
@(private = "file")
win_c_hide :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_hide(app);return {}, nil}
@(private = "file")
win_c_focus :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_focus(app);return {}, nil}
@(private = "file")
win_c_center :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_center(app);return {}, nil}
@(private = "file")
win_c_close :: proc(app: ^App, _: Win_Empty) -> (Win_Empty, Error) {window_close(app);return {}, nil}
@(private = "file")
win_c_fullscreen :: proc(app: ^App, a: Win_On) -> (Win_Empty, Error) {window_set_fullscreen(app, a.on);return {}, nil}
@(private = "file")
win_c_set_title :: proc(app: ^App, a: Win_Title) -> (Win_Empty, Error) {window_set_title(app, a.title);return {}, nil}
@(private = "file")
win_c_set_size :: proc(app: ^App, a: Win_Size) -> (Win_Empty, Error) {window_set_size(app, a.width, a.height);return {}, nil}

// Register the built-in `win` service. Called from `create` once the backend is
// ready. State is the App itself, so handlers reach the backend directly.
@(private)
register_window_service :: proc(app: ^App) {
	w := service(app, "win", app)
	command(w, "minimize", win_c_minimize)
	command(w, "maximize", win_c_maximize)
	command(w, "unmaximize", win_c_unmaximize)
	command(w, "show", win_c_show)
	command(w, "hide", win_c_hide)
	command(w, "focus", win_c_focus)
	command(w, "center", win_c_center)
	command(w, "close", win_c_close)
	command(w, "fullscreen", win_c_fullscreen)
	command(w, "set_title", win_c_set_title)
	command(w, "set_size", win_c_set_size)
}
