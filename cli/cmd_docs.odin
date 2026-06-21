package main

import "core:fmt"
import "core:os"
import "core:strings"

// Hosted docs, used as a fallback when no local docs source is found.
DOCS_URL :: "https://galaxoid-labs.github.io/heimdall/"

// `heimdall docs [--build] [--port N] [--no-open]`
// Serve the documentation site locally in your browser.
//   default   live VitePress dev server (HMR), opens the browser
//   --build   build the static site and preview it
// Falls back to opening the hosted docs if no local source is found.
cmd_docs :: proc(args: []string) {
	build := false
	open := true
	port := ""

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--build", "--static":
			build = true
		case "--no-open":
			open = false
		case "--port":
			i += 1
			if i < len(args) {port = args[i]}
		}
		i += 1
	}

	root := find_docs_root()
	if root == "" {
		fmt.printfln("heimdall docs: no local docs source found.\n  Online docs: %s", DOCS_URL)
		if open {
			open_browser(DOCS_URL)
		}
		return
	}
	if !has_exe("bun") {
		fmt.eprintln("heimdall docs: bun is required to serve the docs — https://bun.sh")
		os.exit(1)
	}

	cmd := make([dynamic]string, context.temp_allocator)
	if build {
		fmt.println("heimdall docs: building the static site...")
		if !run_inherit({"bunx", "vitepress", "build", root}) {
			os.exit(1)
		}
		append(&cmd, "bunx", "vitepress", "preview", root)
		if port != "" {append(&cmd, "--port", port)}
		fmt.println("heimdall docs: serving the production build (Ctrl+C to stop)")
	} else {
		append(&cmd, "bunx", "vitepress", "dev", root)
		if open {append(&cmd, "--open")}
		if port != "" {append(&cmd, "--port", port)}
		fmt.println("heimdall docs: starting the docs dev server (Ctrl+C to stop)")
	}
	run_inherit(cmd[:]) // long-running; blocks until the user stops it
}

// Locate a VitePress docs root: ./docs, then $HEIMDALL_HOME/docs.
@(private = "file")
find_docs_root :: proc() -> string {
	if file_exists("docs/.vitepress") {
		return "docs"
	}
	if home, ok := os.lookup_env("HEIMDALL_HOME", context.temp_allocator); ok && home != "" {
		d := strings.concatenate({home, "/docs"}, context.temp_allocator)
		if file_exists(strings.concatenate({d, "/.vitepress"}, context.temp_allocator)) {
			return d
		}
	}
	return ""
}

open_browser :: proc(url: string) {
	when ODIN_OS == .Darwin {
		_ = run_capture({"open", url})
	} else when ODIN_OS == .Linux {
		_ = run_capture({"xdg-open", url})
	} else when ODIN_OS == .Windows {
		_ = run_capture({"cmd", "/c", "start", "", url})
	}
}
