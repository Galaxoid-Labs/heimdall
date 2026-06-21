// Headless allocator-hygiene check. Wraps everything in a tracking allocator,
// runs several invoke round-trips on the UI thread, then quits and reports the
// number of leaked allocations + bad frees. Expect zero — the bridge hot path
// uses temp storage (freed per call) and create/destroy balance their heap use.
//
// Single-threaded on purpose (set_html, no server, no worker emits) so the
// tracking allocator isn't touched concurrently.
//
//   odin run examples/_probe_alloc -collection:src=.   # -> /tmp/heimdall_probe_alloc.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_alloc.json"

State :: struct {
	app: ^hd.App,
}

Greet_Args :: struct {
	name: string,
}
Greet_Result :: struct {
	message: string,
}
greet :: proc(s: ^State, args: Greet_Args) -> (Greet_Result, hd.Error) {
	return Greet_Result{message = fmt.tprintf("Hi %s", args.name)}, nil
}

Quit_Args :: struct {}
Quit_Result :: struct {}
quit :: proc(s: ^State, args: Quit_Args) -> (Quit_Result, hd.Error) {
	hd.terminate(s.app)
	return {}, nil
}

HTML :: `<!doctype html><html><head><meta charset="utf-8"></head><body><script>
(async function () {
  var H = window.heimdall;
  for (var i = 0; i < 5; i++) { await H.invoke("svc.greet", { name: "n" + i }); }
  H.invoke("svc.quit", {});
})();
</script></body></html>`

Report :: struct {
	leaks:     int,
	bad_frees: int,
}

g_state: State

run_app :: proc() {
	app, err := hd.create(hd.App_Config{title = "alloc-probe", width = 320, height = 200})
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	g_state.app = app
	svc := hd.service(app, "svc", &g_state)
	hd.command(svc, "greet", greet)
	hd.command(svc, "quit", quit)

	hd.set_html(app, HTML)
	hd.run(app)
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	run_app() // returns when JS calls svc.quit -> terminate

	report := Report {
		leaks     = len(track.allocation_map),
		bad_frees = len(track.bad_free_array),
	}
	for _, entry in track.allocation_map {
		fmt.eprintfln("LEAK: %d bytes @ %v", entry.size, entry.location)
	}
	data, _ := json.marshal(report, allocator = context.temp_allocator)
	_ = os.write_entire_file(PROBE_OUT, data)
	fmt.printfln("probe: wrote %s -> %s", PROBE_OUT, string(data))

	mem.tracking_allocator_destroy(&track)
}
