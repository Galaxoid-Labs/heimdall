package main

import "core:fmt"
import "core:os"

// `heimdall bundle [--webview] [--skip-build] [--name <bin>] [--sign ...]`
// Build a release binary and assemble a distributable package for the host OS:
//   * macOS — a `.app` bundle (Info.plist, executable, icon), optionally signed/notarized
//   * Linux — `.deb` and `.rpm` packages (binary + .desktop + icon)
//
// Defaults to the native backend. Pass --webview to bundle the webview/webview
// backend instead.
cmd_bundle :: proc(args: []string) {
	p := load_project()
	webview := false // native is the default; --webview opts out
	skip_build := false
	do_sign := false
	adhoc := false
	notarize := false

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--name":
			i += 1
			if i < len(args) {p.name = args[i]}
		case "--webview":
			webview = true
		case "--skip-build":
			skip_build = true
		case "--sign":
			do_sign = true
		case "--adhoc":
			do_sign = true
			adhoc = true
		case "--notarize":
			do_sign = true
			notarize = true
		}
		i += 1
	}

	// Build the release binary (unless reusing an existing one). Shared step.
	if !skip_build {
		if !build_binary(p, webview, false, p.name) {
			os.exit(1)
		}
	}
	if !file_exists(p.name) {
		fmt.eprintfln("heimdall bundle: binary %q not found (build it first)", p.name)
		os.exit(1)
	}

	when ODIN_OS == .Darwin {
		bundle_macos(p, do_sign, adhoc, notarize)
	} else when ODIN_OS == .Linux {
		_ = do_sign;_ = adhoc;_ = notarize // signing is macOS-only for now
		bundle_linux(p)
	} else {
		fmt.eprintln("heimdall bundle: only macOS (.app) and Linux (.deb/.rpm) are supported")
		os.exit(1)
	}
}
