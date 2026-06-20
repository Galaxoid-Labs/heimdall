package main

import "core:fmt"
import "core:strings"

// `heimdall doctor` — check the toolchain and platform webview deps, print fixes.
cmd_doctor :: proc(args: []string) {
	fmt.println("heimdall doctor\n")
	all_ok := true

	check :: proc(label: string, ok: bool, fix: string, all_ok: ^bool) {
		mark := "ok  " if ok else "MISS"
		fmt.printfln("  [%s] %s", mark, label)
		if !ok {
			all_ok^ = false
			if fix != "" {
				fmt.printfln("         -> %s", fix)
			}
		}
	}

	check("odin compiler", has_exe("odin"), "install Odin and put it on PATH", &all_ok)
	check("bun (frontend tooling)", has_exe("bun"), "install bun: https://bun.sh", &all_ok)

	when ODIN_OS == .Darwin {
		// Xcode command-line tools provide WebKit/Cocoa frameworks + the C++ stdlib.
		clt := run_capture({"xcode-select", "-p"}, allocator = context.temp_allocator)
		check(
			"Xcode command-line tools",
			clt.ok && len(strings.trim_space(clt.out)) > 0,
			"run: xcode-select --install",
			&all_ok,
		)
		check(
			"WebKit framework",
			file_exists("/System/Library/Frameworks/WebKit.framework"),
			"part of macOS; reinstall the CLT if missing",
			&all_ok,
		)
	} else when ODIN_OS == .Linux {
		// WebKitGTK 4.1 dev package is the link dep.
		pc := run_capture(
			{"pkg-config", "--exists", "webkit2gtk-4.1"},
			allocator = context.temp_allocator,
		)
		check(
			"webkit2gtk-4.1 (dev)",
			pc.ok,
			"install the webkit2gtk-4.1 development package (e.g. libwebkit2gtk-4.1-dev)",
			&all_ok,
		)
	} else when ODIN_OS == .Windows {
		check(
			"WebView2 runtime",
			false,
			"Windows backend is not yet implemented (Phase 7); WebView2 Evergreen runtime required",
			&all_ok,
		)
	}

	fmt.println()
	if all_ok {
		fmt.println("all checks passed.")
	} else {
		fmt.println("some checks failed — see fixes above.")
	}
}
