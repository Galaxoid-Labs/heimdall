package main

import "core:fmt"
import "core:os"
import "core:strings"

// `heimdall build [--name <bin>] [--skip-frontend]`
// frontend build -> embed assets -> compile a release binary (-o:speed).
cmd_build :: proc(args: []string) {
	p := load_project()
	skip_frontend := false

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--name":
			i += 1
			if i < len(args) {p.name = args[i]}
		case "--skip-frontend":
			skip_frontend = true
		}
		i += 1
	}

	out := exe_name(p.name)
	if !build_binary(p, skip_frontend, out) {
		os.exit(1)
	}
	fmt.printfln("heimdall build: done -> ./%s", out)
}

// Shared release-build pipeline: frontend build -> embed -> compile to `out`.
// Reused by `heimdall bundle`. Returns false on any step failure.
build_binary :: proc(p: Project, skip_frontend: bool, out: string) -> bool {
	// 0) Refresh the typed client (if enabled) before the frontend build, since the
	//    frontend may import it.
	maybe_regenerate_bindings(p)

	// 1) Frontend production build (in web_dir).
	if !skip_frontend {
		fmt.printfln("heimdall build: frontend (%s) in %s", p.build_cmd, p.web_dir)
		if !run_inherit(shell_command(split_args(p.build_cmd)), p.web_dir) {
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
	// Windows: mark the exe as a GUI app (no console window flashing behind the
	// webview) and embed an icon + version resource (so Explorer / shortcuts show
	// the app icon). Best-effort — skips cleanly if rc.exe or the icon is absent.
	when ODIN_OS == .Windows {
		append(&odin_cmd, "-subsystem:windows")
		if res := windows_build_resource(p); res != "" {
			append(&odin_cmd, res)
		}
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
