// Headless self-test for asset embedding/serving. Builds a two-file "dist"
// (index.html + app.js) as an in-memory asset map, lets `run` start the loopback
// server and navigate to it. app.js (fetched as a SEPARATE http request, proving
// multi-asset serving + MIME) calls greet, then reports the result AND the page
// origin — which must be http://127.0.0.1:<port>, proving it came off the server
// rather than set_html.
//
//   odin run examples/_probe_assets -collection:src=.   # -> /tmp/heimdall_probe_assets.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import hd "src:heimdall"

PROBE_OUT :: "/tmp/heimdall_probe_assets.json"

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

Report_Args :: struct {
	greet:  string,
	origin: string,
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

INDEX_HTML :: `<!doctype html><html><head><meta charset="utf-8">
<title>assets probe</title><script src="app.js" defer></script></head>
<body><h1>assets</h1></body></html>`

APP_JS :: `(async function () {
  var H = window.heimdall;
  var msg = "";
  try { var r = await H.invoke("greeting.greet", { name: "Assets" }); msg = r.message; }
  catch (e) { msg = "ERR:" + e; }
  await H.invoke("greeting.report", { greet: msg, origin: location.origin });
})();`

main :: proc() {
	assets := make(map[string]hd.Asset)
	assets["index.html"] = hd.Asset {
		data = transmute([]u8)string(INDEX_HTML),
	}
	assets["app.js"] = hd.Asset {
		data = transmute([]u8)string(APP_JS),
	}

	app, err := hd.create(
		hd.App_Config{title = "assets-probe", width = 320, height = 200, assets = assets},
	)
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	greeting := Greeting{prefix = "Hello, "}
	g := hd.service(app, "greeting", &greeting)
	hd.command(g, "greet", greet)
	hd.command(g, "report", report)

	hd.run(app) // prod path: starts the loopback server + navigates to it
}
