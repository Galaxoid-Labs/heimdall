package main

import "core:fmt"
import "core:os"
import "core:strings"

// `heimdall build [--name <bin>] [--skip-frontend]`
// frontend build -> embed assets -> compile a release binary (-o:speed).
cmd_build :: proc(args: []string) {
	p := load_project()
	skip_frontend := false
	webview := false // native is the default on macOS; --webview opts out

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--name":
			i += 1
			if i < len(args) {p.name = args[i]}
		case "--skip-frontend":
			skip_frontend = true
		case "--webview":
			webview = true // force the webview/webview backend
		case "--native":
			webview = false // explicit default
		}
		i += 1
	}

	if !build_binary(p, webview, skip_frontend, p.name) {
		os.exit(1)
	}
	fmt.printfln("heimdall build: done -> ./%s", p.name)
}

// Shared release-build pipeline: frontend build -> embed -> compile to `out`.
// Reused by `heimdall bundle`. `webview` forces the webview/webview backend
// (native is the default on macOS). Returns false on any step failure.
build_binary :: proc(p: Project, webview: bool, skip_frontend: bool, out: string) -> bool {
	// 0) Refresh the typed client (if enabled) before the frontend build, since the
	//    frontend may import it.
	maybe_regenerate_bindings(p)

	// 1) Frontend production build (in web_dir).
	if !skip_frontend {
		fmt.printfln("heimdall build: frontend (%s) in %s", p.build_cmd, p.web_dir)
		if !run_inherit(split_args(p.build_cmd), p.web_dir) {
			fmt.eprintln("heimdall build: frontend build failed")
			return false
		}
	}

	// 2) Embed the dist tree.
	if !generate_assets(p.dist_dir, "./assets_gen.odin", p.import_path) {
		return false
	}

	// 3) Compile the Odin app (release).
	odin_cmd := make([dynamic]string, context.temp_allocator)
	append(&odin_cmd, "odin", "build", ".", "-o:speed", fmt.tprintf("-out:%s", out))
	if p.collection != "" {
		append(&odin_cmd, fmt.tprintf("-collection:%s", p.collection))
	}
	if webview {
		append(&odin_cmd, "-define:HEIMDALL_WEBVIEW=true")
	}
	fmt.printfln("heimdall build: compiling -> %s", out)
	if !run_inherit(odin_cmd[:]) {
		fmt.eprintln("heimdall build: odin compile failed")
		return false
	}
	return true
}

// Split a shell-ish command string on spaces (no quoting support — fine for the
// simple `bun run build` style commands we expect).
split_args :: proc(cmd: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	s := cmd
	for field in strings.fields_iterator(&s) {
		append(&out, field)
	}
	return out[:]
}
