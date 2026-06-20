package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

VERSION :: "0.0.1"

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

// Find an executable on PATH (best-effort, via the shell `command -v`).
has_exe :: proc(name: string) -> bool {
	r := run_capture({"/bin/sh", "-c", fmt.tprintf("command -v %s", name)}, allocator = context.temp_allocator)
	return r.ok && len(strings.trim_space(r.out)) > 0
}
