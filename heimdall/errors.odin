package heimdall

// The library's single Error type: a union of per-area enums. A `nil` Error
// means success — this is what command handlers return on the happy path
// (`return result, nil`). Propagate with `or_return`.
//
// Note: none of the member enums has a `None`/zero "success" variant on purpose.
// Success is the `nil` union, not an enum value — assigning any enum member to
// the union makes it non-nil (i.e. an error).
Error :: union {
	Bridge_Error,
	Webview_Error,
	Io_Error,
}

// Errors originating in the IPC bridge / dispatch path.
Bridge_Error :: enum {
	Unknown_Command = 1,
	Bad_Request_Json,
	Unmarshal_Args_Failed,
	Marshal_Result_Failed,
	Handler_Failed,
}

// Errors from the native webview shell.
Webview_Error :: enum {
	Create_Failed = 1,
	Eval_Failed,
}

// Errors from asset / IO / server paths (used from Phase 3 on).
Io_Error :: enum {
	Not_Found = 1,
	Read_Failed,
	Server_Failed,
}
