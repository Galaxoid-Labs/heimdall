// Headless self-test for the native menu bar. A custom menu item with a Cmd+1
// accelerator emits a "menu" event; JS reports it back. Triggered by a synthesized
// Cmd+1 keystroke (see the harness), which exercises the full
// NSMenuItem action -> emit -> JS on("menu") path.
//
//   odin run examples/_probe_menu -collection:src=.   (native is the default on macOS)
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_menu.json"

State :: struct {
	app: ^hd.App,
}

Report_Args :: struct {
	id: string,
}
Report_Result :: struct {}
report :: proc(s: ^State, args: Report_Args) -> (Report_Result, hd.Error) {
	data, _ := json.marshal(args, allocator = context.temp_allocator)
	_ = os.write_entire_file(PROBE_OUT, data)
	fmt.printfln("probe: wrote %s -> %s", PROBE_OUT, string(data))
	os.exit(0)
}

HTML :: `<!doctype html><html><head><meta charset="utf-8"></head><body>
<script>
  window.__HEIMDALL__.on("menu", function (e) {
    window.__HEIMDALL__.invoke("app.report", { id: e.id });
  });
</script></body></html>`

main :: proc() {
	app, err := hd.create(
		hd.App_Config {
			title = "probe-menu",
			width = 320,
			height = 200,
			menu = {
				{
					label = "File",
					submenu = {{label = "Fire", id = "probe.fire", accelerator = "Cmd+1"}},
				},
			},
		},
	)
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	st := State{app = app}
	a := hd.service(app, "app", &st)
	hd.command(a, "report", report)

	hd.set_html(app, HTML)
	hd.run(app)
}
