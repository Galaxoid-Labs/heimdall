package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// `heimdall dev` — start the frontend dev server, build the app with
// HEIMDALL_DEV=true pointing at the dev URL, and relaunch on .odin changes.
// Exits when the app window is closed.
cmd_dev :: proc(args: []string) {
	p := load_project()
	ensure_assets_stub(".", p.import_path)
	maybe_regenerate_bindings(p) // keep the typed client fresh for this session

	// The dev server (e.g. `bun run dev`) spawns a child server that outlives the
	// parent on kill, so free the port up-front (clears a stale server from a
	// previous run) and again on exit.
	port := dev_port(p.dev_url)
	free_port(port)

	fmt.printfln("heimdall dev: frontend (%s) in %s", p.dev_cmd, p.web_dir)
	fe, fe_ok := start_bg(shell_command(split_args(p.dev_cmd)), p.web_dir)
	if !fe_ok {
		os.exit(1)
	}
	defer {
		_ = os.process_kill(fe)
		free_port(port)
	}

	bin := host_temp_path(fmt.tprintf("heimdall-dev-%s", p.name), is_exe = true)
	last_sig := watch_signature(".")
	app: os.Process
	app_running := false
	defer if app_running {_ = os.process_kill(app)}

	fmt.println("heimdall dev: watching .odin files (close the window to stop)")
	for {
		if !app_running {
			if dev_build(p, bin) {
				a, started := start_bg({bin})
				if started {
					app = a
					app_running = true
				}
			} else {
				fmt.println("heimdall dev: build failed; waiting for changes...")
			}
		}

		time.sleep(300 * time.Millisecond)

		// Did the user close the window?
		if app_running {
			st, werr := os.process_wait(app, time.Millisecond)
			if werr == nil && st.exited {
				fmt.println("heimdall dev: window closed; stopping")
				app_running = false
				break
			}
		}

		// Did any source change?
		sig := watch_signature(".")
		if sig != last_sig {
			last_sig = sig
			fmt.println("heimdall dev: change detected, rebuilding...")
			if app_running {
				_ = os.process_kill(app)
				_, _ = os.process_wait(app)
				app_running = false
			}
		}
	}
}

// Extract the port from a dev URL like "http://localhost:5173".
@(private = "file")
dev_port :: proc(url: string) -> string {
	host := url
	if i := strings.last_index_byte(host, '/'); i >= 0 {
		host = host[i + 1:]
	}
	if c := strings.last_index_byte(host, ':'); c >= 0 {
		port := host[c + 1:]
		if slash := strings.index_byte(port, '/'); slash >= 0 {
			port = port[:slash]
		}
		return port
	}
	return ""
}

// Best-effort: kill whatever is listening on `port` (a stale dev server).
@(private = "file")
free_port :: proc(port: string) {
	if port == "" {
		return
	}
	// The port is interpolated into `sh -c`; it comes from heimdall.toml's
	// dev_url, so validate it's purely numeric to avoid shell injection from a
	// malicious project config.
	for ch in port {
		if ch < '0' || ch > '9' {
			return
		}
	}
	when ODIN_OS != .Windows {
		_ = run_capture(
			{"/bin/sh", "-c", fmt.tprintf("lsof -ti tcp:%s | xargs kill 2>/dev/null || true", port)},
			allocator = context.temp_allocator,
		)
	}
}

@(private = "file")
dev_build :: proc(p: Project, bin: string) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", ".", "-define:HEIMDALL_DEV=true", fmt.tprintf("-out:%s", bin))
	if p.collection != "" {
		append(&cmd, fmt.tprintf("-collection:%s", p.collection))
	}
	return run_inherit(cmd[:])
}

// A cheap change signal: XOR of modification times of all .odin files under
// `root`, excluding the vendored framework copy.
@(private = "file")
watch_signature :: proc(root: string) -> i64 {
	sig: i64 = 0
	scan_odin(root, &sig)
	return sig
}

@(private = "file")
scan_odin :: proc(dir: string, sig: ^i64) {
	f, e := os.open(dir)
	if e != nil {
		return
	}
	defer os.close(f)
	infos, re := os.read_directory(f, -1, context.temp_allocator)
	if re != nil {
		return
	}
	for info in infos {
		#partial switch info.type {
		case .Directory:
			// Don't recurse into the vendored framework or hidden dirs.
			if info.name == "heimdall" || strings.has_prefix(info.name, ".") {
				continue
			}
			scan_odin(info.fullpath, sig)
		case .Regular:
			if filepath.ext(info.name) == ".odin" {
				sig^ ~= info.modification_time._nsec
			}
		}
	}
}
