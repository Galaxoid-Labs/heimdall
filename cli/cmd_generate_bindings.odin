package main

import "core:fmt"
import "core:os"
import "core:strings"

// `heimdall generate-bindings [pkg] [--out <base>] [-- <extra odin flags>]`
// Build the app in schema-dump mode and write the typed client (<base>.js +
// <base>.d.ts). Optional and additive — untyped `window.heimdall.invoke` needs
// none of this. `dev` and `build` run this automatically when `bindings` is set
// in heimdall.toml.
//
//   heimdall generate-bindings
//   heimdall generate-bindings . --out web/src/heimdall.gen
//   heimdall generate-bindings examples/hello --out /tmp/b -- -collection:src=.
cmd_generate_bindings :: proc(args: []string) {
	p := load_project()
	pkg := "."
	out := p.bindings if p.bindings != "" else "web/src/heimdall.gen"
	extra := make([dynamic]string, context.temp_allocator)
	pos := make([dynamic]string, context.temp_allocator)

	i := 0
	passthrough := false
	for i < len(args) {
		a := args[i]
		if passthrough {
			append(&extra, a)
			i += 1
			continue
		}
		switch a {
		case "--out":
			i += 1
			if i < len(args) {out = args[i]}
		case "--":
			passthrough = true
		case:
			append(&pos, a)
		}
		i += 1
	}
	if len(pos) > 0 {
		pkg = pos[0]
	}

	// `--out` is a base path; tolerate a trailing extension if the user added one.
	out = strip_client_ext(out)

	// Fold the project's -collection into the odin flags if the user didn't pass one.
	if p.collection != "" && !has_collection_flag(extra[:]) {
		append(&extra, fmt.tprintf("-collection:%s", p.collection))
	}

	if !write_client_bindings(".", pkg, out, p.import_path, extra[:]) {
		os.exit(1)
	}
}

@(private = "file")
strip_client_ext :: proc(path: string) -> string {
	for ext in ([?]string{".d.ts", ".js", ".ts"}) {
		if strings.has_suffix(path, ext) {
			return path[:len(path) - len(ext)]
		}
	}
	return path
}

@(private = "file")
has_collection_flag :: proc(flags: []string) -> bool {
	for f in flags {
		if strings.has_prefix(f, "-collection:") {
			return true
		}
	}
	return false
}
