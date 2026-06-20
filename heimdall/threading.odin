package heimdall

// THE UI-THREAD RULE
// ==================
// All shell interaction — `eval`, resolving an invoke, emitting an event — MUST
// happen on the UI thread (the thread that called `run`). Work done on a worker
// thread that then needs to touch the shell must hop back via `dispatch_main`.
// Forgetting this is the single easiest way to get subtle, intermittent crashes.
//
// (Note: `emit` already routes through the backend's dispatch internally, so it
// is safe to call from any thread.)
//
// The mechanics of the main-thread hop live in the backend (e.g. webview's
// `webview_dispatch`); these are thin pass-throughs to the active backend.

// Schedule `fn` to run on the UI thread as soon as the event loop is free.
// Safe to call from any thread. `user` is passed through untouched.
dispatch_main :: proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr = nil) {
	app.backend.dispatch(app, fn, user)
}

// Stop the event loop and let `run` return. Thread-safe.
terminate :: proc(app: ^App) {
	app.backend.terminate(app)
}
