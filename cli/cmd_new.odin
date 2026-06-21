package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:terminal"

// `heimdall new <name> [--frontend vanilla|sveltekit] [--pm bun|npm|pnpm|yarn|deno] [--framework <path>]`
//
// Scaffolds the Odin/heimdall shell (main.odin, services.odin, heimdall.toml,
// vendored heimdall/) plus a frontend. Two frontends today:
//   * vanilla   — embedded, dependency-free, bun-served (offline, zero deps).
//   * sveltekit — delegates to the official `sv create` (interactive), then
//                 patches the result for static embedding. --pm picks the package
//                 manager (default bun).
//
// New frontends are easy to add: append a Frontend to FRONTENDS with a scaffolder.
//
// The framework copy is resolved from --framework, else $HEIMDALL_HOME/heimdall.

// A package manager option for the (node-based) frontends. dev_cmd/build_cmd land
// in heimdall.toml; the runner used to fetch `sv` is derived in sv_cmd.
Pm :: struct {
	key:       string,
	dev_cmd:   string,
	build_cmd: string,
}

PMS := []Pm {
	{"bun", "bun run dev", "bun run build"},
	{"npm", "npm run dev", "npm run build"},
	{"pnpm", "pnpm run dev", "pnpm run build"},
	{"yarn", "yarn dev", "yarn build"},
	{"deno", "deno task dev", "deno task build"},
}

// Context threaded through scaffolding + template rendering.
Scaffold_Ctx :: struct {
	dir, proj, title:             string, // dir = project path; proj/title = base name
	pm:                           Pm,
	dist_dir, dev_cmd, build_cmd: string, // resolved values for heimdall.toml
	bindings:                     string, // typed-client base path
	addons:                       []string, // sveltekit: extra `sv` add-on specs
}

Frontend :: struct {
	key:      string,
	blurb:    string,
	dist_dir: string, // build output relative to project root (embedded)
	bindings: string, // typed-client base path (where generate-bindings writes)
	uses_pm:  bool, // true = node toolchain (--pm applies); false = bun-only embedded
	deps:     bool, // true = `bun install` etc. handled during scaffold
	scaffold: proc(ctx: ^Scaffold_Ctx) -> bool, // writes the web/ tree
}

FRONTENDS := []Frontend {
	{
		key = "vanilla",
		blurb = "dependency-free static files (any --pm: node/bun/deno, zero deps)",
		dist_dir = "web/dist",
		bindings = "web/src/heimdall.gen",
		uses_pm = true,
		deps = false,
		scaffold = scaffold_vanilla,
	},
	{
		key = "sveltekit",
		blurb = "official SvelteKit via `sv create` (interactive), patched for static embedding",
		dist_dir = "web/build",
		bindings = "web/src/lib/heimdall.gen",
		uses_pm = true,
		deps = true,
		scaffold = scaffold_sveltekit,
	},
}

cmd_new :: proc(args: []string) {
	name := ""
	framework := ""
	frontend_key := "vanilla"
	pm_key := "bun"
	addons := make([dynamic]string, context.temp_allocator) // sveltekit: extra `sv` add-ons

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--framework":
			i += 1;if i < len(args) {framework = args[i]}
		case "--frontend":
			i += 1;if i < len(args) {frontend_key = args[i]}
		case "--pm":
			i += 1;if i < len(args) {pm_key = args[i]}
		case "--add":
			i += 1;if i < len(args) {append(&addons, args[i])}
		case:
			if name == "" && !strings.has_prefix(args[i], "--") {name = args[i]}
		}
		i += 1
	}

	if name == "" {
		fmt.eprintln(
			"usage: heimdall new <name> [--frontend vanilla|sveltekit] [--pm bun|npm|pnpm|yarn|deno]\n" +
			"                          [--add <sv-addon>]... [--framework <path>]\n" +
			"  --add  (sveltekit only, repeatable) an `sv` add-on, e.g. --add tailwindcss=plugins:typography",
		)
		os.exit(1)
	}

	fe, fe_ok := find_frontend(frontend_key)
	if !fe_ok {
		fmt.eprintfln("heimdall new: unknown --frontend %q. available:", frontend_key)
		for f in FRONTENDS {
			fmt.eprintfln("  %-10s %s", f.key, f.blurb)
		}
		os.exit(1)
	}
	pm, pm_ok := find_pm(pm_key)
	if !pm_ok {
		fmt.eprintf("heimdall new: unknown --pm %q. available:", pm_key)
		for p in PMS {fmt.eprintf(" %s", p.key)}
		fmt.eprintln()
		os.exit(1)
	}

	if framework == "" {
		if home, ok := os.lookup_env("HEIMDALL_HOME", context.temp_allocator); ok {
			framework = strings.concatenate({home, "/heimdall"}, context.temp_allocator)
		}
	}
	if framework == "" || !file_exists(framework) {
		fmt.eprintln(
			"heimdall new: framework package not found.\n  pass --framework <path-to-heimdall-pkg> or set HEIMDALL_HOME.",
		)
		os.exit(1)
	}
	if file_exists(name) {
		fmt.eprintfln("heimdall new: %q already exists", name)
		os.exit(1)
	}

	proj := filepath.base(name)
	ctx := Scaffold_Ctx {
		dir      = name,
		proj     = proj,
		title    = proj,
		pm       = pm,
		dist_dir = fe.dist_dir,
		bindings = fe.bindings,
		addons   = addons[:],
	}
	ctx.dev_cmd = pm.dev_cmd
	ctx.build_cmd = pm.build_cmd

	// Shared Odin/heimdall shell (written for every frontend).
	write_file_p(cat(name, "/main.odin"), render(TMPL_MAIN, &ctx))
	write_file_p(cat(name, "/services.odin"), render(TMPL_SERVICES, &ctx))
	write_file_p(cat(name, "/heimdall.toml"), render(TMPL_TOML, &ctx))
	write_file_p(cat(name, "/.gitignore"), render(TMPL_GITIGNORE, &ctx))
	write_file_p(cat(name, "/build.sh"), render(TMPL_BUILD_SH, &ctx))
	write_file_p(cat(name, "/.github/workflows/release.yml"), render(TMPL_WORKFLOW, &ctx))

	// Default app icon (the Heimdall mark) — referenced by App_Config.icon and
	// [bundle].icon. Replace icon.png with your own; it's a normal source file.
	if werr := os.write_entire_file(cat(name, "/icon.png"), ICON_PNG); werr != nil {
		fmt.eprintfln("heimdall new: failed to write icon.png: %v", werr)
		os.exit(1)
	}

	// Vendor the framework package into ./<name>/heimdall (cross-platform copy).
	if err := os.copy_directory_all(cat(name, "/heimdall"), framework); err != nil {
		fmt.eprintfln("heimdall new: failed to vendor framework: %v", err)
		os.exit(1)
	}

	// Copy the Claude Code skills (heimdall + odin-lang) into ./<name>/.claude/skills
	// so Claude has Heimdall + Odin knowledge in the new project. The skills live
	// beside the framework dir (repo root in dev; $HEIMDALL_HOME / the install root
	// otherwise, where install.sh extracts them from the framework tarball).
	skills_src, _ := filepath.join({filepath.dir(framework), ".claude", "skills"}, context.temp_allocator)
	if file_exists(skills_src) {
		mkdir_p(cat(name, "/.claude")) // copy_directory_all needs the dest's parent to exist
		if err := os.copy_directory_all(cat(name, "/.claude/skills"), skills_src); err != nil {
			fmt.eprintfln("heimdall new: note — skills not copied: %v", err)
		}
	}

	// Frontend (vanilla writes files; sveltekit delegates to `sv create`).
	if !fe.scaffold(&ctx) {
		fmt.eprintfln("heimdall new: created %s/, but the frontend setup did not finish", name)
		os.exit(1)
	}

	// Generate the typed client now so it's present immediately (dev/build keep it
	// fresh thereafter). Best-effort — the app still works with the untyped alias.
	if !write_client_bindings(name, name, fe.bindings, "heimdall", {}) {
		fmt.eprintln("heimdall new: typed client not generated (run `heimdall generate-bindings` later)")
	}

	print_next_steps(name, fe)
}

@(private = "file")
find_frontend :: proc(key: string) -> (Frontend, bool) {
	for f in FRONTENDS {
		if f.key == key {return f, true}
	}
	return {}, false
}

@(private = "file")
find_pm :: proc(key: string) -> (Pm, bool) {
	for p in PMS {
		if p.key == key {return p, true}
	}
	return {}, false
}

// ANSI styling, gated on core:terminal's cross-platform color detection (respects
// NO_COLOR, enables VT processing on Windows, off when stdout isn't a terminal).
// Structure is ASCII-only so it renders on any platform/codepage even uncolored.
@(private = "file")
paint :: proc(code, s: string) -> string {
	if !terminal.color_enabled {return s}
	return strings.concatenate({"\x1b[", code, "m", s, "\x1b[0m"}, context.temp_allocator)
}

@(private = "file")
print_next_steps :: proc(name: string, fe: Frontend) {
	BOLD :: "1";GREEN :: "1;32";CYAN :: "36";DIM :: "2"
	rule := "============================================================"

	fmt.printfln("\n  %s", paint(CYAN, rule))
	fmt.printfln(
		"   %s   %s",
		paint(GREEN, fmt.tprintf("created %s/", name)),
		paint(DIM, fmt.tprintf("(frontend: %s)", fe.key)),
	)
	fmt.printfln("  %s\n", paint(CYAN, rule))

	if fe.deps {
		// A delegated frontend (e.g. SvelteKit) prints its own closing tips; point
		// the user at ours instead.
		fmt.printfln(
			"  %s   %s",
			paint(BOLD, "Heimdall - next steps"),
			paint(DIM, "(use these, not the tool's tips above)"),
		)
	} else {
		fmt.printfln("  %s", paint(BOLD, "Heimdall - next steps"))
	}

	fmt.printfln("\n    cd %s", name)
	if !fe.deps {
		fmt.printfln("    %s   %s", paint(CYAN, "(cd web && bun install)"), paint(DIM, "# sets up bun"))
	}
	fmt.printfln("    %s        %s", paint(CYAN, "heimdall dev"), paint(DIM, "# open the app (live reload as you edit)"))
	fmt.printfln("    %s      %s", paint(CYAN, "heimdall build"), paint(DIM, "# -> one binary, assets embedded"))
	fmt.println()
}

// ---- vanilla frontend -----------------------------------------------------

@(private = "file")
scaffold_vanilla :: proc(ctx: ^Scaffold_Ctx) -> bool {
	d := ctx.dir
	write_file_p(cat(d, "/web/index.html"), render(TMPL_INDEX_HTML, ctx))
	write_file_p(cat(d, "/web/src/main.js"), render(TMPL_MAIN_JS, ctx))
	// deno uses `deno task` (deno.json); the rest use package.json scripts.
	if ctx.pm.key == "deno" {
		write_file_p(cat(d, "/web/deno.json"), render(TMPL_DENO_JSON, ctx))
	} else {
		write_file_p(cat(d, "/web/package.json"), render(TMPL_PACKAGE_JSON, ctx))
	}
	write_file_p(cat(d, "/web/dev.js"), render(TMPL_DEV_JS, ctx))
	write_file_p(cat(d, "/web/build.js"), render(TMPL_BUILD_JS, ctx))
	return true
}

// ---- sveltekit frontend (delegates to `sv create`) ------------------------

@(private = "file")
scaffold_sveltekit :: proc(ctx: ^Scaffold_Ctx) -> bool {
	web := cat(ctx.dir, "/web")

	// Run the official `sv create`. The static adapter MUST be configured during
	// create (adding it afterward with `sv add` leaves the project in a state that
	// breaks Tailwind's dev transform), so we pass it via `--add` — which also means
	// the add-on menu is non-interactive: any extra add-ons (Tailwind, …) come from
	// heimdall's repeatable `--add` flag. Template + TypeScript stay interactive.
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "create", "web", "--add", "sveltekit-adapter=adapter:static")
	append(&args, ..ctx.addons) // user-requested add-ons (e.g. tailwindcss=plugins:typography)
	append(&args, "--install", ctx.pm.key, "--no-download-check")
	cmd := sv_cmd(ctx.pm, args[:])

	if !has_exe(cmd[0]) {
		fmt.eprintfln(
			"heimdall new: %q not found — needed to run the Svelte CLI for --pm %s",
			cmd[0],
			ctx.pm.key,
		)
		return false
	}

	fmt.println("\nheimdall new: launching SvelteKit setup (sv create) — follow the prompts…\n")
	if !run_inherit(shell_command(cmd), ctx.dir) {
		fmt.eprintln("heimdall new: `sv create` did not complete")
		return false
	}

	// Heimdall-ify: make it a static SPA (SSR-off + a best-effort SPA fallback).
	add_spa_layout(web)
	patch_adapter_fallback(web)

	// `sv create --install` should have installed deps, but make it certain (and
	// idempotent — a no-op if node_modules already exists).
	if !file_exists(cat(web, "/node_modules")) {
		install := ctx.pm.key == "deno" ? []string{"deno", "install"} : []string{ctx.pm.key, "install"}
		run_inherit(shell_command(install), web)
	}
	return true
}

// Build the `sv` invocation for the chosen package manager. Each PM has its own
// way to run a published CLI; the trailing args are appended verbatim.
@(private = "file")
sv_cmd :: proc(pm: Pm, args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	switch pm.key {
	case "npm":
		append(&out, "npx", "-y", "sv@latest")
	case "pnpm":
		append(&out, "pnpm", "dlx", "sv@latest")
	case "yarn":
		append(&out, "yarn", "dlx", "sv@latest")
	case "deno":
		append(&out, "deno", "run", "-A", "npm:sv@latest")
	case:
		append(&out, "bunx", "sv@latest") // bun (default)
	}
	append(&out, ..args)
	return out[:]
}

// Add `export const ssr = false;` to the root layout so the build is a static SPA.
// Works for both JS and TS projects: a `.js` route module is valid everywhere, so
// we target an existing +layout.{ts,js} (appending) or create +layout.js.
@(private = "file")
add_spa_layout :: proc(web: string) {
	for ext in ([?]string{".ts", ".js"}) {
		p := strings.concatenate({web, "/src/routes/+layout", ext}, context.temp_allocator)
		if data, err := os.read_entire_file(p, context.temp_allocator); err == nil {
			if strings.contains(string(data), "const ssr") {return}
			write_file(p, strings.concatenate({string(data), "\n", LAYOUT_SPA}, context.temp_allocator))
			return
		}
	}
	write_file_p(cat(web, "/src/routes/+layout.js"), LAYOUT_SPA)
}

// Best-effort: turn `adapter()` into `adapter({ fallback: 'index.html' })` so
// client-side routes resolve in the embedded SPA. Scans both config locations and
// both extensions (current SvelteKit inlines the adapter in vite.config.*; older
// versions use svelte.config.*). No-op if the call already has options.
@(private = "file")
patch_adapter_fallback :: proc(web: string) {
	for c in ([?]string{"/vite.config.ts", "/vite.config.js", "/svelte.config.js", "/svelte.config.ts"}) {
		p := cat(web, c)
		data, err := os.read_entire_file(p, context.temp_allocator)
		if err != nil {continue}
		s := string(data)
		if !strings.contains(s, "adapter()") {continue}
		out, _ := strings.replace_all(
			s,
			"adapter()",
			"adapter({ fallback: 'index.html' })",
			context.temp_allocator,
		)
		write_file(p, out)
		return
	}
}

// ---- helpers --------------------------------------------------------------

@(private = "file")
cat :: proc(a, b: string) -> string {
	return strings.concatenate({a, b}, context.temp_allocator)
}

// Token-based templating (NOT fmt) so template braces/percent signs pass through
// untouched. Replaces __NAME__, __TITLE__, and the toml command/dir tokens.
@(private = "file")
render :: proc(tmpl: string, ctx: ^Scaffold_Ctx) -> string {
	s, _ := strings.replace_all(tmpl, "__NAME__", ctx.proj, context.temp_allocator)
	s, _ = strings.replace_all(s, "__TITLE__", ctx.title, context.temp_allocator)
	s, _ = strings.replace_all(s, "__DIST_DIR__", ctx.dist_dir, context.temp_allocator)
	s, _ = strings.replace_all(s, "__DEV_CMD__", ctx.dev_cmd, context.temp_allocator)
	s, _ = strings.replace_all(s, "__BUILD_CMD__", ctx.build_cmd, context.temp_allocator)
	s, _ = strings.replace_all(s, "__BINDINGS__", ctx.bindings, context.temp_allocator)
	s, _ = strings.replace_all(s, "__JS_RUNTIME__", js_runtime(ctx.pm.key), context.temp_allocator)
	return s
}

// The runtime that executes the vanilla starter's dev.js / build.js for a given
// package manager. The scripts are written node-style (node: APIs), which all
// three runtimes support.
@(private = "file")
js_runtime :: proc(pm_key: string) -> string {
	switch pm_key {
	case "bun":
		return "bun"
	case "deno":
		return "deno run -A"
	case:
		return "node" // npm / pnpm / yarn
	}
}

@(private = "file")
mkdir_p :: proc(path: string) {
	if path == "" || path == "." {return}
	if err := os.make_directory_all(path); err != nil && err != .Exist {
		fmt.eprintfln("heimdall new: failed to create %s: %v", path, err)
		os.exit(1)
	}
}

@(private = "file")
write_file :: proc(path, content: string) {
	if werr := os.write_entire_file(path, transmute([]u8)content); werr != nil {
		fmt.eprintfln("heimdall new: failed to write %s: %v", path, werr)
		os.exit(1)
	}
}

// write_file, ensuring the parent directory exists first.
@(private = "file")
write_file_p :: proc(path, content: string) {
	mkdir_p(filepath.dir(path))
	write_file(path, content)
}

// ---- shared templates -----------------------------------------------------

// The default app icon (the Heimdall mark, rendered from docs/public/logo.svg),
// embedded into the CLI and written into every new project as icon.png.
@(private = "file")
ICON_PNG := #load("icon.png")

TMPL_MAIN :: `package main

import "core:fmt"
import "core:os"
import hd "heimdall"

main :: proc() {
	app, err := hd.create(hd.App_Config{
		title     = "__TITLE__",
		app_id    = "com.example.__NAME__",  // names your per-app config/data/cache/log dirs (hd.config_dir, etc.) — change to your own reverse-DNS id
		width     = 800,
		height    = 600,
		resizable = true,
		dev_url   = "http://localhost:5173", // used by ` + "`heimdall dev`" + `
		assets    = ASSETS,                  // embedded by ` + "`heimdall build`" + `
		// Web inspector (right-click → Inspect Element). Default .Auto = on in
		// ` + "`heimdall dev`" + `, off in ` + "`heimdall build`" + `. Use .On to force it, .Off to disable.
		// devtools = .On,
		icon      = #load("icon.png"),       // window/app icon (macOS dock; bundles use [bundle].icon)
		// Native menus are OPTIONAL. macOS always shows the standard
		// App/Edit/Window menus; Linux shows no menu bar unless you add one here.
		// Items with an id emit a "menu" { id } event (subscribe in JS with
		// on("menu", ...)); role items are standard actions. Uncomment to add a
		// menu (use "CmdOrCtrl+..." so accelerators work on every platform):
		// menu = {
		// 	{label = "File", submenu = {
		// 		{label = "New",   id = "file.new",  accelerator = "CmdOrCtrl+N"},
		// 		{label = "Open…", id = "file.open", accelerator = "CmdOrCtrl+O"},
		// 		{separator = true},
		// 		{label = "Close", role = .Quit},
		// 	}},
		// },
		// Deep linking is OPTIONAL. List the schemes you handle here AND register
		// them with the OS via [bundle].schemes in heimdall.toml. Incoming URLs
		// arrive as an "open-url" event (on("open-url", ...)) and/or this hook:
		// url_schemes = {"__NAME__"},
		// on_open_url = proc(app: ^hd.App, url: string) { fmt.println("opened:", url) },
	})
	if err != nil {
		fmt.eprintfln("create failed: %v", err)
		os.exit(1)
	}
	defer hd.destroy(app)

	greeting := Greeting{prefix = "Hello, "}
	g := hd.service(app, "greeting", &greeting)
	hd.command(g, "greet", greet)

	hd.run(app)
}
`

TMPL_SERVICES :: `package main

import "core:fmt"
import hd "heimdall"

Greeting :: struct {
	prefix: string,
}

Greet_Args :: struct {
	name: string,
}

Greet_Result :: struct {
	message: string,
}

// invoke("greeting.greet", {name}) -> {message}
greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
	return Greet_Result{message = fmt.tprintf("%s%s", s.prefix, args.name)}, nil
}
`

TMPL_TOML :: `# heimdall project config
name      = "__NAME__"
web_dir   = "web"
dist_dir  = "__DIST_DIR__"
dev_cmd   = "__DEV_CMD__"
build_cmd = "__BUILD_CMD__"
dev_url   = "http://localhost:5173"
# Typed JS client: dev/build regenerate <bindings>.js + .d.ts from your Odin
# command types. Remove this line to opt out (the untyped window.heimdall still works).
bindings  = "__BINDINGS__"
# title shown in the window: __TITLE__

# Packaging metadata for ` + "`heimdall bundle`" + `.
# [bundle] holds settings common to every platform; [bundle.<platform>] overrides
# per-platform — so you only repeat what's actually platform-specific.
# identifier is REQUIRED to bundle.
[bundle]
identifier   = "com.example.__NAME__"
version      = "0.1.0"
build        = "1"
display_name = "__TITLE__"
icon         = "icon.png"   # app icon (macOS .icns, Linux hicolor, Windows .ico + exe resource)
# Deep linking: register custom URL scheme(s) so the OS routes myapp://… to your
# app. Match these in App_Config.url_schemes. Comma-separate for multiple.
# schemes     = "__NAME__"
# Used across platforms; on Windows, maintainer -> installer Publisher, homepage -> its URL:
# summary     = "A short one-liner"
# description = "A longer description."
# maintainer  = "Your Name <you@example.com>"
# license     = "MIT"
# homepage    = "https://example.com"

[bundle.macos]
min_macos    = "11.0"
# category   = "public.app-category.developer-tools"
# icon       = "icon.icns"  # macOS-specific icon (else the common one is used)

[bundle.linux]
category     = "Utility;"   # freedesktop Categories for the .desktop entry
# deb_depends = "libwebkitgtk-6.0-4, libadwaita-1-0, libgtk-4-1"  # .deb only; .rpm auto-detects

# Windows: 'heimdall bundle' makes an Inno Setup installer (.exe) + a portable .zip.
# The app .exe is self-contained (no DLLs); end users only need the WebView2 runtime,
# which ships with Win10/11. Building the installer needs Inno Setup 6 on YOUR machine
# (winget install JRSoftware.InnoSetup6); without it you still get the .zip. The app
# icon/version are embedded via the Windows SDK's rc.exe. Run 'heimdall doctor' to check.
# [bundle.windows]

# Code signing for ` + "`heimdall sign`" + ` / ` + "`heimdall bundle --sign`" + `.
# No secrets here — identity is a cert name; CI overrides via HEIMDALL_SIGN_IDENTITY.
# Local testing: ` + "`heimdall bundle --adhoc`" + ` (no certificate needed).
[sign.macos]
# identity       = "Developer ID Application: Your Name (TEAMID)"
# entitlements   = "entitlements.plist"
# notary_profile = "__NAME__-notary"   # xcrun notarytool store-credentials name

# [sign.windows]
# identity = "Your Company, Inc."   # certificate subject
`

TMPL_GITIGNORE :: `assets_gen.odin
# Generated typed client (regenerated by dev/build/generate-bindings)
**/heimdall.gen.js
**/heimdall.gen.d.ts
web/dist/
web/build/
web/.svelte-kit/
web/node_modules/
/__NAME__
*.app/
*.deb
*.rpm
*.bin
.DS_Store
`

TMPL_BUILD_SH :: `#!/usr/bin/env bash
set -euo pipefail
(cd web && __BUILD_CMD__)
heimdall embed __DIST_DIR__ ./assets_gen.odin
odin build . -o:speed -out:app
echo "built -> ./app"
`

// GitHub Actions: build + bundle + sign + notarize a macOS .app on tag push,
// using the reusable heimdall composite action. Replace OWNER/heimdall with the
// repo hosting heimdall, and set the secrets named below (Settings -> Secrets
// and variables -> Actions). Drop the signing inputs to ship an unsigned/ad-hoc
// build, or use ` + "`command: bundle --adhoc`" + `.
TMPL_WORKFLOW :: `name: release
on:
  push:
    tags: ["v*"]
  workflow_dispatch:

jobs:
  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v5

      - name: Build, bundle, sign, notarize
        uses: OWNER/heimdall@v1   # <-- the repo hosting heimdall
        with:
          command: bundle --sign --notarize
          sign-identity: ` + "${{ secrets.MACOS_SIGN_IDENTITY }}" + `
          macos-cert-p12: ` + "${{ secrets.MACOS_CERT_P12 }}" + `
          macos-cert-password: ` + "${{ secrets.MACOS_CERT_PASSWORD }}" + `
          apple-id: ` + "${{ secrets.APPLE_ID }}" + `
          apple-team-id: ` + "${{ secrets.APPLE_TEAM_ID }}" + `
          apple-app-password: ` + "${{ secrets.APPLE_APP_PASSWORD }}" + `

      - uses: actions/upload-artifact@v5
        with:
          name: __NAME__-macos
          path: "*.app"
`

// ---- vanilla frontend templates -------------------------------------------

TMPL_INDEX_HTML :: `<!doctype html>
<html>
<head><meta charset="utf-8"><title>__TITLE__</title></head>
<body>
  <h1>__TITLE__</h1>
  <input id="name" value="world">
  <button id="go">greet</button>
  <p id="out"></p>
  <script type="module" src="/src/main.js"></script>
</body>
</html>
`

TMPL_MAIN_JS :: `// Typed client generated from your Odin command types (heimdall generate-bindings,
// also auto-run by dev/build). Or skip it and use window.heimdall.invoke(...) directly.
import { greeting, on } from "./heimdall.gen.js";

document.querySelector("#go").addEventListener("click", async () => {
  const name = document.querySelector("#name").value;
  const { message } = await greeting.greet({ name });   // typed: args + result
  document.querySelector("#out").textContent = message;
});

// Native menu clicks arrive as a "menu" event with the item's id.
on("menu", (e) => {
  console.log("menu:", e.id);
});

// Deep link: if you enable a URL scheme (App_Config.url_schemes + [bundle].schemes),
// opening myapp://… delivers the URL here.
on("open-url", (e) => {
  console.log("open-url:", e.url);
});
`

TMPL_PACKAGE_JSON :: `{
  "name": "__NAME__-web",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "__JS_RUNTIME__ dev.js",
    "build": "__JS_RUNTIME__ build.js"
  }
}
`

// For --pm deno (which uses `deno task`, not package.json scripts).
TMPL_DENO_JSON :: `{
  "tasks": {
    "dev": "deno run -A dev.js",
    "build": "deno run -A build.js"
  }
}
`

TMPL_DEV_JS :: `// Minimal static dev server (no deps). Serves the web/ folder on :5173.
// Written with node: APIs so it runs the same under node, bun, and deno.
import { createServer } from "node:http";
import { readFile } from "node:fs";
import { extname, join, normalize } from "node:path";

const PORT = 5173;
const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png",
  ".ico": "image/x-icon", ".woff2": "font/woff2",
};

createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
  if (p === "/") p = "/index.html";
  const file = join(".", normalize(p));
  readFile(file, (err, data) => {
    if (err) { res.statusCode = 404; res.end("not found"); return; }
    res.setHeader("Content-Type", MIME[extname(file)] || "application/octet-stream");
    res.end(data);
  });
}).listen(PORT, () => console.log("dev server -> http://localhost:" + PORT));
`

TMPL_BUILD_JS :: `// Copy the static frontend into dist/. Replace with your bundler if you like.
// node: APIs so it runs under node, bun, and deno alike.
import { mkdirSync, rmSync, cpSync } from "node:fs";
rmSync("dist", { recursive: true, force: true });
mkdirSync("dist", { recursive: true });
cpSync("index.html", "dist/index.html");
cpSync("src", "dist/src", { recursive: true });
console.log("built -> dist/");
`

// ---- sveltekit patch fragment ---------------------------------------------

LAYOUT_SPA :: `// heimdall: build a static SPA for embedding (no SSR server at runtime).
// ssr=false makes pages client-rendered; the adapter's fallback (index.html) boots
// the SPA for every route. We deliberately do NOT set prerender=true so routes with
// server load/actions don't fail the static build (they just won't run server-side
// — there is no server in an embedded app).
export const ssr = false;
`
