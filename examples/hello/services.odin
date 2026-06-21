package main

import "core:fmt"
import hd "src:heimdall"

// A service is a plain struct holding state. Commands are procs over it.
Greeting :: struct {
	prefix: string,
}

Greet_Args :: struct {
	name: string,
}

Greet_Result :: struct {
	message: string,
}

// invoke("greeting.greet", {name}) -> {message}
greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
	return Greet_Result{message = fmt.tprintf("%s%s", s.prefix, args.name)}, nil
}

// An event payload. Declared with `hd.event(app, "greeting.tick", Tick)` so the
// generated bindings type `on("greeting.tick", t => ...)`.
Tick :: struct {
	count: int,
}

// A command that fails, to exercise the reject path (JS Promise rejection).
Boom_Args :: struct {}
Boom_Result :: struct {}

boom :: proc(s: ^Greeting, args: Boom_Args) -> (Boom_Result, hd.Error) {
	return {}, hd.Bridge_Error.Handler_Failed
}
