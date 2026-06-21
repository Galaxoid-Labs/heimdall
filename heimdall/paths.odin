package heimdall

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Per-app directories for config, data, cache, and logs — one cross-platform API;
// the OS-specific locations live behind the `when ODIN_OS` switch below. Every
// directory is namespaced by the app id (`App_Config.app_id`, falling back to a
// sanitized `title`) so apps don't collide, and is created on first access.
//
// Per-platform roots (then `/<app_id>`):
//   macOS    Config/Data ~/Library/Application Support · Cache ~/Library/Caches · Log ~/Library/Logs
//   Linux    XDG_CONFIG_HOME(.config) · XDG_DATA_HOME(.local/share) · XDG_CACHE_HOME(.cache) · XDG_STATE_HOME(.local/state)
//   Windows  Config/Data %APPDATA% · Cache/Log %LOCALAPPDATA%
//
// Odin usage (caller owns the returned string):
//   dir := hd.config_dir(app)                          // .../<app_id>
//   p   := hd.app_path(app, .Config, "settings.json")  // a file path inside it
//
// JS usage (the built-in `paths` service, typed in generated bindings):
//   const dir = await paths.config()   // { path }

Path_Kind :: enum {
	Config,
	Data,
	Cache,
	Log,
}

// The directory for `kind`, created if needed. Returns "" if the home/app-data
// location can't be resolved. Allocated with `allocator` (caller frees).
app_dir :: proc(app: ^App, kind: Path_Kind, allocator := context.allocator) -> string {
	base := base_dir(kind, context.temp_allocator)
	if base == "" {
		return ""
	}
	id := app_identifier(app, context.temp_allocator)
	dir, _ := filepath.join({base, id}, context.temp_allocator)
	_ = os.make_directory_all(dir) // best-effort
	return strings.clone(dir, allocator)
}

config_dir :: proc(app: ^App, allocator := context.allocator) -> string {return app_dir(app, .Config, allocator)}
data_dir :: proc(app: ^App, allocator := context.allocator) -> string {return app_dir(app, .Data, allocator)}
cache_dir :: proc(app: ^App, allocator := context.allocator) -> string {return app_dir(app, .Cache, allocator)}
log_dir :: proc(app: ^App, allocator := context.allocator) -> string {return app_dir(app, .Log, allocator)}

// A file path inside the `kind` directory, e.g. `app_path(app, .Config, "x.json")`.
// Creates the directory (and any subdirs named in `rel`). Caller owns the result.
app_path :: proc(app: ^App, kind: Path_Kind, rel: string, allocator := context.allocator) -> string {
	dir := app_dir(app, kind, context.temp_allocator)
	if dir == "" {
		return ""
	}
	p, _ := filepath.join({dir, rel}, context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(p)) // ensure parent (handles rel subdirs)
	return strings.clone(p, allocator)
}

// ---- internals ------------------------------------------------------------

@(private = "file")
base_dir :: proc(kind: Path_Kind, allocator: runtime.Allocator) -> string {
	when ODIN_OS == .Darwin {
		home := home_dir(allocator)
		if home == "" {return ""}
		switch kind {
		case .Config, .Data:
			return join2(home, "Library/Application Support", allocator)
		case .Cache:
			return join2(home, "Library/Caches", allocator)
		case .Log:
			return join2(home, "Library/Logs", allocator)
		}
	} else when ODIN_OS == .Windows {
		switch kind {
		case .Config, .Data:
			return env_or_home(app_env("APPDATA"), "AppData/Roaming", allocator)
		case .Cache, .Log:
			return env_or_home(app_env("LOCALAPPDATA"), "AppData/Local", allocator)
		}
	} else {
		// Linux and other XDG-style unixes.
		switch kind {
		case .Config:
			return xdg("XDG_CONFIG_HOME", ".config", allocator)
		case .Data:
			return xdg("XDG_DATA_HOME", ".local/share", allocator)
		case .Cache:
			return xdg("XDG_CACHE_HOME", ".cache", allocator)
		case .Log:
			return xdg("XDG_STATE_HOME", ".local/state", allocator)
		}
	}
	return ""
}

@(private = "file")
home_dir :: proc(allocator: runtime.Allocator) -> string {
	when ODIN_OS == .Windows {
		if v, ok := os.lookup_env("USERPROFILE", allocator); ok && v != "" {return v}
		return ""
	} else {
		if v, ok := os.lookup_env("HOME", allocator); ok && v != "" {return v}
		return ""
	}
}

// XDG dir: use the env var if it's an absolute path, else $HOME/<fallback>.
@(private = "file")
xdg :: proc(env_key, fallback_rel: string, allocator: runtime.Allocator) -> string {
	if v, ok := os.lookup_env(env_key, allocator); ok && strings.has_prefix(v, "/") {
		return v
	}
	home := home_dir(allocator)
	if home == "" {return ""}
	return join2(home, fallback_rel, allocator)
}

@(private = "file")
app_env :: proc(key: string) -> string {
	v, _ := os.lookup_env(key, context.temp_allocator)
	return v
}

// Windows: prefer the env var, else $USERPROFILE/<fallback>.
@(private = "file")
env_or_home :: proc(env_val, fallback_rel: string, allocator: runtime.Allocator) -> string {
	if env_val != "" {
		return strings.clone(env_val, allocator)
	}
	home := home_dir(allocator)
	if home == "" {return ""}
	return join2(home, fallback_rel, allocator)
}

@(private = "file")
join2 :: proc(a, b: string, allocator: runtime.Allocator) -> string {
	p, _ := filepath.join({a, b}, allocator)
	return p
}

// The app id used to namespace dirs: App_Config.app_id, else a sanitized title,
// else "heimdall-app". Package-private — also used by the Linux single-instance
// lock (backend_linux.odin) so the socket name matches the app's data dirs.
@(private)
app_identifier :: proc(app: ^App, allocator: runtime.Allocator) -> string {
	id := app.cfg.app_id
	if strings.trim_space(id) == "" {id = app.cfg.title}
	if strings.trim_space(id) == "" {id = "heimdall-app"}
	return sanitize_folder(id, allocator)
}

// Make a string safe as a single path segment: path separators / odd chars -> '-'.
// Leaves dots intact (so "com.example.app" stays as-is).
@(private = "file")
sanitize_folder :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0, ' ', '\t', '\n', '\r':
			strings.write_rune(&b, '-')
		case:
			strings.write_rune(&b, r)
		}
	}
	out := strings.to_string(b)
	if out == "" {return strings.clone("heimdall-app", allocator)}
	return out
}

// ---- built-in `paths` service (frontend) ----------------------------------

@(private = "file")
Paths_None :: struct {}
@(private = "file")
Paths_Result :: struct {
	path: string,
}

@(private = "file")
paths_c_config :: proc(app: ^App, _: Paths_None) -> (Paths_Result, Error) {return {path = config_dir(app, context.temp_allocator)}, nil}
@(private = "file")
paths_c_data :: proc(app: ^App, _: Paths_None) -> (Paths_Result, Error) {return {path = data_dir(app, context.temp_allocator)}, nil}
@(private = "file")
paths_c_cache :: proc(app: ^App, _: Paths_None) -> (Paths_Result, Error) {return {path = cache_dir(app, context.temp_allocator)}, nil}
@(private = "file")
paths_c_log :: proc(app: ^App, _: Paths_None) -> (Paths_Result, Error) {return {path = log_dir(app, context.temp_allocator)}, nil}

@(private)
register_paths_service :: proc(app: ^App) {
	p := service(app, "paths", app)
	command(p, "config", paths_c_config)
	command(p, "data", paths_c_data)
	command(p, "cache", paths_c_cache)
	command(p, "log", paths_c_log)
}
