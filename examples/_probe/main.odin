// Headless self-test for the bridge. On load, JS calls greeting.greet, then
// exercises the reject path, then reports both back through probe.report, which
// writes the result to a file and exits. Lets CI verify the full invoke
// round-trip (both directions, success + reject) with no clicking.
//
//   odin run examples/_probe -collection:src=.   # writes /tmp/heimdall_probe.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe.json"

Greeting :: struct {
	prefix: string,
}
Greet_Args :: struct {
	name: string,
}
Greet_Result :: struct {
	message: string,
}

greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
	return Greet_Result{message = fmt.tprintf("%s%s", s.prefix, args.name)}, nil
}

Boom_Args :: struct {}
Boom_Result :: struct {}
boom :: proc(s: ^Greeting, args: Boom_Args) -> (Boom_Result, hd.Error) {
	return {}, hd.Bridge_Error.Handler_Failed
}

Report_Args :: struct {
	greet:    string,
	rejected: string,
}
Report_Result :: struct {}

report :: proc(s: ^Greeting, args: Report_Args) -> (Report_Result, hd.Error) {
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
  (async function () {
    var H = window.__HEIMDALL__;
    var greetMsg = "", rejected = "";
    try { var r = await H.invoke("greeting.greet", { name: "Probe" }); greetMsg = r.message; }
    catch (e) { greetMsg = "ERR:" + e; }
    try { await H.invoke("greeting.boom", {}); rejected = "NOT_REJECTED"; }
    catch (e) { rejected = String(e); }
    await H.invoke("greeting.report", { greet: greetMsg, rejected: rejected });
  })();
</script>
</body></html>
`

main :: proc() {
	app, err := hd.create(hd.App_Config{title = "probe", width = 320, height = 200})
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	greeting := Greeting{prefix = "Hello, "}
	g := hd.service(app, "greeting", &greeting)
	hd.command(g, "greet", greet)
	hd.command(g, "boom", boom)
	hd.command(g, "report", report)

	hd.set_html(app, HTML)
	hd.run(app)
}
