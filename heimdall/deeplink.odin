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
//      argument (argv). The already-running case on Windows/Linux needs
//      single-instance forwarding (mutex+WM_COPYDATA / D-Bus) — NOT yet
//      implemented; see docs/guide/deep-linking.md.
//
// The app sees a URL two ways (set either or both on App_Config):
//   * on_open_url(app, url) — an Odin hook, called immediately.
//   * an "open-url" event { url } — for the frontend: on("open-url", e => …).
//
// `App_Config.url_schemes` lists the schemes to match in argv at runtime; keep
// it in sync with `[bundle].schemes` (which does the OS registration).
//
// ───────────────────────────────────────────────────────────────────────────
// TODO — Windows/Linux "already-running" single-instance forwarding (NEXT)
// ───────────────────────────────────────────────────────────────────────────
// Today, on Win/Linux, opening myapp://… while the app is ALREADY running starts
// a SECOND instance (which gets the URL via argv and delivers it correctly, but
// you now have two windows). macOS is unaffected (LaunchServices reuses the live
// instance). To make Win/Linux behave like macOS, add single-instance + forward:
//
//   Shared shape (do this in app.odin `create`, before the backend opens a window):
//     1. Try to become the "primary" instance (platform lock below).
//     2. If we ARE primary: keep a listener open for incoming URLs; when one
//        arrives from a secondary, call `deliver_open_url(app, url)` (already the
//        single entry point — it fires the hook + queues/emits the event).
//     3. If we are NOT primary: a primary already exists — send our launch URL
//        (from os.args, via url_matches_scheme) to it over the channel, then
//        EXIT immediately (os.exit(0)) without opening a window.
//
//   Windows (backend_windows.odin):
//     * CreateMutexW("Global\\heimdall-<bundle_id>") → GetLastError ==
//       ERROR_ALREADY_EXISTS means a primary is running.
//     * Forward: FindWindow for the primary's hidden message window (or a known
//       class/title) and SendMessageW WM_COPYDATA with the URL bytes.
//     * Receive: handle WM_COPYDATA in the existing wndproc → UTF-8 → dispatch to
//       the UI thread → deliver_open_url. (Already-have a wndproc + dispatch.)
//
//   Linux (backend_linux.odin):
//     * Simplest: GApplication with G_APPLICATION_HANDLES_OPEN +
//       g_application_register/g_application_get_is_remote; the "open" signal on
//       the primary delivers the URLs, g_application_run on a remote forwards over
//       D-Bus and returns. BUT our loop is hand-rolled (not g_application_run), so
//       either (a) adopt GApplication's registration just for uniqueness/open
//       forwarding while keeping our g_main_context_iteration loop, or (b) a
//       lockfile in $XDG_RUNTIME_DIR + a unix-domain socket: primary listens,
//       secondary connects, writes the URL, exits.
//
//   Verify with a real bundled/installed build (scheme must be OS-registered):
//   launch the app, then `start myapp://x` (Win) / `xdg-open myapp://x` (Linux)
//   → the SAME window receives "open-url", no second instance. (Cold-start +
//   the macOS path are already covered by examples/_probe_deeplink.)

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
