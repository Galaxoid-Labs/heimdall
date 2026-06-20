package main

import "core:fmt"
import "core:os"
import "core:strings"

// `heimdall bundle [--webview] [--skip-build] [--name <bin>]`
// Build a release binary and assemble a macOS `.app` bundle (Info.plist,
// executable, icon, PkgInfo). Requires [bundle].identifier in heimdall.toml.
//
// Defaults to the native backend (a real native .app). Pass --webview to bundle
// the webview/webview backend instead.
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

	when ODIN_OS != .Darwin {
		fmt.eprintln("heimdall bundle: only macOS .app bundling is implemented")
		os.exit(1)
	}

	// Required config.
	if strings.trim_space(p.bundle_id) == "" {
		fmt.eprintln(
`heimdall bundle: missing required setting [bundle].identifier

Add a reverse-DNS bundle id to heimdall.toml, e.g.:

  [bundle]
  identifier = "com.example.myapp"
  version    = "1.0.0"`,
		)
		os.exit(1)
	}

	// 1) Build the release binary (unless reusing an existing one).
	if !skip_build {
		if !build_binary(p, webview, false, p.name) {
			os.exit(1)
		}
	}
	if !file_exists(p.name) {
		fmt.eprintfln("heimdall bundle: binary %q not found (build it first)", p.name)
		os.exit(1)
	}

	display := p.display_name if p.display_name != "" else p.name
	app_dir := fmt.tprintf("%s.app", display)
	contents := fmt.tprintf("%s/Contents", app_dir)
	macos := fmt.tprintf("%s/MacOS", contents)
	resources := fmt.tprintf("%s/Resources", contents)

	// 2) Fresh bundle skeleton.
	_ = run_capture({"rm", "-rf", app_dir})
	if !run_capture({"mkdir", "-p", macos}).ok || !run_capture({"mkdir", "-p", resources}).ok {
		fmt.eprintln("heimdall bundle: failed to create bundle directories")
		os.exit(1)
	}

	// 3) Executable + PkgInfo.
	if !run_capture({"cp", p.name, fmt.tprintf("%s/%s", macos, p.name)}).ok {
		fmt.eprintln("heimdall bundle: failed to copy executable")
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/PkgInfo", contents), transmute([]u8)string("APPL????"))

	// 4) Icon (optional): .icns copied as-is, .png converted via sips+iconutil.
	has_icon := false
	if p.bundle_icon != "" {
		has_icon = bundle_icon(p.bundle_icon, resources)
	}

	// 5) Info.plist.
	plist := info_plist(p, display, has_icon)
	if os.write_entire_file(fmt.tprintf("%s/Info.plist", contents), transmute([]u8)plist) != nil {
		fmt.eprintln("heimdall bundle: failed to write Info.plist")
		os.exit(1)
	}

	fmt.printfln("heimdall bundle: done -> ./%s  (%s)", app_dir, p.bundle_id)

	// 6) Optionally sign (and notarize) the freshly-assembled bundle.
	if do_sign {
		identity := resolve_identity(p, adhoc)
		if !sign_app(app_dir, identity, p.sign_entitlements) {
			os.exit(1)
		}
		if notarize && !notarize_app(p, app_dir) {
			os.exit(1)
		}
	}
}

// Generate the Info.plist XML from project config.
@(private = "file")
info_plist :: proc(p: Project, display: string, has_icon: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	w :: proc(b: ^strings.Builder, key, val: string) {
		fmt.sbprintfln(b, "\t<key>%s</key>", key)
		fmt.sbprintfln(b, "\t<string>%s</string>", xml_escape(val))
	}

	strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	strings.write_string(
		&b,
		"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
	)
	strings.write_string(&b, "<plist version=\"1.0\">\n<dict>\n")

	w(&b, "CFBundleName", p.name)
	w(&b, "CFBundleDisplayName", display)
	w(&b, "CFBundleIdentifier", p.bundle_id)
	w(&b, "CFBundleExecutable", p.name)
	w(&b, "CFBundleShortVersionString", p.version)
	w(&b, "CFBundleVersion", p.build_number)
	w(&b, "CFBundlePackageType", "APPL")
	w(&b, "CFBundleInfoDictionaryVersion", "6.0")
	w(&b, "LSMinimumSystemVersion", p.min_macos)
	if p.category != "" {
		w(&b, "LSApplicationCategoryType", p.category)
	}
	if has_icon {
		w(&b, "CFBundleIconFile", "AppIcon")
	}
	strings.write_string(&b, "\t<key>NSHighResolutionCapable</key>\n\t<true/>\n")

	strings.write_string(&b, "</dict>\n</plist>\n")
	return strings.to_string(b)
}

// Place the app icon. .icns is copied directly; .png is converted to AppIcon.icns
// via `sips` + `iconutil`. Returns true if an icon was installed.
@(private = "file")
bundle_icon :: proc(icon: string, resources: string) -> bool {
	if !file_exists(icon) {
		fmt.eprintfln("heimdall bundle: icon %q not found, skipping", icon)
		return false
	}
	if strings.has_suffix(icon, ".icns") {
		return run_capture({"cp", icon, fmt.tprintf("%s/AppIcon.icns", resources)}).ok
	}
	if !strings.has_suffix(icon, ".png") {
		fmt.eprintfln("heimdall bundle: icon must be .png or .icns (got %q), skipping", icon)
		return false
	}

	// Generate an .iconset then convert with iconutil.
	iconset := fmt.tprintf("%s/AppIcon.iconset", resources)
	if !run_capture({"mkdir", "-p", iconset}).ok {
		return false
	}
	Spec :: struct {
		size: int,
		name: string,
	}
	specs := []Spec {
		{16, "icon_16x16.png"},
		{32, "icon_16x16@2x.png"},
		{32, "icon_32x32.png"},
		{64, "icon_32x32@2x.png"},
		{128, "icon_128x128.png"},
		{256, "icon_128x128@2x.png"},
		{256, "icon_256x256.png"},
		{512, "icon_256x256@2x.png"},
		{512, "icon_512x512.png"},
		{1024, "icon_512x512@2x.png"},
	}
	for s in specs {
		sz := fmt.tprintf("%d", s.size)
		out := fmt.tprintf("%s/%s", iconset, s.name)
		r := run_capture({"sips", "-z", sz, sz, icon, "--out", out})
		if !r.ok {
			fmt.eprintln("heimdall bundle: sips failed (is it on PATH?), skipping icon")
			_ = run_capture({"rm", "-rf", iconset})
			return false
		}
	}
	ok := run_capture({"iconutil", "-c", "icns", iconset, "-o", fmt.tprintf("%s/AppIcon.icns", resources)}).ok
	_ = run_capture({"rm", "-rf", iconset})
	if !ok {
		fmt.eprintln("heimdall bundle: iconutil failed, skipping icon")
	}
	return ok
}

@(private = "file")
xml_escape :: proc(s: string) -> string {
	if strings.index_any(s, "&<>") < 0 {
		return s
	}
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	return r
}
