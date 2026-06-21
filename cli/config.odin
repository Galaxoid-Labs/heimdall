package main

import "core:os"
import "core:strings"

// Project config, read from heimdall.toml when present. Kept tiny on purpose.
//
// Platform model: `[bundle]` / `[sign]` hold settings common to all platforms;
// `[bundle.macos]` / `[bundle.windows]` / `[bundle.linux]` (and `[sign.<plat>]`)
// override per-platform. A setting resolves platform-first, then falls back to
// the common section — so you only repeat what's actually platform-specific.
// (Backward compatible: a flat `[bundle]` with everything in it still works.)
Project :: struct {
	name:        string, // output binary name
	web_dir:     string, // frontend source dir
	dist_dir:    string, // frontend build output (embedded)
	build_cmd:   string, // frontend production build
	dev_cmd:     string, // frontend dev server
	dev_url:     string, // URL the dev server serves
	import_path: string, // framework import path for generated assets_gen.odin
	collection:  string, // optional odin -collection flag value (e.g. "src=.")
	bindings:    string, // typed-client base path (e.g. web/src/heimdall.gen); "" disables auto-gen

	// [bundle] (+ [bundle.<platform>]) — packaging metadata.
	bundle_id:    string, // CFBundleIdentifier (REQUIRED to bundle), e.g. com.acme.app
	version:      string, // marketing version, e.g. 1.0.0
	build_number: string, // build version, e.g. 1
	display_name: string, // display name; defaults to name
	category:     string, // app category — macOS LSApplicationCategoryType; on Linux, freedesktop Categories (e.g. "Utility;")
	min_macos:    string, // LSMinimumSystemVersion (macOS)
	bundle_icon:  string, // path to an app icon (.icns/.png on macOS; .png on Linux)
	schemes:      []string, // deep-link URL schemes to register (e.g. "myapp" or "myapp,acme")

	// Linux packaging ([bundle] + [bundle.linux]) — .deb / .rpm metadata.
	summary:      string, // one-line description (defaults to display_name)
	description:  string, // longer description (defaults to summary)
	maintainer:   string, // "Name <email>" (DEB Maintainer / RPM Packager)
	license:      string, // license string (DEB/RPM License field)
	homepage:     string, // project URL (optional)
	deb_depends:  string, // override DEB Depends (default: GTK4/webkit runtime libs)
	rpm_requires: string, // override RPM Requires (default: auto-detected from the ELF)

	// [sign] (+ [sign.<platform>]) — code-signing.
	sign_identity:     string, // macOS: "Developer ID Application: …" / "-"; Windows: cert subject
	sign_entitlements: string, // macOS entitlements plist (optional)
	notary_profile:    string, // macOS notarytool keychain-profile name (optional)
}

default_project :: proc() -> Project {
	return Project {
		name = "app",
		web_dir = "web",
		dist_dir = "web/dist",
		build_cmd = "bun run build",
		dev_cmd = "bun run dev",
		dev_url = "http://localhost:5173",
		import_path = "heimdall",
		collection = "",
		version = "0.1.0",
		build_number = "1",
		min_macos = "11.0",
	}
}

// The platform key used for `[section.<platform>]` overrides, from the host OS
// (you build/bundle for a platform on that platform).
@(private = "file")
current_platform :: proc() -> string {
	when ODIN_OS == .Darwin {
		return "macos"
	} else when ODIN_OS == .Windows {
		return "windows"
	} else when ODIN_OS == .Linux {
		return "linux"
	} else {
		return ""
	}
}

// Load heimdall.toml from `dir` (or cwd), overlaying onto defaults. Minimal
// parser: `key = "value"` lines, '#' comments, and `[section]` headers (keys are
// namespaced as `section.key`). Values are collected, then resolved per-platform.
load_project :: proc(dir := ".") -> Project {
	p := default_project()
	path := strings.concatenate({dir, "/heimdall.toml"}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return p
	}

	// Collect all key=value pairs keyed by full dotted path.
	values := make(map[string]string, 32, context.temp_allocator)
	section := ""
	it := string(data)
	for {
		idx := strings.index_byte(it, '\n')
		line := it if idx < 0 else it[:idx]
		section = collect_toml_line(&values, line, section)
		if idx < 0 {
			break
		}
		it = it[idx + 1:]
	}

	resolve_project(&p, values, current_platform())
	return p
}

// Parse a value after `=`: a quoted string (value is between the quotes; trailing
// inline comment ignored), or an unquoted value (truncated at an inline `#`).
@(private = "file")
parse_toml_value :: proc(rest: string) -> string {
	if len(rest) > 0 && (rest[0] == '"' || rest[0] == '\'') {
		q := rest[0]
		if close := strings.index_byte(rest[1:], q); close >= 0 {
			return rest[1:1 + close]
		}
		return rest[1:] // unterminated quote — take the rest
	}
	v := rest
	if h := strings.index_byte(v, '#'); h >= 0 { // strip inline comment
		v = v[:h]
	}
	return strings.trim_space(v)
}

// Parse one line into `values`; returns the (possibly updated) current section.
@(private = "file")
collect_toml_line :: proc(values: ^map[string]string, raw: string, section: string) -> string {
	line := strings.trim_space(raw)
	if line == "" || line[0] == '#' {
		return section
	}
	if line[0] == '[' {
		return strings.clone(strings.trim(line, "[]"), context.temp_allocator)
	}
	eq := strings.index_byte(line, '=')
	if eq < 0 {
		return section
	}
	key := strings.trim_space(line[:eq])
	val := parse_toml_value(strings.trim_space(line[eq + 1:]))

	full := key
	if section != "" {
		full = strings.concatenate({section, ".", key}, context.temp_allocator)
	}
	values[full] = strings.clone(val, context.temp_allocator)
	return section
}

// Resolve a `[section]`/`[section.<plat>]` setting, platform-first.
@(private = "file")
resolve :: proc(m: map[string]string, section, key, plat: string) -> (string, bool) {
	if plat != "" {
		if v, ok := m[strings.concatenate({section, ".", plat, ".", key}, context.temp_allocator)];
		   ok {
			return v, true
		}
	}
	v, ok := m[strings.concatenate({section, ".", key}, context.temp_allocator)]
	return v, ok
}

@(private = "file")
resolve_project :: proc(p: ^Project, m: map[string]string, plat: string) {
	// Top-level project settings (common across platforms).
	if v, ok := m["name"]; ok {p.name = v}
	if v, ok := m["web_dir"]; ok {p.web_dir = v}
	if v, ok := m["dist_dir"]; ok {p.dist_dir = v}
	if v, ok := m["build_cmd"]; ok {p.build_cmd = v}
	if v, ok := m["dev_cmd"]; ok {p.dev_cmd = v}
	if v, ok := m["dev_url"]; ok {p.dev_url = v}
	if v, ok := m["import_path"]; ok {p.import_path = v}
	if v, ok := m["collection"]; ok {p.collection = v}
	if v, ok := m["bindings"]; ok {p.bindings = v}

	// [bundle] common + [bundle.<plat>] overrides.
	if v, ok := resolve(m, "bundle", "identifier", plat); ok {p.bundle_id = v}
	if v, ok := resolve(m, "bundle", "version", plat); ok {p.version = v}
	if v, ok := resolve(m, "bundle", "build", plat); ok {p.build_number = v}
	if v, ok := resolve(m, "bundle", "display_name", plat); ok {p.display_name = v}
	if v, ok := resolve(m, "bundle", "category", plat); ok {p.category = v}
	if v, ok := resolve(m, "bundle", "min_macos", plat); ok {p.min_macos = v}
	if v, ok := resolve(m, "bundle", "icon", plat); ok {p.bundle_icon = v}
	if v, ok := resolve(m, "bundle", "schemes", plat); ok {p.schemes = split_csv(v)}
	if v, ok := resolve(m, "bundle", "summary", plat); ok {p.summary = v}
	if v, ok := resolve(m, "bundle", "description", plat); ok {p.description = v}
	if v, ok := resolve(m, "bundle", "maintainer", plat); ok {p.maintainer = v}
	if v, ok := resolve(m, "bundle", "license", plat); ok {p.license = v}
	if v, ok := resolve(m, "bundle", "homepage", plat); ok {p.homepage = v}
	if v, ok := resolve(m, "bundle", "deb_depends", plat); ok {p.deb_depends = v}
	if v, ok := resolve(m, "bundle", "rpm_requires", plat); ok {p.rpm_requires = v}

	// [sign] common + [sign.<plat>] overrides.
	if v, ok := resolve(m, "sign", "identity", plat); ok {p.sign_identity = v}
	if v, ok := resolve(m, "sign", "entitlements", plat); ok {p.sign_entitlements = v}
	if v, ok := resolve(m, "sign", "notary_profile", plat); ok {p.notary_profile = v}
}

// Split a comma-separated value into trimmed, non-empty parts.
@(private = "file")
split_csv :: proc(s: string) -> []string {
	out := make([dynamic]string)
	for part in strings.split(s, ",") {
		t := strings.trim_space(part)
		if t != "" {
			append(&out, strings.clone(t))
		}
	}
	return out[:]
}
