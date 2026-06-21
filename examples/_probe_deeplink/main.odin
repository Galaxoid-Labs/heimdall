// Headless self-test for deep linking: the cold-start delivery path. Simulates an
// incoming URL arriving before the frontend is ready (deliver_open_url queues the
// event and fires the on_open_url hook immediately). Once the page loads, the
// shim sends win.__ready, Odin flushes the queued "open-url" event, and JS
// reports back both what the hook saw and what the event saw.
//
//   odin run examples/_probe_deeplink -collection:src=.   -> /tmp/heimdall_probe_deeplink.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_deeplink.json"
URL :: "myapp://probe/path?x=1"

State :: struct {
	hook_saw: string, // set by the on_open_url hook (fires immediately)
}
g: State

on_open_url :: proc(app: ^hd.App, url: string) {
	g.hook_saw = url
}

Report_Args :: struct {
	event_saw: string, // what JS on("open-url") received
}
Report_Result :: struct {}
report :: proc(s: ^State, args: Report_Args) -> (Report_Result, hd.Error) {
	out := struct {
		hook_saw:  string,
		event_saw: string,
	}{g.hook_saw, args.event_saw}
	data, _ := json.marshal(out, allocator = context.temp_allocator)
	_ = os.write_entire_file(PROBE_OUT, data)
	fmt.printfln("probe: wrote %s -> %s", PROBE_OUT, string(data))
	os.exit(0)
}

HTML :: `<!doctype html><html><head><meta charset="utf-8"></head><body>
<script>
  window.__HEIMDALL__.on("open-url", function (e) {
    window.__HEIMDALL__.invoke("probe.report", { event_saw: e.url });
  });
</script></body></html>`

main :: proc() {
	app, err := hd.create(
		hd.App_Config {
			title = "probe-deeplink",
			width = 320,
			height = 200,
			url_schemes = {"myapp"},
			on_open_url = on_open_url,
		},
	)
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	p := hd.service(app, "probe", &g)
	hd.command(p, "report", report)

	// Simulate a cold-start deep link arriving before the frontend is ready:
	// the hook fires now; the event is queued and flushed after win.__ready.
	hd.deliver_open_url(app, URL)

	hd.set_html(app, HTML)
	hd.run(app)
}
