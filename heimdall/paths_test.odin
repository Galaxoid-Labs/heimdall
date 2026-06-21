package heimdall

// Tests for the cross-platform per-app directories (paths.odin).
//
//   odin test heimdall
//
// We sandbox the environment (HOME / XDG_* / APPDATA / LOCALAPPDATA /
// USERPROFILE) to a temp dir so the tests resolve real paths without touching —
// or creating dirs in — the developer's actual config locations. The `base_dir`
// branch under test is the host OS's: macOS exercises the ~/Library/* branch,
// Linux the XDG branch, Windows the %APPDATA% branch. The XDG- and Windows-only
// branches are noted for on-platform verification in DEVELOPMENT.md.

import "core:os"
import "core:strings"
import "core:testing"

// Point every base-dir env var at `root` so resolution is deterministic and
// confined to a temp dir. Covers all three platforms' branches.
@(private = "file")
sandbox_env :: proc(root: string) {
	os.set_env("HOME", root) // macOS + Linux home
	os.set_env("USERPROFILE", root) // Windows home fallback
	// Linux XDG: unset so each kind falls back to $HOME/<rel> (the common case).
	os.unset_env("XDG_CONFIG_HOME")
	os.unset_env("XDG_DATA_HOME")
	os.unset_env("XDG_CACHE_HOME")
	os.unset_env("XDG_STATE_HOME")
	// Windows roaming/local app data.
	os.set_env("APPDATA", strings.concatenate({root, "/Roaming"}, context.temp_allocator))
	os.set_env("LOCALAPPDATA", strings.concatenate({root, "/Local"}, context.temp_allocator))
}

// A temp-dir subpath for a test, allocated in the temp allocator.
@(private = "file")
tmp :: proc(name: string) -> string {
	base, _ := os.temp_dir(context.temp_allocator)
	return strings.concatenate({base, "/", name}, context.temp_allocator)
}

// A throwaway App carrying just the config the paths code reads.
@(private = "file")
test_app :: proc(app_id: string, title := "") -> App {
	return App{cfg = App_Config{app_id = app_id, title = title}}
}

@(test)
test_app_dir_namespaced_and_created :: proc(t: ^testing.T) {
	root := tmp("hd-paths-test-1")
	sandbox_env(root)

	app := test_app("com.example.heimtest")

	for kind in Path_Kind {
		dir := app_dir(&app, kind, context.temp_allocator)
		testing.expectf(t, dir != "", "%v dir should resolve, got empty", kind)
		// Namespaced by the app id.
		testing.expectf(
			t,
			strings.has_suffix(dir, "com.example.heimtest"),
			"%v dir should end with the app id, got %q",
			kind,
			dir,
		)
		// Created on access.
		testing.expectf(t, os.exists(dir), "%v dir should exist after access: %q", kind, dir)
	}
}

@(test)
test_kinds_distinct_where_expected :: proc(t: ^testing.T) {
	root := tmp("hd-paths-test-2")
	sandbox_env(root)

	app := test_app("com.example.heimtest")
	cache := cache_dir(&app, context.temp_allocator)
	cfg := config_dir(&app, context.temp_allocator)
	// Cache is a different physical location than config on every platform.
	testing.expectf(t, cache != cfg, "cache (%q) should differ from config (%q)", cache, cfg)
}

@(test)
test_app_path_builds_file_and_parents :: proc(t: ^testing.T) {
	root := tmp("hd-paths-test-3")
	sandbox_env(root)

	app := test_app("com.example.heimtest")
	p := app_path(&app, .Data, "db/store.sqlite", context.temp_allocator)
	testing.expect(t, p != "", "app_path should resolve")
	testing.expect(t, strings.has_suffix(p, "store.sqlite"), "app_path should end with the file")
	// The parent ("db") subdir should have been created; the file itself should not.
	parent := p[:strings.last_index(p, "/")] if strings.contains(p, "/") else p
	testing.expectf(t, os.exists(parent), "app_path should create the parent dir: %q", parent)
}

@(test)
test_app_identifier_fallbacks :: proc(t: ^testing.T) {
	root := tmp("hd-paths-test-4")
	sandbox_env(root)

	// app_id wins.
	a1 := test_app("explicit.id", "Some Title")
	d1 := config_dir(&a1, context.temp_allocator)
	testing.expect(t, strings.has_suffix(d1, "explicit.id"), "app_id should be used when set")

	// Falls back to a sanitized title.
	a2 := test_app("", "My Cool App")
	d2 := config_dir(&a2, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(d2, "My-Cool-App"), "title should be sanitized into the id, got %q", d2)

	// Falls back to "heimdall-app" when both are empty.
	a3 := test_app("", "")
	d3 := config_dir(&a3, context.temp_allocator)
	testing.expect(t, strings.has_suffix(d3, "heimdall-app"), "should fall back to heimdall-app")
}

@(test)
test_id_sanitized_into_path_segment :: proc(t: ^testing.T) {
	// Path separators and odd chars in the id become '-' so it stays a single
	// segment; dots survive. Exercised through the public API (the sanitizer is
	// file-private).
	root := tmp("hd-paths-test-5")
	sandbox_env(root)

	app := test_app("com.ex/ample:app?")
	dir := config_dir(&app, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(dir, "com.ex-ample-app-"), "id should be sanitized to one segment, got %q", dir)
	// No raw separator from the id leaked a nested dir into the path.
	testing.expect(t, !strings.contains(dir, "ample/app"), "sanitized id must not introduce a nested dir")
}
