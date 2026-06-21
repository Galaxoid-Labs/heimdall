package heimdall

import "core:encoding/json"
import "core:strings"

// Backend-agnostic bridge helpers. The inbound-request flow itself lives in
// `backend_on_request` (backend.odin); the per-backend native callback that
// feeds it lives in each backend file (e.g. backend_darwin.odin). These two
// helpers — parsing the request envelope and encoding a rejection — are pure and
// shared by all backends.

// Request limits. The request JSON comes from the webview, so guard against a
// hostile payload BEFORE handing it to `json.parse` — the parser is recursive, so
// deeply-nested input would otherwise overflow the stack and crash the process
// (a DoS). Oversized input is rejected for the same reason.
@(private = "file")
MAX_REQUEST_BYTES :: 16 << 20 // 16 MiB
@(private = "file")
MAX_NESTING :: 200 // brackets deep; legitimate command args never approach this

// Cheap O(n) pre-scan: reject if the request is too large or nests too deeply.
// Brackets inside JSON strings don't count (tracks string + escape state).
@(private = "file")
within_limits :: proc(req: string) -> bool {
	if len(req) > MAX_REQUEST_BYTES {
		return false
	}
	depth := 0
	in_str := false
	escaped := false
	for i in 0 ..< len(req) {
		c := req[i]
		if in_str {
			if escaped {escaped = false} else if c == '\\' {escaped = true} else if c == '"' {in_str = false}
			continue
		}
		switch c {
		case '"':
			in_str = true
		case '[', '{':
			depth += 1
			if depth > MAX_NESTING {return false}
		case ']', '}':
			depth -= 1
		}
	}
	return true
}

// Split a bind request — a JSON array `["name", args?]` — into the command name
// and the args sub-object re-serialized as a JSON string (what the thunk
// unmarshals into the concrete Args type). Uses temp allocation.
parse_request :: proc(req: string) -> (name: string, args_json: string, err: Error) {
	if !within_limits(req) {
		return "", "", .Bad_Request_Json
	}
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

// Parse a native-backend wire message — the JSON object `{i, n, a}` (id, name,
// args) the shim posts via the platform message channel — into the id (as JSON)
// and the `["name", args]` request string `backend_on_request` expects. Shared by
// all native backends. Returns ok=false for malformed/oversized/over-nested input
// (the backend then drops the message). Applies the same `within_limits` guard as
// parse_request BEFORE `json.parse`, so the native delivery path can't be crashed
// by a deeply-nested payload either. Temp-allocated.
parse_native_message :: proc(body: string) -> (id_json: string, req_json: string, ok: bool) {
	if !within_limits(body) {
		return "", "", false
	}
	val, jerr := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	if jerr != .None {
		return "", "", false
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		return "", "", false
	}
	n_bytes, _ := json.marshal(obj["n"], allocator = context.temp_allocator)
	a_bytes, _ := json.marshal(obj["a"], allocator = context.temp_allocator)
	i_bytes, _ := json.marshal(obj["i"], allocator = context.temp_allocator)
	req_json = strings.concatenate({"[", string(n_bytes), ",", string(a_bytes), "]"}, context.temp_allocator)
	return string(i_bytes), req_json, true
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
