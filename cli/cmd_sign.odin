package main

import "core:fmt"
import "core:os"
import "core:strings"

// `heimdall sign [target] [--adhoc] [--notarize]`
// Code-sign the app. One command, per-OS behavior:
//   macOS   — codesign (hardened runtime) + verify; --notarize runs notarytool+staple
//   Windows — signtool (stub; not yet implemented)
//   Linux   — no-op (no OS-level signing requirement)
//
// The signing identity resolves from (highest first): --adhoc, the env var
// HEIMDALL_SIGN_IDENTITY, then [sign].identity in heimdall.toml. Keeping it in
// env means CI can inject it without secrets in the repo.
cmd_sign :: proc(args: []string) {
	p := load_project()
	target := ""
	adhoc := false
	notarize := false

	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--adhoc":
			adhoc = true
		case "--notarize":
			notarize = true
		case:
			if !strings.has_prefix(a, "-") && target == "" {target = a}
		}
		i += 1
	}
	if target == "" {
		target = app_path(p)
	}
	if !file_exists(target) {
		fmt.eprintfln("heimdall sign: target %q not found (build/bundle it first)", target)
		os.exit(1)
	}

	identity := resolve_identity(p, adhoc)
	if !sign_app(target, identity, p.sign_entitlements) {
		os.exit(1)
	}
	if notarize && !notarize_app(p, target) {
		os.exit(1)
	}
}

// Default app path from config: "<DisplayName>.app".
app_path :: proc(p: Project) -> string {
	display := p.display_name if p.display_name != "" else p.name
	return fmt.tprintf("%s.app", display)
}

// "-" for ad-hoc; else env override; else config. "" means "none configured".
resolve_identity :: proc(p: Project, adhoc: bool) -> string {
	if adhoc {
		return "-"
	}
	return env_or("HEIMDALL_SIGN_IDENTITY", p.sign_identity)
}

env_or :: proc(name, fallback: string) -> string {
	if v, ok := os.lookup_env(name, context.temp_allocator); ok && strings.trim_space(v) != "" {
		return v
	}
	return fallback
}

// Sign `target` with `identity`. Dispatches per host OS.
sign_app :: proc(target, identity, entitlements: string) -> bool {
	when ODIN_OS == .Darwin {
		return sign_macos(target, identity, entitlements)
	} else when ODIN_OS == .Windows {
		return sign_windows(target, identity)
	} else {
		fmt.println("heimdall sign: Linux has no OS-level signing requirement — skipping")
		return true
	}
}

@(private = "file")
sign_macos :: proc(target, identity, entitlements: string) -> bool {
	if identity == "" {
		fmt.eprintln(
`heimdall sign: no signing identity.

Set one of:
  --adhoc                                  (local testing; won't pass Gatekeeper elsewhere)
  HEIMDALL_SIGN_IDENTITY=…                  (env, e.g. in CI)
  [sign] identity = "Developer ID Application: Name (TEAMID)"   (heimdall.toml)

List your identities with:  security find-identity -v -p codesigning`,
		)
		return false
	}

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "codesign", "--force", "--options", "runtime")
	if identity != "-" {
		// A real cert: timestamp (needs network) and optional entitlements.
		append(&cmd, "--timestamp")
		if entitlements != "" {
			append(&cmd, "--entitlements", entitlements)
		}
	}
	append(&cmd, "--sign", identity, target)

	label := "ad-hoc" if identity == "-" else identity
	fmt.printfln("heimdall sign: codesign (%s) -> %s", label, target)
	if !run_inherit(cmd[:]) {
		fmt.eprintln("heimdall sign: codesign failed")
		return false
	}
	if !run_inherit({"codesign", "--verify", "--strict", "--verbose=2", target}) {
		fmt.eprintln("heimdall sign: verification failed")
		return false
	}
	fmt.println("heimdall sign: signed + verified")
	if identity == "-" {
		fmt.println("  note: ad-hoc signature — fine for local runs, but other Macs need a Developer ID + notarization")
	}
	return true
}

// Notarize + staple (macOS). Untestable without an Apple Developer account; the
// flow is the standard notarytool path. Creds come from a stored keychain
// profile (HEIMDALL_NOTARY_PROFILE / [sign].notary_profile) or, failing that,
// HEIMDALL_APPLE_ID + HEIMDALL_TEAM_ID + HEIMDALL_APP_PASSWORD (CI-friendly).
notarize_app :: proc(p: Project, target: string) -> bool {
	when ODIN_OS != .Darwin {
		fmt.println("heimdall sign: notarization is macOS-only — skipping")
		return true
	} else {
		zip := fmt.tprintf("%s.zip", target)
		fmt.printfln("heimdall sign: zipping %s", target)
		if !run_inherit({"ditto", "-c", "-k", "--keepParent", target, zip}) {
			return false
		}

		sub := make([dynamic]string, context.temp_allocator)
		append(&sub, "xcrun", "notarytool", "submit", zip, "--wait")
		if profile := env_or("HEIMDALL_NOTARY_PROFILE", p.notary_profile); profile != "" {
			append(&sub, "--keychain-profile", profile)
		} else {
			aid := env_or("HEIMDALL_APPLE_ID", "")
			tid := env_or("HEIMDALL_TEAM_ID", "")
			pw := env_or("HEIMDALL_APP_PASSWORD", "")
			if aid == "" || tid == "" || pw == "" {
				fmt.eprintln(
					"heimdall sign: notarization needs a keychain profile (HEIMDALL_NOTARY_PROFILE / [sign].notary_profile)\n  or HEIMDALL_APPLE_ID + HEIMDALL_TEAM_ID + HEIMDALL_APP_PASSWORD",
				)
				return false
			}
			append(&sub, "--apple-id", aid, "--team-id", tid, "--password", pw)
		}

		fmt.println("heimdall sign: submitting to Apple notary service (this can take a few minutes)...")
		if !run_inherit(sub[:]) {
			fmt.eprintln("heimdall sign: notarization failed")
			return false
		}
		if !run_inherit({"xcrun", "stapler", "staple", target}) {
			fmt.eprintln("heimdall sign: stapling failed")
			return false
		}
		fmt.println("heimdall sign: notarized + stapled")
		return true
	}
}

// Windows Authenticode (stub). Compiled only on Windows hosts.
when ODIN_OS == .Windows {
	@(private = "file")
	sign_windows :: proc(target, identity: string) -> bool {
		// Intended: signtool sign /fd sha256 /a /n "<identity>"
		//   /tr http://timestamp.digicert.com /td sha256 <target.exe>
		fmt.eprintln("heimdall sign: Windows signing not yet implemented (would invoke signtool)")
		return false
	}
}
