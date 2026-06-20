package main

import "core:fmt"
import "core:strings"

// `heimdall doctor` — check the toolchain and platform webview deps, print fixes.
cmd_doctor :: proc(args: []string) {
	fmt.println("heimdall doctor\n")
	all_ok := true

	// `optional` checks are nice-to-haves (e.g. installer tooling) — a miss is
	// reported as a hint and never fails the overall result.
	check :: proc(label: string, ok: bool, fix: string, all_ok: ^bool, optional := false) {
		mark := "ok  " if ok else ("opt " if optional else "MISS")
		fmt.printfln("  [%s] %s", mark, label)
		if !ok {
			if !optional {all_ok^ = false}
			if fix != "" {
				fmt.printfln("         -> %s", fix)
			}
		}
	}

	check("odin compiler", has_exe("odin"), "install Odin and put it on PATH", &all_ok)
	// Frontend tooling: the starter works with any JS runtime (the `--pm` you chose
	// drives node / bun / deno). Pass if any is present.
	check(
		"JS runtime (node / bun / deno — for the frontend)",
		has_exe("node") || has_exe("bun") || has_exe("deno"),
		"install Node.js (https://nodejs.org) or Bun (https://bun.sh)",
		&all_ok,
	)

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
		// The native Linux backend is GTK4 + libadwaita + webkitgtk-6.0.
		pc := run_capture(
			{"pkg-config", "--exists", "webkitgtk-6.0 libadwaita-1 gtk4"},
			allocator = context.temp_allocator,
		)
		check(
			"webkitgtk-6.0 + libadwaita + gtk4 (dev)",
			pc.ok,
			"install the GTK4 WebKit dev packages — Fedora: `sudo dnf install webkitgtk6.0-devel libadwaita-devel gtk4-devel`; Debian/Ubuntu: `sudo apt install libwebkitgtk-6.0-dev libadwaita-1-dev libgtk-4-dev`",
			&all_ok,
		)
	} else when ODIN_OS == .Windows {
		// The native Windows backend is WebView2 (COM). The loader is linked
		// statically (no DLL to ship); only the Evergreen *runtime* is needed — and
		// it ships with current Win10/11, so end users typically have it already.
		ver, ok := check_webview2_runtime(context.temp_allocator)
		label := fmt.tprintf("WebView2 runtime (%s)", ver) if ok else "WebView2 runtime (needed to run the app)"
		check(
			label,
			ok,
			"install the WebView2 Evergreen runtime: https://developer.microsoft.com/microsoft-edge/webview2/",
			&all_ok,
		)

		// Build-time only: tooling for `heimdall bundle` (the Windows installer).
		// Optional — not needed to develop, run, or ship the app itself.
		check(
			"Inno Setup (installer — only for `heimdall bundle`)",
			windows_find_iscc() != "",
			"install Inno Setup 6 for .exe installers: winget install JRSoftware.InnoSetup6",
			&all_ok,
			optional = true,
		)
		check(
			"Windows SDK rc.exe (embeds the app icon/version — bundle only)",
			windows_find_rc() != "",
			"install the Windows SDK / 'Desktop development with C++' workload",
			&all_ok,
			optional = true,
		)
	}

	fmt.println()
	if all_ok {
		fmt.println("all checks passed.")
	} else {
		fmt.println("some checks failed — see fixes above.")
	}
}
