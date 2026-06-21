package heimdall

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

// Schema-dump mode (Phase 6). With `-define:HEIMDALL_SCHEMA=true`, `run` does NOT
// open a window: it walks the populated command registry AND the declared-event
// registry, introspects each command's Args/Result and each event's payload type
// via core:reflect, prints a JSON schema to stdout, and exits. `heimdall
// generate-bindings` runs the app this way and turns the JSON into a typed client.
//
// This works because the same RTTI core:encoding/json uses to (un)marshal is the
// single source of truth for the types we document — no chicken-and-egg, no
// separate source parser. Untyped `invoke` works without any of this.

// JSON shapes emitted to stdout. The CLI consumes these.
Schema :: struct {
	version:  string,
	services: []Schema_Service,
	events:   []Schema_Event,
}
Schema_Service :: struct {
	name:     string,
	commands: []Schema_Command,
}
Schema_Command :: struct {
	name:   string,
	args:   []Schema_Field,
	result: []Schema_Field,
}
Schema_Event :: struct {
	name:    string,
	payload: []Schema_Field, // fields of the declared payload type
}
Schema_Field :: struct {
	name: string,
	ts:   string, // TypeScript type, derived from the Odin type
}

// Build the schema from the registry and print it as JSON. Called by `run` in
// schema mode. Uses temp allocation throughout; the process exits right after.
@(private)
dump_schema :: proc(app: ^App) {
	alloc := context.temp_allocator

	// Group flat "service.command" keys back under their service.
	by_service: map[string][dynamic]Schema_Command
	by_service.allocator = alloc

	for key, thunk in app.registry {
		svc_name, cmd_name := split_command_key(key)
		// Skip reserved/internal commands (e.g. win.__ready) — they aren't part
		// of the public typed API.
		if strings.has_prefix(cmd_name, "_") {
			continue
		}
		cmds, ok := &by_service[svc_name]
		if !ok {
			by_service[svc_name] = make([dynamic]Schema_Command, alloc)
			cmds = &by_service[svc_name]
		}
		append(
			cmds,
			Schema_Command {
				name = cmd_name,
				args = fields_of(thunk.args_type, alloc),
				result = fields_of(thunk.result_type, alloc),
			},
		)
	}

	services := make([dynamic]Schema_Service, alloc)
	for name, cmds in by_service {
		append(&services, Schema_Service{name = name, commands = cmds[:]})
	}

	// Declared events (name -> payload type), for typed `on()`.
	events := make([dynamic]Schema_Event, alloc)
	for name, payload_type in app.events {
		append(&events, Schema_Event{name = name, payload = fields_of(payload_type, alloc)})
	}

	schema := Schema {
		version  = VERSION,
		services = services[:],
		events   = events[:],
	}
	data, err := json.marshal(schema, {pretty = true}, alloc)
	if err != nil {
		fmt.eprintfln("schema: marshal failed: %v", err)
		os.exit(1)
	}
	fmt.println(string(data))
}

// Split "service.command" on the first dot.
@(private)
split_command_key :: proc(key: string) -> (service: string, command: string) {
	dot := strings.index_byte(key, '.')
	if dot < 0 {
		return key, ""
	}
	return key[:dot], key[dot + 1:]
}

// Reflect a (struct) type into [{name, ts}] fields. Non-structs / empty structs
// yield an empty slice.
@(private)
fields_of :: proc(T: typeid, alloc: runtime.Allocator) -> []Schema_Field {
	names := reflect.struct_field_names(T)
	types := reflect.struct_field_types(T)
	n := min(len(names), len(types))
	out := make([dynamic]Schema_Field, 0, n, alloc)
	for i in 0 ..< n {
		append(&out, Schema_Field{name = names[i], ts = ts_type(types[i], alloc)})
	}
	return out[:]
}

// Map an Odin type to a TypeScript type string. Recursive: unwraps named types,
// turns slices/arrays into T[], and inlines nested structs as object literals.
@(private)
ts_type :: proc(ti: ^runtime.Type_Info, alloc: runtime.Allocator) -> string {
	if ti == nil {
		return "any"
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return ts_type(v.base, alloc)
	case runtime.Type_Info_Integer:
		return "number"
	case runtime.Type_Info_Float:
		return "number"
	case runtime.Type_Info_Boolean:
		return "boolean"
	case runtime.Type_Info_String:
		return "string"
	case runtime.Type_Info_Slice:
		return fmt.aprintf("%s[]", ts_type(v.elem, alloc), allocator = alloc)
	case runtime.Type_Info_Array:
		return fmt.aprintf("%s[]", ts_type(v.elem, alloc), allocator = alloc)
	case runtime.Type_Info_Dynamic_Array:
		return fmt.aprintf("%s[]", ts_type(v.elem, alloc), allocator = alloc)
	case runtime.Type_Info_Pointer:
		return ts_type(v.elem, alloc)
	case runtime.Type_Info_Struct:
		b := strings.builder_make(alloc)
		strings.write_string(&b, "{ ")
		for i in 0 ..< int(v.field_count) {
			if i > 0 {
				strings.write_string(&b, "; ")
			}
			strings.write_string(&b, v.names[i])
			strings.write_string(&b, ": ")
			strings.write_string(&b, ts_type(v.types[i], alloc))
		}
		strings.write_string(&b, " }")
		return strings.to_string(b)
	}
	return "any"
}
