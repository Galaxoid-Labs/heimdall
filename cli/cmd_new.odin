package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// `heimdall new <name> [--framework <path-to-heimdall-pkg>]`
// Scaffold a project: app files + a vanilla (dependency-free, bun-served)
// frontend, and vendor the framework package into ./<name>/heimdall.
//
// The framework copy is resolved from --framework, else $HEIMDALL_HOME/heimdall,
// else error (a shipped CLI would embed it; for now point it at the repo).
cmd_new :: proc(args: []string) {
	name := ""
	framework := ""

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--framework":
			i += 1
			if i < len(args) {framework = args[i]}
		case:
			if name == "" {name = args[i]}
		}
		i += 1
	}

	if name == "" {
		fmt.eprintln("usage: heimdall new <name> [--framework <path>]")
		os.exit(1)
	}
	if framework == "" {
		if home, ok := os.lookup_env("HEIMDALL_HOME", context.temp_allocator); ok {
			framework = strings.concatenate({home, "/heimdall"}, context.temp_allocator)
		}
	}
	if framework == "" || !file_exists(framework) {
		fmt.eprintfln(
			"heimdall new: framework package not found.\n  pass --framework <path-to-heimdall-pkg> or set HEIMDALL_HOME.",
		)
		os.exit(1)
	}
	if file_exists(name) {
		fmt.eprintfln("heimdall new: %q already exists", name)
		os.exit(1)
	}

	// Project/binary name is the final path component; `name` may be a path.
	proj := filepath.base(name)
	title := proj

	mkdir_p(name)
	mkdir_p(strings.concatenate({name, "/web/src"}, context.temp_allocator))
	mkdir_p(strings.concatenate({name, "/.github/workflows"}, context.temp_allocator))

	write_file(cat(name, "/main.odin"), render(TMPL_MAIN, proj, title))
	write_file(cat(name, "/services.odin"), render(TMPL_SERVICES, proj, title))
	write_file(cat(name, "/heimdall.toml"), render(TMPL_TOML, proj, title))
	write_file(cat(name, "/.gitignore"), render(TMPL_GITIGNORE, proj, title))
	write_file(cat(name, "/build.sh"), render(TMPL_BUILD_SH, proj, title))
	write_file(cat(name, "/web/index.html"), render(TMPL_INDEX_HTML, proj, title))
	write_file(cat(name, "/web/src/main.js"), render(TMPL_MAIN_JS, proj, title))
	write_file(cat(name, "/web/package.json"), render(TMPL_PACKAGE_JSON, proj, title))
	write_file(cat(name, "/web/dev.js"), render(TMPL_DEV_JS, proj, title))
	write_file(cat(name, "/web/build.js"), render(TMPL_BUILD_JS, proj, title))
	write_file(cat(name, "/.github/workflows/release.yml"), render(TMPL_WORKFLOW, proj, title))

	// Vendor the framework package into ./<name>/heimdall.
	dest := cat(name, "/heimdall")
	if !run_inherit({"cp", "-R", framework, dest}) {
		fmt.eprintln("heimdall new: failed to vendor framework")
		os.exit(1)
	}

	fmt.printfln(
`
created %s/

next:
  cd %s
  (cd web && bun install)   # vanilla template has no deps, but sets up bun
  heimdall dev              # opens a window with a live invoke round-trip

build a release binary:
  heimdall build`,
		name,
		name,
	)
}

@(private = "file")
cat :: proc(a, b: string) -> string {
	return strings.concatenate({a, b}, context.temp_allocator)
}

// Token-based templating (NOT fmt) so template braces/percent signs pass through
// untouched. Replaces __NAME__ and __TITLE__.
@(private = "file")
render :: proc(tmpl, name, title: string) -> string {
	s, _ := strings.replace_all(tmpl, "__NAME__", name, context.temp_allocator)
	s, _ = strings.replace_all(s, "__TITLE__", title, context.temp_allocator)
	return s
}

@(private = "file")
mkdir_p :: proc(path: string) {
	run_inherit({"mkdir", "-p", path})
}

@(private = "file")
write_file :: proc(path, content: string) {
	if werr := os.write_entire_file(path, transmute([]u8)content); werr != nil {
		fmt.eprintfln("heimdall new: failed to write %s: %v", path, werr)
		os.exit(1)
	}
}

// ---- templates ------------------------------------------------------------

TMPL_MAIN :: `package main

import "core:fmt"
import "core:os"
import hd "heimdall"

main :: proc() {
	app, err := hd.create(hd.App_Config{
		title     = "__TITLE__",
		width     = 800,
		height    = 600,
		resizable = true,
		dev_url   = "http://localhost:5173", // used by ` + "`heimdall dev`" + `
		assets    = ASSETS,                  // embedded by ` + "`heimdall build`" + `
		// Native menus (macOS). Items with an id emit a "menu" { id } event;
		// subscribe in JS with on("menu", ...). role items are standard actions.
		menu = {
			{label = "File", submenu = {
				{label = "New",   id = "file.new",  accelerator = "Cmd+N"},
				{label = "Open…", id = "file.open", accelerator = "Cmd+O"},
				{separator = true},
				{label = "Close", role = .Quit},
			}},
		},
	})
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	greeting := Greeting{prefix = "Hello, "}
	g := hd.service(app, "greeting", &greeting)
	hd.command(g, "greet", greet)

	hd.run(app)
}
`

TMPL_SERVICES :: `package main

import "core:fmt"
import hd "heimdall"

Greeting :: struct {
	prefix: string,
}

Greet_Args :: struct {
	name: string,
}

Greet_Result :: struct {
	message: string,
}

// invoke("greeting.greet", {name}) -> {message}
greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
	return Greet_Result{message = fmt.tprintf("%s%s", s.prefix, args.name)}, nil
}
`

TMPL_TOML :: `# heimdall project config
name      = "__NAME__"
web_dir   = "web"
dist_dir  = "web/dist"
dev_cmd   = "bun run dev"
build_cmd = "bun run build"
dev_url   = "http://localhost:5173"
# title shown in the window: __TITLE__

# Packaging metadata for ` + "`heimdall bundle`" + `.
# [bundle] holds settings common to every platform; [bundle.<platform>] overrides
# per-platform — so you only repeat what's actually platform-specific.
# identifier is REQUIRED to bundle.
[bundle]
identifier   = "com.example.__NAME__"
version      = "0.1.0"
build        = "1"
display_name = "__TITLE__"
# icon       = "icon.png"   # common icon; override per-platform below if needed

[bundle.macos]
min_macos    = "11.0"
# category   = "public.app-category.developer-tools"
# icon       = "icon.icns"  # macOS-specific icon (else the common one is used)

# [bundle.windows]
# [bundle.linux]

# Code signing for ` + "`heimdall sign`" + ` / ` + "`heimdall bundle --sign`" + `.
# No secrets here — identity is a cert name; CI overrides via HEIMDALL_SIGN_IDENTITY.
# Local testing: ` + "`heimdall bundle --adhoc`" + ` (no certificate needed).
[sign.macos]
# identity       = "Developer ID Application: Your Name (TEAMID)"
# entitlements   = "entitlements.plist"
# notary_profile = "__NAME__-notary"   # xcrun notarytool store-credentials name

# [sign.windows]
# identity = "Your Company, Inc."   # certificate subject
`

TMPL_GITIGNORE :: `assets_gen.odin
web/bindings.d.ts
web/dist/
web/node_modules/
/__NAME__
*.app/
*.bin
.DS_Store
`

TMPL_BUILD_SH :: `#!/usr/bin/env bash
set -euo pipefail
(cd web && bun run build)
heimdall embed web/dist ./assets_gen.odin
odin build . -o:speed -out:app
echo "built -> ./app"
`

TMPL_INDEX_HTML :: `<!doctype html>
<html>
<head><meta charset="utf-8"><title>__TITLE__</title></head>
<body>
  <h1>__TITLE__</h1>
  <input id="name" value="world">
  <button id="go">greet</button>
  <p id="out"></p>
  <script type="module" src="/src/main.js"></script>
</body>
</html>
`

TMPL_MAIN_JS :: `const H = window.__HEIMDALL__;

document.querySelector("#go").addEventListener("click", async () => {
  const name = document.querySelector("#name").value;
  const r = await H.invoke("greeting.greet", { name });
  document.querySelector("#out").textContent = r.message;
});

// Native menu clicks arrive as a "menu" event with the item's id.
H.on("menu", (e) => {
  console.log("menu:", e.id);
});
`

TMPL_PACKAGE_JSON :: `{
  "name": "__NAME__-web",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "bun run dev.js",
    "build": "bun run build.js"
  }
}
`

TMPL_DEV_JS :: `// Minimal static dev server (no deps). Serves the web/ folder on :5173.
const PORT = 5173;
Bun.serve({
  port: PORT,
  fetch(req) {
    let path = new URL(req.url).pathname;
    if (path === "/") path = "/index.html";
    return new Response(Bun.file("." + path));
  },
});
console.log("dev server -> http://localhost:" + PORT);
`

TMPL_BUILD_JS :: `// Copy the static frontend into dist/. Replace with your bundler if you like.
import { mkdirSync, rmSync, cpSync } from "fs";
rmSync("dist", { recursive: true, force: true });
mkdirSync("dist", { recursive: true });
cpSync("index.html", "dist/index.html");
cpSync("src", "dist/src", { recursive: true });
console.log("built -> dist/");
`

// GitHub Actions: build + bundle + sign + notarize a macOS .app on tag push,
// using the reusable heimdall composite action. Replace OWNER/heimdall with the
// repo hosting heimdall, and set the secrets named below (Settings -> Secrets
// and variables -> Actions). Drop the signing inputs to ship an unsigned/ad-hoc
// build, or use `command: bundle --adhoc`.
TMPL_WORKFLOW :: `name: release
on:
  push:
    tags: ["v*"]
  workflow_dispatch:

jobs:
  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Build, bundle, sign, notarize
        uses: OWNER/heimdall@v1   # <-- the repo hosting heimdall
        with:
          command: bundle --sign --notarize
          sign-identity: ` + "${{ secrets.MACOS_SIGN_IDENTITY }}" + `
          macos-cert-p12: ` + "${{ secrets.MACOS_CERT_P12 }}" + `
          macos-cert-password: ` + "${{ secrets.MACOS_CERT_PASSWORD }}" + `
          apple-id: ` + "${{ secrets.APPLE_ID }}" + `
          apple-team-id: ` + "${{ secrets.APPLE_TEAM_ID }}" + `
          apple-app-password: ` + "${{ secrets.APPLE_APP_PASSWORD }}" + `

      - uses: actions/upload-artifact@v4
        with:
          name: __NAME__-macos
          path: "*.app"
`
