package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// `heimdall generate-bindings [pkg] [--out <path>] [-- <extra odin flags>]`
// Build the app in schema-dump mode, run it to get the command schema as JSON,
// and write a typed .d.ts. Optional and additive — untyped invoke needs none of
// this.
//
//   heimdall generate-bindings . --out web/bindings.d.ts
//   heimdall generate-bindings examples/hello --out /tmp/b.d.ts -- -collection:src=.
cmd_generate_bindings :: proc(args: []string) {
	pkg := "."
	out := "web/bindings.d.ts"
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

	bin := "/tmp/heimdall_schema_dump"
	build_cmd := make([dynamic]string, context.temp_allocator)
	append(&build_cmd, "odin", "build", pkg, "-define:HEIMDALL_SCHEMA=true", fmt.tprintf("-out:%s", bin))
	for e in extra {
		append(&build_cmd, e)
	}

	fmt.printfln("heimdall: building schema binary (%s)...", pkg)
	br := run_capture(build_cmd[:], allocator = context.temp_allocator)
	if !br.ok {
		fmt.eprintfln("heimdall generate-bindings: schema build failed:\n%s%s", br.out, br.err)
		os.exit(1)
	}

	rr := run_capture({bin}, allocator = context.temp_allocator)
	if !rr.ok {
		fmt.eprintfln("heimdall generate-bindings: schema run failed:\n%s%s", rr.out, rr.err)
		os.exit(1)
	}

	schema: Schema
	if uerr := json.unmarshal(transmute([]u8)rr.out, &schema, allocator = context.temp_allocator);
	   uerr != nil {
		fmt.eprintfln("heimdall generate-bindings: bad schema JSON: %v\n%s", uerr, rr.out)
		os.exit(1)
	}

	dts := generate_dts(schema, context.temp_allocator)
	if werr := os.write_entire_file(out, transmute([]u8)dts); werr != nil {
		fmt.eprintfln("heimdall generate-bindings: write failed: %v", werr)
		os.exit(1)
	}

	n := 0
	for svc in schema.services {n += len(svc.commands)}
	fmt.printfln("heimdall generate-bindings: %d command(s) -> %s", n, out)
}
