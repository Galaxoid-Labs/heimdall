// Heimdall "hello" example — one service, one command, a button.
// Self-contained: inline HTML via set_html, so no bundler/server is needed.
//
// Run from the repo root:
//   odin run examples/hello -collection:src=.
package main

import "core:fmt"
import "core:os"
import hd "src:heimdall"

HTML :: `
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Heimdall Hello</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; padding: 2rem; }
  input, button { font-size: 1rem; padding: .4rem .6rem; }
  #out { margin-top: 1rem; font-weight: 600; min-height: 1.4em; }
  #err { margin-top: .5rem; color: #b00; }
</style></head>
<body>
  <h2>Heimdall bridge</h2>
  <input id="name" placeholder="your name" value="Jake">
  <button id="go">greet</button>
  <button id="bang">boom (reject)</button>
  <div id="out"></div>
  <div id="err"></div>
  <p style="color:#888">Try the <b>File</b> / <b>Demo</b> menus (native backend) — clicks show below.</p>
  <div id="menu"></div>
  <script>
    var H = window.__HEIMDALL__;
    H.on("menu", function (e) {
      document.getElementById("menu").textContent = "menu: " + e.id;
    });
    document.getElementById("go").onclick = async function () {
      document.getElementById("err").textContent = "";
      var name = document.getElementById("name").value;
      try {
        var r = await H.invoke("greeting.greet", { name: name });
        document.getElementById("out").textContent = r.message;
      } catch (e) {
        document.getElementById("err").textContent = "error: " + e;
      }
    };
    document.getElementById("bang").onclick = async function () {
      document.getElementById("out").textContent = "";
      try {
        await H.invoke("greeting.boom", {});
      } catch (e) {
        document.getElementById("err").textContent = "rejected: " + e;
      }
    };
  </script>
</body>
</html>
`

main :: proc() {
	app, err := hd.create(
		hd.App_Config {
			title = "Heimdall — Hello",
			width = 520,
			height = 360,
			resizable = true,
			// Custom menus (native backend). Items with an `id` emit "menu" { id };
			// `role` items use the standard macOS behavior.
			menu = {
				{
					label = "File",
					submenu = {
						{label = "New", id = "file.new", accelerator = "Cmd+N"},
						{label = "Open…", id = "file.open", accelerator = "Cmd+O"},
						{separator = true},
						{label = "Close Window", role = .Quit},
					},
				},
				{
					label = "Demo",
					submenu = {
						{label = "Say Hello", id = "demo.hello", accelerator = "Cmd+Shift+H"},
						{label = "Disabled Item", id = "demo.nope", disabled = true},
					},
				},
			},
		},
	)
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	greeting := Greeting{prefix = "Hello, "}
	g := hd.service(app, "greeting", &greeting)
	hd.command(g, "greet", greet)
	hd.command(g, "boom", boom)

	hd.set_html(app, HTML)
	hd.run(app)
}
