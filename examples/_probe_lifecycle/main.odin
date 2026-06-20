// Headless self-test for lifecycle hooks. on_startup sets a flag; JS asks Odin
// to quit (terminate), which ends the loop; on_shutdown then writes a proof file
// recording that BOTH hooks ran, in order. The process exits naturally (no
// os.exit), confirming on_shutdown runs after run() returns.
//
//   odin run examples/_probe_lifecycle -collection:src=.  # -> /tmp/heimdall_probe_lifecycle.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_lifecycle.json"

State :: struct {
	started:  bool,
	app:      ^hd.App,
}

Proof :: struct {
	startup_ran:  bool,
	shutdown_ran: bool,
}

@(private = "file")
g_state: State

on_startup :: proc(app: ^hd.App) -> hd.Error {
	g_state.started = true
	return nil
}

on_shutdown :: proc(app: ^hd.App) {
	proof := Proof {
		startup_ran  = g_state.started,
		shutdown_ran = true,
	}
	data, _ := json.marshal(proof, allocator = context.temp_allocator)
	if werr := os.write_entire_file(PROBE_OUT, data); werr != nil {
		fmt.eprintfln("probe: write failed: %v", werr)
		os.exit(2)
	}
	fmt.printfln("probe: wrote %s -> %s", PROBE_OUT, string(data))
}

Quit_Args :: struct {}
Quit_Result :: struct {}
quit :: proc(s: ^State, args: Quit_Args) -> (Quit_Result, hd.Error) {
	hd.terminate(s.app)
	return {}, nil
}

HTML :: `<!doctype html><html><head><meta charset="utf-8"></head><body>
<script>window.__HEIMDALL__.invoke("app.quit", {});</script></body></html>`

main :: proc() {
	app, err := hd.create(
		hd.App_Config {
			title = "lifecycle-probe",
			width = 320,
			height = 200,
			on_startup = on_startup,
			on_shutdown = on_shutdown,
		},
	)
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	g_state.app = app
	a := hd.service(app, "app", &g_state)
	hd.command(a, "quit", quit)

	hd.set_html(app, HTML)
	hd.run(app)
}
