package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

VERSION :: "0.1.0"

// Result of running a child process with captured output.
Run :: struct {
	ok:   bool,
	code: int,
	out:  string,
	err:  string,
}

// Run a command, capturing stdout/stderr.
run_capture :: proc(cmd: []string, dir := "", allocator := context.allocator) -> Run {
	state, sout, serr, e := os.process_exec(
		os.Process_Desc{command = cmd, working_dir = dir},
		allocator,
	)
	if e != nil {
		return Run{ok = false, code = -1, err = fmt.aprintf("exec failed: %v", e, allocator = allocator)}
	}
	return Run {
		ok = state.exited && state.exit_code == 0,
		code = state.exit_code,
		out = string(sout),
		err = string(serr),
	}
}

// Run a command, inheriting our stdio (live output). Returns success.
run_inherit :: proc(cmd: []string, dir := "") -> bool {
	p, e := os.process_start(
		os.Process_Desc{command = cmd, working_dir = dir, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin},
	)
	if e != nil {
		fmt.eprintfln("heimdall: failed to start %v: %v", cmd, e)
		return false
	}
	st, we := os.process_wait(p)
	if we != nil {
		return false
	}
	return st.exited && st.exit_code == 0
}

// Start a command in the background (inheriting stdio), returning its handle.
start_bg :: proc(cmd: []string, dir := "") -> (os.Process, bool) {
	p, e := os.process_start(
		os.Process_Desc{command = cmd, working_dir = dir, stdout = os.stdout, stderr = os.stderr},
	)
	if e != nil {
		fmt.eprintfln("heimdall: failed to start %v: %v", cmd, e)
		return {}, false
	}
	return p, true
}

// Collect regular files under `root`, returning paths relative to `root` with
// forward slashes.
collect_files :: proc(root: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	walk_rec(root, "", &out, allocator)
	return out[:]
}

// Builds keys from directory entry names (carried as `rel_prefix`) rather than
// from info.fullpath — the latter canonicalizes symlinks (e.g. /tmp ->
// /private/tmp on macOS) and corrupts the relative key.
@(private = "file")
walk_rec :: proc(dir, rel_prefix: string, out: ^[dynamic]string, allocator: runtime.Allocator) {
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
		child_rel: string
		if rel_prefix == "" {
			child_rel = info.name
		} else {
			child_rel = strings.concatenate({rel_prefix, "/", info.name}, context.temp_allocator)
		}
		#partial switch info.type {
		case .Directory:
			walk_rec(info.fullpath, child_rel, out, allocator)
		case .Regular:
			append(out, strings.clone(child_rel, allocator))
		}
	}
}

// Replace OS path separators with '/'.
to_slash :: proc(p: string, allocator := context.temp_allocator) -> string {
	when ODIN_OS == .Windows {
		return strings.replace_all(p, "\\", "/", allocator) or_else p
	} else {
		return p
	}
}

file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// Wrap an external command so it can run on Windows. Package managers and their
// runners (npm, npx, pnpm, yarn, and the `sv` CLI) are `.cmd`/`.ps1` batch shims,
// which `CreateProcess` cannot launch directly — so on Windows we route through
// `cmd /c`. Real `.exe`s (odin, node, bun, deno, git) work either way. On other
// platforms the command is returned unchanged.
shell_command :: proc(args: []string, allocator := context.temp_allocator) -> []string {
	when ODIN_OS == .Windows {
		out := make([dynamic]string, 0, len(args) + 2, allocator)
		append(&out, "cmd", "/c")
		append(&out, ..args)
		return out[:]
	} else {
		return args
	}
}

// The host executable suffix — ".exe" on Windows, "" elsewhere. Odin's `-out:`
// requires the extension on Windows.
exe_ext :: proc() -> string {
	when ODIN_OS == .Windows {
		return ".exe"
	} else {
		return ""
	}
}

// A binary name with the host executable suffix (Windows: appends ".exe" if not
// already present). odin's `-out:` requires the extension on Windows.
exe_name :: proc(base: string, allocator := context.temp_allocator) -> string {
	ext := exe_ext()
	if ext == "" || strings.has_suffix(base, ext) {return base}
	return strings.concatenate({base, ext}, allocator)
}

// A scratch path under the OS temp dir (the cross-platform replacement for a
// hardcoded "/tmp/…"). When `is_exe`, appends the host exe suffix so the path is
// a valid `odin build -out:` target on Windows.
host_temp_path :: proc(name: string, is_exe := false, allocator := context.temp_allocator) -> string {
	dir := "/tmp"
	when ODIN_OS == .Windows {
		dir = os.get_env("TEMP", allocator)
		if dir == "" {dir = os.get_env("TMP", allocator)}
		if dir == "" {dir = "C:\\Windows\\Temp"}
	}
	return strings.concatenate({dir, "/", name, is_exe ? exe_ext() : ""}, allocator)
}

// Find an executable on PATH (best-effort). Uses `where` on Windows, the shell
// `command -v` elsewhere.
has_exe :: proc(name: string) -> bool {
	when ODIN_OS == .Windows {
		r := run_capture({"where", name}, allocator = context.temp_allocator)
	} else {
		r := run_capture({"/bin/sh", "-c", fmt.tprintf("command -v %s", name)}, allocator = context.temp_allocator)
	}
	return r.ok && len(strings.trim_space(r.out)) > 0
}
