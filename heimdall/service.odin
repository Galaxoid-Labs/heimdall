package heimdall

import "core:encoding/json"
import "core:mem"
import "core:strings"

// A Thunk is the type-erased form of a registered command. The polymorphic
// `command()` monomorphizes `invoke` for the concrete (S, A, R) types, then
// stores it here keyed by "service.command". At dispatch time the bridge calls
// `invoke(state, handler, args_json)` with everything as `rawptr` — no generics
// at the call site, all the type knowledge baked into the proc body.
Thunk :: struct {
	state:   rawptr, // ^S, the service state (caller-owned, lives in main)
	handler: rawptr, // the user's proc(^S, A) -> (R, Error)
	invoke:  proc(state, handler: rawptr, args_json: string, alloc: mem.Allocator) -> (result_json: string, err: Error),

	// Captured for Phase 6 schema-dump (typed binding generation).
	args_type:   typeid,
	result_type: typeid,
}

// A handle to a registered service: a named, stateful namespace. Returned by
// `service()`, consumed by `command()`. Carries the app + service name + an
// erased pointer to the service state so commands can be wired to it.
Service_Handle :: struct {
	app:   ^App,
	name:  string,
	state: rawptr,
}

// Register a service: a named namespace backed by a caller-owned state struct.
// The state pointer must outlive the app (typically a local in `main`).
service :: proc(app: ^App, name: string, state: ^$S) -> Service_Handle {
	return Service_Handle{app = app, name = name, state = rawptr(state)}
}

// Register a command under a service. `handler` is an ordinary Odin proc taking
// (^S, A) and returning (R, Error), where A/R are JSON-marshalable. The
// unmarshal→call→marshal glue is generated here at compile time from the
// handler's own types — no macros, no runtime attribute reflection.
command :: proc(svc: Service_Handle, name: string, handler: proc(s: ^$S, args: $A) -> ($R, Error)) {
	// Monomorphized per (S, A, R). References the enclosing type params, so each
	// instantiation gets its own concrete unmarshal/marshal.
	invoke :: proc(state_raw, handler_raw: rawptr, args_json: string, alloc: mem.Allocator) -> (string, Error) {
		h := cast(proc(s: ^S, args: A) -> (R, Error))handler_raw
		state := cast(^S)state_raw

		args: A
		if err := json.unmarshal(transmute([]u8)args_json, &args, allocator = alloc); err != nil {
			return "", .Unmarshal_Args_Failed
		}

		result, herr := h(state, args)
		if herr != nil {
			return "", herr
		}

		out, merr := json.marshal(result, allocator = alloc)
		if merr != nil {
			return "", .Marshal_Result_Failed
		}
		return string(out), nil
	}

	key := strings.concatenate({svc.name, ".", name}, svc.app.registry_allocator)
	svc.app.registry[key] = Thunk {
		state       = svc.state,
		handler     = rawptr(handler),
		invoke      = invoke,
		args_type   = A,
		result_type = R,
	}
}
