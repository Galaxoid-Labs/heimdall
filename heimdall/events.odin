package heimdall

import "base:runtime"
import "core:encoding/json"
import "core:strings"

// The event bus — the push direction (Odin -> JS), complementing request/
// response `invoke`. Fire-and-forget: no ack, no return value. Use it for
// progress, background-task completion, and multi-window state sync.
//
//   Progress :: struct { read, total: int }
//   emit(app, "file.progress", Progress{ read = 512, total = 1000 })
//
// On the JS side:
//   const off = __HEIMDALL__.on("file.progress", p => updateBar(p.read, p.total))
//
// TYPED EVENTS (optional). `emit`/`on` accept any name + payload. To get a typed
// `on()` in the generated `.d.ts`, declare the event's payload type once with
// `event()` — same idea as `command()` for invoke. It records name -> payload
// type so schema-dump (generate-bindings) can reflect it:
//
//   Progress :: struct { read, total: int }
//   event(app, "file.progress", Progress)   // -> on("file.progress", p => ...) typed

// A queued emit: the fully-rendered `__HEIMDALL__._event(...)` JS call, owned by
// `alloc` and freed once it has run on the UI thread.
@(private)
Emit_Job :: struct {
	js:    string,
	alloc: runtime.Allocator,
}

// Emit an event with any JSON-marshalable payload. Safe to call from any thread:
// it marshals now, then hops onto the UI thread (via the backend's dispatch) to
// run the eval. Returns an Error only if marshalling fails.
emit :: proc(app: ^App, name: string, payload: $T) -> Error {
	alloc := app.event_allocator

	// Marshal the payload — it becomes a JS expression verbatim (JSON is valid JS).
	payload_json, perr := json.marshal(payload, allocator = alloc)
	if perr != nil {
		return .Marshal_Result_Failed
	}
	defer delete(payload_json, alloc)

	// Marshal the name too, so it lands as a correctly-quoted/escaped JS string.
	name_json, nerr := json.marshal(name, allocator = alloc)
	if nerr != nil {
		return .Marshal_Result_Failed
	}
	defer delete(name_json, alloc)

	// __HEIMDALL__._event(<name>, <payload>)
	js := strings.concatenate(
		{"window.__HEIMDALL__._event(", string(name_json), ",", string(payload_json), ")"},
		alloc,
	)

	job := new(Emit_Job, alloc)
	job^ = Emit_Job{js = js, alloc = alloc}
	app.backend.dispatch(app, emit_run, job)
	return nil
}

// Declare an event's payload type, so `heimdall generate-bindings` emits a typed
// `on()` for it. Optional and additive — `emit` and `on` work for any name
// without ever declaring it. Pass the payload type by name:
//
//   event(app, "file.progress", Progress)
//
// Re-declaring a name just updates its type (the key is interned once).
event :: proc(app: ^App, name: string, T: typeid) {
	if _, ok := app.events[name]; ok {
		app.events[name] = T
		return
	}
	app.events[strings.clone(name, app.registry_allocator)] = T
}

// Runs on the UI thread (via the backend dispatch trampoline, which restores the
// context). Evals the event JS, then frees the job.
@(private)
emit_run :: proc(app: ^App, user: rawptr) {
	job := cast(^Emit_Job)user
	app.backend.eval(app, job.js)
	delete(job.js, job.alloc)
	free(job, job.alloc)
}
