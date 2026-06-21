package heimdall

import "core:os"
import "core:strings"

// Deep linking — opening the app via a custom URL scheme (myapp://…).
//
// Two halves:
//   1. REGISTRATION — telling the OS the app owns the scheme. Done at packaging
//      time from `[bundle].schemes` in heimdall.toml: macOS CFBundleURLTypes,
//      Linux .desktop `MimeType=x-scheme-handler/<scheme>`, Windows registry
//      keys in the Inno installer. (See cli/cmd_bundle_*.odin.)
//   2. DELIVERY — getting the URL into the running app. macOS receives it via
//      `application:openURLs:` (cold-start AND already-running, single-instance
//      free). Windows and Linux receive a cold-start URL as a command-line
//      argument (argv). The already-running case is now handled on all three:
//      Linux forwards over an AF_UNIX socket (backend_linux.odin); Windows over a
//      named mutex + WM_COPYDATA (backend_windows.odin). See
//      docs/guide/deep-linking.md.
//
// The app sees a URL two ways (set either or both on App_Config):
//   * on_open_url(app, url) — an Odin hook, called immediately.
//   * an "open-url" event { url } — for the frontend: on("open-url", e => …).
//
// `App_Config.url_schemes` lists the schemes to match in argv at runtime; keep
// it in sync with `[bundle].schemes` (which does the OS registration).
//
// ───────────────────────────────────────────────────────────────────────────
// Single-instance "already-running" forwarding — DONE on all three platforms
// ───────────────────────────────────────────────────────────────────────────
// macOS reuses the live instance for free (LaunchServices). Linux matches it via
// single-instance forwarding in backend_linux.odin (an AF_UNIX socket in
// $XDG_RUNTIME_DIR named after the app id: the first instance listens; a later
// one connects, writes its launch URL, and exits — the primary focuses its
// window and delivers the URL). Windows mirrors the same shape in
// backend_windows.odin (windows_single_instance):
//
//     1. Become the "primary" by creating a named mutex
//        ("Global\\heimdall-<app_id>"); GetLastError == ERROR_ALREADY_EXISTS
//        means a primary is already running.
//     2. Primary: receives forwarded URLs via WM_COPYDATA in its wndproc →
//        UTF-8 → re-activates the window → deliver_open_url.
//     3. Secondary: FindWindowW the primary by its per-app window class,
//        SendMessageW WM_COPYDATA with the launch URL bytes (from os.args, via
//        url_matches_scheme), grant it foreground rights, then os.exit(0)
//        without opening a window.
//
// All three only engage when App_Config.url_schemes is set. Cold-start (every
// platform) + the macOS already-running path are covered by
// examples/_probe_deeplink; the Linux and Windows already-running paths were each
// verified end-to-end with a primary + forwarded secondaries.

// Payload of the "open-url" event. Auto-declared in `create` so it's typed in
// generated bindings.
Open_Url :: struct {
	url: string,
}

// Central entry for an incoming deep-link URL. Calls the on_open_url hook now,
// and delivers an "open-url" event to the frontend — queued until the frontend
// signals ready (win.__ready), so a cold-start URL isn't lost before the page's
// on("open-url") handler exists.
deliver_open_url :: proc(app: ^App, url: string) {
	if url == "" {
		return
	}
	if app.cfg.on_open_url != nil {
		app.cfg.on_open_url(app, url)
	}
	if app.frontend_ready {
		_ = emit(app, "open-url", Open_Url{url = url})
	} else {
		append(&app.pending_urls, strings.clone(url, app.event_allocator))
	}
}

// Flush queued cold-start URLs once the frontend is ready (called from the
// reserved win.__ready command, which the shim sends on DOMContentLoaded).
@(private)
flush_pending_urls :: proc(app: ^App) {
	for url in app.pending_urls {
		_ = emit(app, "open-url", Open_Url{url = url})
		delete(url, app.event_allocator)
	}
	clear(&app.pending_urls)
}

// Cold-start: if the app was launched with a `<scheme>://…` argument, deliver it.
// Windows/Linux pass deep links via argv; macOS uses application:openURLs: for
// both cold-start and already-running, so it skips argv here.
@(private)
deliver_launch_url :: proc(app: ^App) {
	when ODIN_OS != .Darwin {
		if len(os.args) < 2 {
			return
		}
		for arg in os.args[1:] {
			if url_matches_scheme(app, arg) {
				deliver_open_url(app, arg)
				break
			}
		}
	}
}

@(private)
url_matches_scheme :: proc(app: ^App, arg: string) -> bool {
	for s in app.cfg.url_schemes {
		prefix := strings.concatenate({s, "://"}, context.temp_allocator)
		if strings.has_prefix(arg, prefix) {
			return true
		}
	}
	return false
}
