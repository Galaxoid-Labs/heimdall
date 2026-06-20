package heimdall

import "core:encoding/json"

// Backend-agnostic bridge helpers. The inbound-request flow itself lives in
// `backend_on_request` (backend.odin); the per-backend native callback that
// feeds it lives in each backend file (e.g. backend_darwin.odin). These two
// helpers — parsing the request envelope and encoding a rejection — are pure and
// shared by all backends.

// Split a bind request — a JSON array `["name", args?]` — into the command name
// and the args sub-object re-serialized as a JSON string (what the thunk
// unmarshals into the concrete Args type). Uses temp allocation.
parse_request :: proc(req: string) -> (name: string, args_json: string, err: Error) {
	val, jerr := json.parse(transmute([]u8)req, allocator = context.temp_allocator)
	if jerr != .None {
		return "", "", .Bad_Request_Json
	}
	arr, is_arr := val.(json.Array)
	if !is_arr || len(arr) < 1 {
		return "", "", .Bad_Request_Json
	}
	name_v, is_str := arr[0].(json.String)
	if !is_str {
		return "", "", .Bad_Request_Json
	}
	name = string(name_v)

	args_json = "{}"
	if len(arr) >= 2 {
		b, merr := json.marshal(arr[1], allocator = context.temp_allocator)
		if merr != nil {
			return "", "", .Bad_Request_Json
		}
		args_json = string(b)
	}
	return name, args_json, nil
}

// Encode an error message as a JSON string for a rejected invoke. (The JS side
// JSON.parses the reply before handing it to the Promise's reject callback, so
// the payload must be valid JSON.) Temp-allocated.
reject_json :: proc(msg: string) -> string {
	encoded, merr := json.marshal(msg, allocator = context.temp_allocator)
	if merr != nil {
		return "\"error\""
	}
	return string(encoded)
}
