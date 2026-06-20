// The `heimdall` CLI — the user's primary touchpoint.
//
//   heimdall new <name>          scaffold a project
//   heimdall dev                 run frontend dev server + app, rebuild on change
//   heimdall build               frontend build -> embed -> compile -> binary
//   heimdall embed <dir> <out>   generate an asset map (#load) from a dist tree
//   heimdall generate-bindings   schema-dump -> typed .d.ts
//   heimdall doctor              check the toolchain
package main

import "core:fmt"
import "core:os"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		print_usage()
		os.exit(1)
	}

	cmd := args[1]
	rest := args[2:]

	switch cmd {
	case "new":
		cmd_new(rest)
	case "dev":
		cmd_dev(rest)
	case "build":
		cmd_build(rest)
	case "bundle":
		cmd_bundle(rest)
	case "sign":
		cmd_sign(rest)
	case "embed":
		cmd_embed(rest)
	case "generate-bindings":
		cmd_generate_bindings(rest)
	case "doctor":
		cmd_doctor(rest)
	case "docs":
		cmd_docs(rest)
	case "version", "--version", "-v":
		fmt.printfln("heimdall %s", VERSION)
	case "help", "--help", "-h":
		print_usage()
	case:
		fmt.eprintfln("heimdall: unknown command %q", cmd)
		print_usage()
		os.exit(1)
	}
}

print_usage :: proc() {
	fmt.printfln(
`heimdall %s — a lightweight Tauri, in Odin

usage: heimdall <command> [args]

commands:
  new <name>           scaffold a project (--frontend vanilla|sveltekit, --pm bun|npm|pnpm|yarn|deno)
  dev                  start the frontend dev server + app; rebuild on change
  build                build frontend, embed assets, compile a release binary
  bundle               build + assemble a macOS .app (needs [bundle].identifier)
  sign [target]        code-sign the app (--adhoc for local; --notarize on macOS)
  embed <dir> <out>    generate an Odin asset map from a dist directory
  generate-bindings    run the app in schema mode and emit a typed .d.ts
  doctor               check that the toolchain and platform deps are present
  docs                 serve the documentation locally in your browser
  version              print version
  help                 show this help`,
		VERSION,
	)
}
