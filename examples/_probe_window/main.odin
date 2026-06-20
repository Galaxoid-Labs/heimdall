// Headless self-test for the built-in `win` window-control service. On load, JS
// calls a sequence of win.* commands and records whether each resolved; the
// result is written to a file and the app exits. Verifies the service is
// registered and every window op round-trips without error (visual state — actual
// minimize/maximize/fullscreen — is left to manual/visual checks).
//
//   odin run examples/_probe_window -collection:src=.   # -> /tmp/heimdall_probe_window.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_window.json"

State :: struct {}

Report :: struct {
	set_title:      string,
	maximize:       string,
	unmaximize:     string,
	fullscreen_on:  string,
	fullscreen_off: string,
	center:         string,
	focus:          string,
}
Report_Result :: struct {}
report :: proc(s: ^State, r: Report) -> (Report_Result, hd.Error) {
	data, _ := json.marshal(r, allocator = context.temp_allocator)
	if werr := os.write_entire_file(PROBE_OUT, data); werr != nil {
		fmt.eprintfln("probe: write failed: %v", werr)
		os.exit(2)
	}
	fmt.printfln("probe: wrote %s -> %s", PROBE_OUT, string(data))
	os.exit(0)
}

HTML :: `<!doctype html><html><head><meta charset="utf-8"></head><body>
<script>
  (async function () {
    var H = window.__HEIMDALL__;
    async function call(name, args) {
      try { await H.invoke(name, args || {}); return "ok"; }
      catch (e) { return "ERR:" + e; }
    }
    var r = {};
    r.set_title      = await call("win.set_title", { title: "Window Probe" });
    r.maximize       = await call("win.maximize");
    r.unmaximize     = await call("win.unmaximize");
    r.fullscreen_on  = await call("win.fullscreen", { on: true });
    r.fullscreen_off = await call("win.fullscreen", { on: false });
    r.center         = await call("win.center");
    r.focus          = await call("win.focus");
    await H.invoke("probe.report", r);
  })();
</script>
</body></html>`

main :: proc() {
	app, err := hd.create(hd.App_Config{title = "win-probe", width = 320, height = 200})
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	st := State{}
	p := hd.service(app, "probe", &st)
	hd.command(p, "report", report)

	hd.set_html(app, HTML)
	hd.run(app)
}
