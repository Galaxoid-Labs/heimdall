// Headless self-test for the event bus + threading. JS subscribes to "tick",
// then asks Odin to start a WORKER THREAD that emits N tick events. The handler
// collects them; on the last one it reports the sequence back, which is written
// to a file and the app exits. Verifies: on() fan-out, emit() from a non-UI
// thread, the dispatch_main hop, and payload integrity/ordering.
//
//   odin run examples/_probe_events -collection:src=.   # -> /tmp/heimdall_probe_events.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:thread"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_events.json"
TICKS :: 5

Probe :: struct {
	app: ^hd.App,
}

Tick :: struct {
	n:     int,
	total: int,
}

// Runs on a worker thread (NOT the UI thread) — proves emit() is thread-safe.
worker :: proc(app: ^hd.App) {
	for i in 0 ..< TICKS {
		hd.emit(app, "tick", Tick{n = i + 1, total = TICKS})
	}
}

Start_Args :: struct {}
Start_Result :: struct {}
start :: proc(s: ^Probe, args: Start_Args) -> (Start_Result, hd.Error) {
	thread.create_and_start_with_poly_data(s.app, worker, s.app.ctx, self_cleanup = true)
	return {}, nil
}

Report_Args :: struct {
	ticks: []int,
}
Report_Result :: struct {}
report :: proc(s: ^Probe, args: Report_Args) -> (Report_Result, hd.Error) {
	data, _ := json.marshal(args, allocator = context.temp_allocator)
	if werr := os.write_entire_file(PROBE_OUT, data); werr != nil {
		fmt.eprintfln("probe: write failed: %v", werr)
		os.exit(2)
	}
	fmt.printfln("probe: wrote %s -> %s", PROBE_OUT, string(data))
	os.exit(0)
}

HTML :: `
<!doctype html><html><head><meta charset="utf-8"></head><body>
<script>
  var H = window.__HEIMDALL__;
  var ticks = [];
  H.on("tick", function (p) {
    ticks.push(p.n);
    if (ticks.length >= p.total) {
      H.invoke("probe.report", { ticks: ticks });
    }
  });
  H.invoke("probe.start", {});
</script>
</body></html>
`

main :: proc() {
	app, err := hd.create(hd.App_Config{title = "probe-events", width = 320, height = 200})
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	probe := Probe{app = app}
	p := hd.service(app, "probe", &probe)
	hd.command(p, "start", start)
	hd.command(p, "report", report)

	hd.set_html(app, HTML)
	hd.run(app)
}
