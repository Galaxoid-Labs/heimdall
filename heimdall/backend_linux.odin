#+build linux
package heimdall

// Native Linux backend — GTK 4 + libadwaita + WebKitGTK (webkitgtk-6.0), via
// `foreign import` C / GObject. Fills the same Backend vtable as the macOS and
// Windows backends, so the bridge / services / events / user code are
// platform-agnostic. This is the Linux backend.
//
// Why GTK4 + libadwaita: the window uses an AdwHeaderBar title bar, and `adw_init`
// makes the whole UI follow the system light/dark preference automatically
// (AdwStyleManager) — so the title bar matches the user's theme with no extra
// work. (GTK3 did not follow the freedesktop `color-scheme` without a manual
// portal query; GTK4/libadwaita does.)
//
// Maps to the vtable as:
//   * adw_init + GtkWindow + AdwHeaderBar               — window + themed title bar
//   * WebKitWebView (webkitgtk-6.0)                      — the web view
//   * WebKitUserContentManager
//       - register_script_message_handler("__heimdall_invoke", NULL)
//         + "script-message-received::__heimdall_invoke" — JS -> Odin (JSCValue)
//       - add_script(SHIM_JS_NATIVE, document-start)      — the shim
//   * webkit_web_view_evaluate_javascript                — eval / reply / events
//   * g_idle_add                                          — dispatch (main-thread hop)
//   * webkit_web_context_register_uri_scheme("app")       — serve embedded ASSETS
//   * GtkWindow "close-request"                           — should_quit veto
//   * g_main_context_iteration loop                       — run/terminate
//   * GMenu + GtkPopoverMenuBar + GSimpleActionGroup      — the menu bar
//
// Link deps: `pkg-config --libs gtk4 libadwaita-1 webkitgtk-6.0`. `heimdall
// doctor` checks `pkg-config --exists webkitgtk-6.0`. See docs/platform_notes.md.

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Substituted into SHIM_JS_NATIVE's __CHANNEL__ (WebKitGTK uses the same
// messageHandlers API as Cocoa's WKScriptMessageHandler).
LINUX_CHANNEL :: "window.webkit.messageHandlers.__heimdall_invoke.postMessage(payload)"

foreign import gtk {
	"system:gtk-4",
	"system:adwaita-1",
	"system:webkitgtk-6.0",
	"system:javascriptcoregtk-6.0",
	"system:gobject-2.0",
	"system:glib-2.0",
	"system:gio-2.0",
}

foreign import libc "system:c"

@(private = "file")
GTK_ORIENTATION_VERTICAL :: c.int(1)
// WebKitUserContentInjectedFrames.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME
@(private = "file")
INJECT_TOP_FRAME :: c.int(1)
// WebKitUserScriptInjectionTime.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START
@(private = "file")
INJECT_AT_DOCUMENT_START :: c.int(0)
// GSourceFunc return: G_SOURCE_REMOVE (FALSE) runs the idle callback once.
@(private = "file")
G_SOURCE_REMOVE :: c.int(0)
// G_SOURCE_CONTINUE (TRUE) keeps a GSource (e.g. the single-instance fd watch).
@(private = "file")
G_SOURCE_CONTINUE :: c.int(1)
// GIOCondition G_IO_IN — data available to read on a watched fd.
@(private = "file")
G_IO_IN :: c.int(1)

// Callbacks crossing the FFI boundary — all `proc "c"`.
@(private = "file")
Script_Message_CB :: #type proc "c" (manager: rawptr, value: rawptr, user: rawptr)
@(private = "file")
Source_Func :: #type proc "c" (user: rawptr) -> c.int
@(private = "file")
Uri_Scheme_CB :: #type proc "c" (request: rawptr, user: rawptr)
// GUnixFDSourceFunc: (fd, GIOCondition, user) -> keep-source bool. Used to service
// the single-instance listening socket on the GLib main loop.
@(private = "file")
Unix_FD_CB :: #type proc "c" (fd: c.int, condition: c.int, user: rawptr) -> c.int

@(default_calling_convention = "c")
foreign gtk {
	// libadwaita
	adw_init :: proc() ---
	adw_header_bar_new :: proc() -> rawptr ---

	// GTK 4 — window
	gtk_window_new :: proc() -> rawptr ---
	gtk_window_set_title :: proc(window: rawptr, title: cstring) ---
	gtk_window_set_default_size :: proc(window: rawptr, width, height: c.int) ---
	gtk_window_set_resizable :: proc(window: rawptr, resizable: c.int) ---
	gtk_window_set_titlebar :: proc(window: rawptr, titlebar: rawptr) ---
	gtk_window_set_child :: proc(window: rawptr, child: rawptr) ---
	gtk_window_present :: proc(window: rawptr) ---
	gtk_window_minimize :: proc(window: rawptr) ---
	gtk_window_maximize :: proc(window: rawptr) ---
	gtk_window_unmaximize :: proc(window: rawptr) ---
	gtk_window_fullscreen :: proc(window: rawptr) ---
	gtk_window_unfullscreen :: proc(window: rawptr) ---
	gtk_widget_set_visible :: proc(widget: rawptr, visible: c.int) ---
	gtk_widget_set_size_request :: proc(widget: rawptr, width, height: c.int) ---

	// GTK 4 — widgets / layout
	gtk_widget_grab_focus :: proc(widget: rawptr) -> c.int ---
	gtk_widget_set_vexpand :: proc(widget: rawptr, expand: c.int) ---
	gtk_widget_set_hexpand :: proc(widget: rawptr, expand: c.int) ---
	gtk_box_new :: proc(orientation: c.int, spacing: c.int) -> rawptr ---
	gtk_box_append :: proc(box: rawptr, child: rawptr) ---
	gtk_popover_menu_bar_new_from_model :: proc(model: rawptr) -> rawptr ---

	// GTK 4 — actions + shortcuts (menu plumbing)
	gtk_widget_insert_action_group :: proc(widget: rawptr, name: cstring, group: rawptr) ---
	gtk_widget_add_controller :: proc(widget: rawptr, controller: rawptr) ---
	gtk_shortcut_controller_new :: proc() -> rawptr ---
	gtk_shortcut_controller_add_shortcut :: proc(controller: rawptr, shortcut: rawptr) ---
	gtk_shortcut_new :: proc(trigger: rawptr, action: rawptr) -> rawptr ---
	gtk_shortcut_trigger_parse_string :: proc(s: cstring) -> rawptr ---
	gtk_named_action_new :: proc(name: cstring) -> rawptr ---

	// GLib main loop + utilities
	g_main_context_iteration :: proc(ctx: rawptr, may_block: c.int) -> c.int ---
	g_idle_add :: proc(function: Source_Func, data: rawptr) -> c.uint ---
	// glib-unix: watch a raw fd on the default main context (single-instance socket).
	g_unix_fd_add :: proc(fd: c.int, condition: c.int, function: Unix_FD_CB, user_data: rawptr) -> c.uint ---
	g_free :: proc(mem: rawptr) ---
	g_quark_from_static_string :: proc(s: cstring) -> u32 ---
	g_error_new_literal :: proc(domain: u32, code: c.int, message: cstring) -> rawptr ---
	g_error_free :: proc(error: rawptr) ---

	// GObject
	g_object_unref :: proc(object: rawptr) ---
	g_signal_connect_data :: proc(instance: rawptr, detailed_signal: cstring, handler: rawptr, data: rawptr, destroy_data: rawptr, connect_flags: c.int) -> c.ulong ---

	// GIO — streams, menus, actions, variants
	g_memory_input_stream_new_from_data :: proc(data: rawptr, len: int, destroy: rawptr) -> rawptr ---
	g_menu_new :: proc() -> rawptr ---
	g_menu_append :: proc(menu: rawptr, label: cstring, detailed_action: cstring) ---
	g_menu_append_item :: proc(menu: rawptr, item: rawptr) ---
	g_menu_append_section :: proc(menu: rawptr, label: cstring, section: rawptr) ---
	g_menu_append_submenu :: proc(menu: rawptr, label: cstring, submenu: rawptr) ---
	g_menu_item_new :: proc(label: cstring, detailed_action: cstring) -> rawptr ---
	g_menu_item_set_submenu :: proc(item: rawptr, submenu: rawptr) ---
	g_menu_item_set_attribute_value :: proc(item: rawptr, attribute: cstring, value: rawptr) ---
	g_variant_new_string :: proc(s: cstring) -> rawptr ---
	g_simple_action_new :: proc(name: cstring, parameter_type: rawptr) -> rawptr ---
	g_simple_action_group_new :: proc() -> rawptr ---
	g_action_map_add_action :: proc(action_map: rawptr, action: rawptr) ---

	// WebKitGTK (webkitgtk-6.0)
	webkit_web_view_new :: proc() -> rawptr ---
	webkit_web_view_get_context :: proc(webview: rawptr) -> rawptr ---
	webkit_web_context_get_security_manager :: proc(ctx: rawptr) -> rawptr ---
	webkit_web_context_register_uri_scheme :: proc(ctx: rawptr, scheme: cstring, callback: Uri_Scheme_CB, user_data: rawptr, destroy: rawptr) ---
	webkit_security_manager_register_uri_scheme_as_secure :: proc(manager: rawptr, scheme: cstring) ---
	webkit_security_manager_register_uri_scheme_as_cors_enabled :: proc(manager: rawptr, scheme: cstring) ---
	webkit_web_view_get_user_content_manager :: proc(webview: rawptr) -> rawptr ---
	webkit_web_view_get_settings :: proc(webview: rawptr) -> rawptr ---
	webkit_settings_set_enable_developer_extras :: proc(settings: rawptr, enabled: c.int) ---
	webkit_web_view_load_uri :: proc(webview: rawptr, uri: cstring) ---
	webkit_web_view_load_html :: proc(webview: rawptr, content: cstring, base_uri: cstring) ---
	webkit_web_view_evaluate_javascript :: proc(webview: rawptr, script: cstring, length: int, world_name: cstring, source_uri: cstring, cancellable: rawptr, callback: rawptr, user_data: rawptr) ---
	webkit_user_content_manager_register_script_message_handler :: proc(manager: rawptr, name: cstring, world_name: cstring) -> c.int ---
	webkit_user_content_manager_add_script :: proc(manager: rawptr, script: rawptr) ---
	webkit_user_script_new :: proc(source: cstring, injected_frames: c.int, injection_time: c.int, allow_list: rawptr, block_list: rawptr) -> rawptr ---
	webkit_user_script_unref :: proc(script: rawptr) ---
	webkit_uri_scheme_request_get_path :: proc(request: rawptr) -> cstring ---
	webkit_uri_scheme_request_finish :: proc(request: rawptr, stream: rawptr, stream_length: i64, content_type: cstring) ---
	webkit_uri_scheme_request_finish_error :: proc(request: rawptr, error: rawptr) ---

	// JavaScriptCore (value -> string; result must be g_free'd)
	jsc_value_to_string :: proc(value: rawptr) -> cstring ---
}

@(default_calling_convention = "c")
foreign libc {
	setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
	getenv :: proc(name: cstring) -> cstring ---
}

@(private = "file")
Linux_Backend :: struct {
	app:       ^App,
	window:    rawptr, // GtkWindow*
	webview:   rawptr, // WebKitWebView*
	ucc:       rawptr, // WebKitUserContentManager*
	actions:   rawptr, // GSimpleActionGroup* (menu actions)
	shortcuts: rawptr, // GtkShortcutController* (menu accelerators)
	running:   bool,

	// Single-instance deep-link forwarding (only when url_schemes is set):
	// the primary listens on this AF_UNIX socket; secondaries connect, write
	// their launch URL, and exit. -1 when not the primary / not enabled.
	lock_fd:   posix.FD,
	lock_path: string, // owned by registry_allocator; unlinked at destroy
}

// Single app per process — the C trampolines reach the app through this.
@(private = "file")
g_lin: ^Linux_Backend

linux_backend_create :: proc(app: ^App, debug: bool) -> bool {
	// WebKitGTK's DMABUF renderer crashes/blanks on some VM/NVIDIA setups; disable
	// it unless the user already chose (keeps first-run + headless/CI reliable).
	if getenv("WEBKIT_DISABLE_DMABUF_RENDERER") == nil {
		setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 1)
	}

	// Initialize GTK4 + libadwaita. libadwaita's style manager follows the system
	// light/dark preference from here on (so the AdwHeaderBar title bar matches).
	adw_init()

	lin := new(Linux_Backend, app.registry_allocator)
	lin.app = app
	lin.lock_fd = -1
	g_lin = lin

	// Single-instance deep-link forwarding (parity with macOS LaunchServices): if a
	// primary instance is already running, hand it our launch URL and exit before
	// opening a second window. Only engaged when the app declares url_schemes.
	if !lin_single_instance(lin) {
		os.exit(0)
	}

	lin.window = gtk_window_new()
	gtk_window_set_default_size(lin.window, 800, 600)

	// libadwaita title bar (themed, follows light/dark automatically).
	gtk_window_set_titlebar(lin.window, adw_header_bar_new())

	// app:// scheme: serve embedded assets directly off the web view's context (no
	// loopback server), registered before any navigation and marked secure +
	// CORS-enabled so the page gets a real origin for fetch().
	lin.webview = webkit_web_view_new()
	gtk_widget_set_vexpand(lin.webview, 1)
	gtk_widget_set_hexpand(lin.webview, 1)
	ctx := webkit_web_view_get_context(lin.webview)
	webkit_web_context_register_uri_scheme(ctx, "app", lin_uri_scheme_cb, lin, nil)
	sec := webkit_web_context_get_security_manager(ctx)
	webkit_security_manager_register_uri_scheme_as_secure(sec, "app")
	webkit_security_manager_register_uri_scheme_as_cors_enabled(sec, "app")

	lin.ucc = webkit_web_view_get_user_content_manager(lin.webview)

	// JS -> Odin: register the "__heimdall_invoke" handler (3-arg in GTK4, world =
	// NULL) and connect its per-name signal.
	webkit_user_content_manager_register_script_message_handler(lin.ucc, "__heimdall_invoke", nil)
	g_signal_connect_data(
		lin.ucc,
		"script-message-received::__heimdall_invoke",
		auto_cast lin_script_message_cb,
		lin,
		nil,
		0,
	)

	// Inject the native shim at document start (same id-correlated shim as macOS).
	shim, _ := strings.replace_all(SHIM_JS_NATIVE, "__CHANNEL__", LINUX_CHANNEL, context.temp_allocator)
	shim_c := strings.clone_to_cstring(shim, context.temp_allocator)
	us := webkit_user_script_new(shim_c, INJECT_TOP_FRAME, INJECT_AT_DOCUMENT_START, nil, nil)
	webkit_user_content_manager_add_script(lin.ucc, us)
	webkit_user_script_unref(us)

	if debug {
		webkit_settings_set_enable_developer_extras(webkit_web_view_get_settings(lin.webview), 1)
	}

	// Layout. With a menu, stack [menubar | webview] in a vertical box; otherwise
	// the web view fills the window. (Unlike macOS — global menu bar + standard
	// App/Edit/Window menus — GTK menus live in-window, and WebKitGTK already
	// provides copy/paste + a context menu, so we render only the user's menus.)
	menubar := lin_install_menu(lin)
	if menubar != nil {
		vbox := gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
		gtk_box_append(vbox, menubar)
		gtk_box_append(vbox, lin.webview)
		gtk_window_set_child(lin.window, vbox)
	} else {
		gtk_window_set_child(lin.window, lin.webview)
	}

	// Closing the window honors should_quit (close-request veto), then ends the
	// loop — the native window-close hook for should_quit.
	g_signal_connect_data(lin.window, "close-request", auto_cast lin_close_request_cb, lin, nil, 0)

	// Initial window state from App_Config (best-effort; Wayland forbids some).
	if app.cfg.min_width > 0 || app.cfg.min_height > 0 {
		gtk_widget_set_size_request(lin.window, c.int(app.cfg.min_width), c.int(app.cfg.min_height))
	}
	if app.cfg.maximized {gtk_window_maximize(lin.window)}
	if app.cfg.fullscreen {gtk_window_fullscreen(lin.window)}
	// always_on_top / center: no portable GTK4/Wayland client API — skipped.

	app.backend = Backend {
		impl      = lin,
		set_title = lin_set_title,
		set_size  = lin_set_size,
		window_op = lin_window_op,
		navigate  = lin_navigate,
		set_html  = lin_set_html,
		init_js   = lin_init_js,
		eval      = lin_eval,
		reply     = lin_reply,
		dispatch  = lin_dispatch,
		run       = lin_run,
		terminate = lin_terminate,
		destroy   = lin_destroy,
	}
	app.backend.serves_assets = true // we serve embedded assets over app://
	return true
}

// ---- helpers --------------------------------------------------------------

@(private = "file")
self_lin :: proc(app: ^App) -> ^Linux_Backend {
	return cast(^Linux_Backend)app.backend.impl
}

@(private = "file")
linux_has_ext :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	dot := strings.last_index_byte(path, '.')
	return dot > slash
}

// ---- single-instance deep-link forwarding ---------------------------------
//
// Windows/Linux deliver a deep link as a launch argument, so opening myapp://…
// while the app already runs would otherwise spawn a SECOND window. macOS gets
// single-instance free from LaunchServices; here we reproduce it with an AF_UNIX
// socket in $XDG_RUNTIME_DIR named after the app id:
//
//   * The first instance binds + listens, and services connections on the GLib
//     main loop (g_unix_fd_add) — it is the primary.
//   * A later instance connects, writes its launch URL (if any), and exits; the
//     primary reads it, focuses its window, and delivers the URL like any other
//     open-url. A re-launch with no URL just focuses the existing window.
//
// Only engaged when the app declares url_schemes (deep links are the whole point
// of single-instance here). Returns false when this process is a secondary that
// has forwarded and should exit.

// Build "$XDG_RUNTIME_DIR/heimdall-<app_id>.sock" (falls back to /tmp), cloned
// into registry_allocator so it outlives temp frames (unlinked at destroy).
@(private = "file")
lin_lock_path :: proc(app: ^App) -> string {
	id := app_identifier(app, context.temp_allocator)
	base := "/tmp"
	if dir := getenv("XDG_RUNTIME_DIR"); dir != nil {
		if s := string(dir); s != "" {base = s}
	}
	path := strings.concatenate({base, "/heimdall-", id, ".sock"}, context.temp_allocator)
	return strings.clone(path, app.registry_allocator)
}

// Fill an AF_UNIX sockaddr for `path`. Returns the address and the length to pass
// to bind/connect (the full struct — the kernel reads sun_path as nul-terminated).
@(private = "file")
lin_sock_addr :: proc(path: string) -> (posix.sockaddr_un, posix.socklen_t) {
	addr: posix.sockaddr_un // zero-initialized → sun_path is nul-padded
	addr.sun_family = .UNIX
	n := min(len(path), len(addr.sun_path) - 1)
	for i in 0 ..< n {
		addr.sun_path[i] = c.char(path[i])
	}
	return addr, posix.socklen_t(size_of(posix.sockaddr_un))
}

// This process's launch deep-link URL (first argv entry matching a scheme), or "".
@(private = "file")
lin_launch_url :: proc(app: ^App) -> string {
	if len(os.args) < 2 {return ""}
	for arg in os.args[1:] {
		if url_matches_scheme(app, arg) {return arg}
	}
	return ""
}

@(private = "file")
lin_single_instance :: proc(lin: ^Linux_Backend) -> (primary: bool) {
	app := lin.app
	if len(app.cfg.url_schemes) == 0 {
		return true // no deep-link schemes → single-instance not needed
	}
	lin.lock_path = lin_lock_path(app)
	addr, addr_len := lin_sock_addr(lin.lock_path)

	// 1) Probe for a live primary by trying to connect.
	if cfd := posix.socket(.UNIX, .STREAM); cfd >= 0 {
		if posix.connect(cfd, cast(^posix.sockaddr)&addr, addr_len) == .OK {
			// A primary is alive — forward our launch URL (if any) and become a
			// no-op secondary. The primary focuses its window on receipt.
			if url := lin_launch_url(app); url != "" {
				buf := transmute([]byte)url
				posix.write(cfd, raw_data(buf), c.size_t(len(buf)))
			}
			posix.close(cfd)
			return false
		}
		posix.close(cfd)
	}

	// 2) No live primary. Clear any stale socket file, then bind + listen.
	path_c := strings.clone_to_cstring(lin.lock_path, context.temp_allocator)
	posix.unlink(path_c)
	lfd := posix.socket(.UNIX, .STREAM)
	if lfd < 0 {return true} // can't single-instance; just run normally
	if posix.bind(lfd, cast(^posix.sockaddr)&addr, addr_len) != .OK {
		posix.close(lfd)
		return true
	}
	if posix.listen(lfd, 4) != .OK {
		posix.close(lfd)
		posix.unlink(path_c)
		return true
	}
	lin.lock_fd = lfd
	g_unix_fd_add(c.int(lfd), G_IO_IN, lin_accept_cb, lin) // serviced by the run loop
	return true
}

// A secondary connected. Accept, read its forwarded URL, focus our window, and
// deliver the URL through the normal open-url path. Keeps the watch alive.
@(private = "file")
lin_accept_cb :: proc "c" (fd: c.int, condition: c.int, user: rawptr) -> c.int {
	lin := g_lin
	if lin == nil {return G_SOURCE_REMOVE}
	context = lin.app.ctx
	defer free_all(context.temp_allocator)

	cfd := posix.accept(posix.FD(fd), nil, nil)
	if cfd < 0 {return G_SOURCE_CONTINUE}
	buf: [4096]byte
	total := 0
	for total < len(buf) {
		n := posix.read(cfd, raw_data(buf[total:]), c.size_t(len(buf) - total))
		if n <= 0 {break}
		total += int(n)
	}
	posix.close(cfd)

	// Bring the existing window forward (macOS-like re-activation), then deliver.
	gtk_window_present(lin.window)
	gtk_widget_grab_focus(lin.webview)
	if total > 0 {
		deliver_open_url(lin.app, string(buf[:total]))
	}
	return G_SOURCE_CONTINUE
}

// ---- C trampolines --------------------------------------------------------

// JS -> Odin. In webkitgtk-6.0 the signal hands us the JSCValue directly;
// stringify it (the body is the JSON string the shim posted) and dispatch.
@(private = "file")
lin_script_message_cb :: proc "c" (manager: rawptr, value: rawptr, user: rawptr) {
	lin := g_lin
	if lin == nil {return}
	context = lin.app.ctx
	cs := jsc_value_to_string(value) // newly-allocated; must g_free
	if cs != nil {
		linux_handle_message(lin.app, string(cs))
		g_free(rawptr(cs))
	}
}

// Parse the native wire message {i, n, a}, rebuild the `[name, args]` envelope
// (shared with backend_on_request), carry the JS id through Request_Id. Mirrors
// darwin_handle_message exactly.
@(private = "file")
linux_handle_message :: proc(app: ^App, body: string) {
	context = app.ctx
	id_json, req_json, ok := parse_native_message(body)
	if !ok {return}
	id_c := strings.clone_to_cstring(id_json, context.temp_allocator)
	backend_on_request(app, transmute(Request_Id)id_c, req_json)
}

// app:// scheme handler: look up the path in the embedded asset map and respond
// with a memory input stream + MIME, or a 404 GError. Synchronous — the bytes are
// embedded (#load) and outlive the stream, so no destroy notify is needed.
@(private = "file")
lin_uri_scheme_cb :: proc "c" (request: rawptr, user: rawptr) {
	lin := g_lin
	if lin == nil {return}
	context = lin.app.ctx
	defer free_all(context.temp_allocator)

	path_c := webkit_uri_scheme_request_get_path(request)
	path := strings.trim_prefix(string(path_c), "/")
	if path == "" {
		path = "index.html"
	}

	asset, ok := lin.app.cfg.assets[path]
	if !ok && !linux_has_ext(path) {
		asset, ok = lin.app.cfg.assets["index.html"] // SPA fallback
	}
	if !ok {
		gerr := g_error_new_literal(g_quark_from_static_string("heimdall"), 404, "not found")
		webkit_uri_scheme_request_finish_error(request, gerr)
		g_error_free(gerr)
		return
	}

	mime := asset.mime if asset.mime != "" else guess_mime(path)
	mime_c := strings.clone_to_cstring(mime, context.temp_allocator)
	stream := g_memory_input_stream_new_from_data(raw_data(asset.data), len(asset.data), nil)
	webkit_uri_scheme_request_finish(request, stream, i64(len(asset.data)), mime_c)
	g_object_unref(stream)
}

// GtkWindow "close-request": return TRUE (1) to veto the close (should_quit said
// no), FALSE (0) to let it close — which ends the run loop.
@(private = "file")
lin_close_request_cb :: proc "c" (window: rawptr, user: rawptr) -> c.int {
	lin := g_lin
	if lin == nil {return 0}
	context = lin.app.ctx
	if lin.app.cfg.should_quit != nil && !lin.app.cfg.should_quit(lin.app) {
		return 1 // vetoed
	}
	lin.running = false
	return 0
}

// UI-thread dispatch. We box {app, fn, user} and unbox it in the idle callback.
// g_idle_add is thread-safe, so this is the main-thread hop for emit()/terminate().
@(private = "file")
Dispatch_Box :: struct {
	app:  ^App,
	fn:   proc(app: ^App, user: rawptr),
	user: rawptr,
}

@(private = "file")
lin_dispatch :: proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr) {
	box := new(Dispatch_Box, app.event_allocator)
	box^ = Dispatch_Box{app = app, fn = fn, user = user}
	g_idle_add(lin_dispatch_cb, box)
}

@(private = "file")
lin_dispatch_cb :: proc "c" (user: rawptr) -> c.int {
	box := cast(^Dispatch_Box)user
	context = box.app.ctx
	box.fn(box.app, box.user)
	free(box, box.app.event_allocator)
	return G_SOURCE_REMOVE
}

// ---- menu bar -------------------------------------------------------------
//
// GTK4 removed GtkMenuBar/GtkMenuItem; the modern equivalent is a GMenu model
// rendered by a GtkPopoverMenuBar, with actions in a GSimpleActionGroup and
// accelerators on a GtkShortcutController. Custom items emit a "menu" { id }
// event; role items map to GTK/WebKit where one exists. macOS-only roles
// (About/Hide/Show All/Zoom) have no GTK equivalent and are skipped.

@(private = "file")
lin_cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// Build the menu bar from App_Config.menu. Returns the GtkPopoverMenuBar widget,
// or nil when no menus are configured.
@(private = "file")
lin_install_menu :: proc(lin: ^Linux_Backend) -> rawptr {
	if len(lin.app.cfg.menu) == 0 {
		return nil
	}
	lin.actions = g_simple_action_group_new()
	lin.shortcuts = gtk_shortcut_controller_new()
	gtk_widget_add_controller(lin.window, lin.shortcuts)

	root := g_menu_new()
	for top in lin.app.cfg.menu {
		sub := g_menu_new()
		lin_build_menu(lin, sub, top.submenu)
		g_menu_append_submenu(root, lin_cstr(top.label), sub)
		g_object_unref(sub)
	}
	gtk_widget_insert_action_group(lin.window, "hd", lin.actions)
	return gtk_popover_menu_bar_new_from_model(root)
}

// Append `items` into the GMenu `into`. Separators split items into GMenu
// sections (which render with a divider between them).
@(private = "file")
lin_build_menu :: proc(lin: ^Linux_Backend, into: rawptr, items: []Menu_Item) {
	section := g_menu_new()
	n := 0
	for it in items {
		if it.separator {
			if n > 0 {
				g_menu_append_section(into, nil, section)
				g_object_unref(section)
				section = g_menu_new()
				n = 0
			}
			continue
		}
		if len(it.submenu) > 0 && it.role == .None && it.id == "" {
			sub := g_menu_new()
			lin_build_menu(lin, sub, it.submenu)
			item := g_menu_item_new(lin_cstr(it.label), nil)
			g_menu_item_set_submenu(item, sub)
			g_menu_append_item(section, item)
			g_object_unref(item)
			g_object_unref(sub)
			n += 1
			continue
		}
		if it.role != .None {
			lin_add_role_item(lin, section, it)
		} else {
			lin_add_custom_item(lin, section, it)
		}
		n += 1
	}
	if n > 0 {
		g_menu_append_section(into, nil, section)
	}
	g_object_unref(section)
}

// A custom item: register an action that emits "menu" { id }, append it to the
// menu (with accelerator display), and wire the accelerator.
@(private = "file")
lin_add_custom_item :: proc(lin: ^Linux_Backend, section: rawptr, it: Menu_Item) {
	// The id cstring is owned by the registry allocator (lives for the app's life,
	// like the menu) and is the action's user-data — emitted verbatim.
	id_c := strings.clone_to_cstring(it.id, lin.app.registry_allocator)
	act := g_simple_action_new(lin_cstr(it.id), nil)
	g_signal_connect_data(act, "activate", auto_cast lin_menu_activate_cb, rawptr(id_c), nil, 0)
	g_action_map_add_action(lin.actions, act)
	g_object_unref(act)
	lin_menu_leaf(lin, section, it.label, it.id, it.accelerator)
}

@(private = "file")
lin_add_role_item :: proc(lin: ^Linux_Backend, section: rawptr, it: Menu_Item) {
	label := it.label
	name: string // action name
	edit_cmd: cstring = nil
	cb: rawptr = nil
	key := ""

	#partial switch it.role {
	case .Quit:
		if label == "" {label = "Quit"};name = "role.quit";key = "q";cb = auto_cast lin_menu_quit_cb
	case .Undo:
		if label == "" {label = "Undo"};name = "role.undo";key = "z";edit_cmd = "Undo"
	case .Redo:
		if label == "" {label = "Redo"};name = "role.redo";edit_cmd = "Redo"
	case .Cut:
		if label == "" {label = "Cut"};name = "role.cut";key = "x";edit_cmd = "Cut"
	case .Copy:
		if label == "" {label = "Copy"};name = "role.copy";key = "c";edit_cmd = "Copy"
	case .Paste:
		if label == "" {label = "Paste"};name = "role.paste";key = "v";edit_cmd = "Paste"
	case .Select_All:
		if label == "" {label = "Select All"};name = "role.selectall";key = "a";edit_cmd = "SelectAll"
	case .Minimize:
		if label == "" {label = "Minimize"};name = "role.minimize";cb = auto_cast lin_menu_minimize_cb
	case:
		return // macOS-only role with no GTK equivalent — skip.
	}

	act := g_simple_action_new(lin_cstr(name), nil)
	if edit_cmd != nil {
		g_signal_connect_data(act, "activate", auto_cast lin_menu_edit_cb, rawptr(edit_cmd), nil, 0)
	} else if cb != nil {
		g_signal_connect_data(act, "activate", cb, lin, nil, 0)
	}
	g_action_map_add_action(lin.actions, act)
	g_object_unref(act)

	accel := it.accelerator
	if accel == "" && key != "" {
		accel = strings.concatenate({"CmdOrCtrl+", key}, context.temp_allocator)
	}
	lin_menu_leaf(lin, section, label, name, accel)
}

// Append a leaf menu item bound to action "hd.<name>", showing + wiring its
// accelerator (if any).
@(private = "file")
lin_menu_leaf :: proc(lin: ^Linux_Backend, section: rawptr, label, name, accel: string) {
	action := strings.concatenate({"hd.", name}, context.temp_allocator)
	item := g_menu_item_new(lin_cstr(label), lin_cstr(action))
	if gtk_accel := lin_accel_to_gtk(accel); gtk_accel != "" {
		g_menu_item_set_attribute_value(item, "accel", g_variant_new_string(lin_cstr(gtk_accel)))
		if trigger := gtk_shortcut_trigger_parse_string(lin_cstr(gtk_accel)); trigger != nil {
			sc := gtk_shortcut_new(trigger, gtk_named_action_new(lin_cstr(action)))
			gtk_shortcut_controller_add_shortcut(lin.shortcuts, sc)
		}
	}
	g_menu_append_item(section, item)
	g_object_unref(item)
}

// "Cmd+Shift+S" / "CmdOrCtrl+N" → GTK4 accelerator string "<Super><Shift>s".
// Last segment is the key (lowercased); the rest are modifiers. Empty if no key.
@(private = "file")
lin_accel_to_gtk :: proc(accel: string) -> string {
	if accel == "" {return ""}
	parts := strings.split(accel, "+", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	key := ""
	for p, i in parts {
		t := strings.to_lower(strings.trim_space(p), context.temp_allocator)
		if i == len(parts) - 1 {
			key = t
		} else {
			switch t {
			case "cmdorctrl", "ctrl", "control":
				strings.write_string(&b, "<Control>")
			case "cmd", "command", "super", "meta":
				strings.write_string(&b, "<Super>")
			case "shift":
				strings.write_string(&b, "<Shift>")
			case "alt", "option", "opt":
				strings.write_string(&b, "<Alt>")
			}
		}
	}
	if key == "" {return ""}
	strings.write_string(&b, key)
	return strings.to_string(b)
}

// Custom menu item activated → emit "menu" { id }. `user` is the id cstring.
@(private = "file")
lin_menu_activate_cb :: proc "c" (action: rawptr, parameter: rawptr, user: rawptr) {
	lin := g_lin
	if lin == nil {return}
	context = lin.app.ctx
	_ = emit(lin.app, "menu", Menu_Event{id = string(transmute(cstring)user)})
}

// Edit-role item → run the WebKit editing command (`user` is the command name).
@(private = "file")
lin_menu_edit_cb :: proc "c" (action: rawptr, parameter: rawptr, user: rawptr) {
	lin := g_lin
	if lin == nil {return}
	context = lin.app.ctx
	// execute_editing_command lives in webkitgtk-6.0; declared inline to keep the
	// menu plumbing together.
	webkit_web_view_execute_editing_command(lin.webview, transmute(cstring)user)
}

@(default_calling_convention = "c")
foreign gtk {
	webkit_web_view_execute_editing_command :: proc(webview: rawptr, command: cstring) ---
}

// Quit-role item → clean shutdown via the run loop (honors should_quit).
@(private = "file")
lin_menu_quit_cb :: proc "c" (action: rawptr, parameter: rawptr, user: rawptr) {
	lin := g_lin
	if lin == nil {return}
	context = lin.app.ctx
	if lin.app.cfg.should_quit != nil && !lin.app.cfg.should_quit(lin.app) {
		return
	}
	lin.running = false
}

@(private = "file")
lin_menu_minimize_cb :: proc "c" (action: rawptr, parameter: rawptr, user: rawptr) {
	lin := g_lin
	if lin == nil {return}
	gtk_window_minimize(lin.window)
}

// ---- vtable procs ---------------------------------------------------------

@(private = "file")
lin_set_title :: proc(app: ^App, title: string) {
	gtk_window_set_title(self_lin(app).window, strings.clone_to_cstring(title, context.temp_allocator))
}

@(private = "file")
lin_set_size :: proc(app: ^App, width, height: int, fixed: bool) {
	lin := self_lin(app)
	gtk_window_set_resizable(lin.window, 0 if fixed else 1)
	gtk_window_set_default_size(lin.window, c.int(width), c.int(height))
}

// Unified window control. Center/always-on-top have no Wayland client API → no-op.
@(private = "file")
lin_window_op :: proc(app: ^App, op: Window_Op) {
	lin := self_lin(app)
	w := lin.window
	switch op {
	case .Minimize:
		gtk_window_minimize(w)
	case .Maximize:
		gtk_window_maximize(w)
	case .Unmaximize:
		gtk_window_unmaximize(w)
	case .Fullscreen_On:
		gtk_window_fullscreen(w)
	case .Fullscreen_Off:
		gtk_window_unfullscreen(w)
	case .Show:
		gtk_widget_set_visible(w, 1);gtk_window_present(w)
	case .Hide:
		gtk_widget_set_visible(w, 0)
	case .Focus:
		gtk_window_present(w)
	case .Center: // Wayland: a client can't position its own window — no-op.
	case .Close:
		lin.running = false
	}
}

@(private = "file")
lin_navigate :: proc(app: ^App, url: string) {
	webkit_web_view_load_uri(self_lin(app).webview, strings.clone_to_cstring(url, context.temp_allocator))
}

@(private = "file")
lin_set_html :: proc(app: ^App, html: string) {
	webkit_web_view_load_html(self_lin(app).webview, strings.clone_to_cstring(html, context.temp_allocator), nil)
}

@(private = "file")
lin_init_js :: proc(app: ^App, js: string) {
	lin := self_lin(app)
	js_c := strings.clone_to_cstring(js, context.temp_allocator)
	us := webkit_user_script_new(js_c, INJECT_TOP_FRAME, INJECT_AT_DOCUMENT_START, nil, nil)
	webkit_user_content_manager_add_script(lin.ucc, us)
	webkit_user_script_unref(us)
}

@(private = "file")
lin_eval :: proc(app: ^App, js: string) {
	js_c := strings.clone_to_cstring(js, context.temp_allocator)
	// length -1 = nul-terminated; no world, source uri, cancellable, or callback.
	webkit_web_view_evaluate_javascript(self_lin(app).webview, js_c, -1, nil, nil, nil, nil, nil)
}

@(private = "file")
lin_reply :: proc(app: ^App, id_tok: Request_Id, ok: bool, json_result: string) {
	id_str := string(transmute(cstring)id_tok)
	fn := "window.heimdall._resolve(" if ok else "window.heimdall._reject("
	js := strings.concatenate({fn, id_str, ",", json_result, ")"}, context.temp_allocator)
	lin_eval(app, js)
}

@(private = "file")
lin_run :: proc(app: ^App) {
	lin := self_lin(app)
	if !app.cfg.hidden {
		gtk_window_present(lin.window)
		gtk_widget_grab_focus(lin.webview)
	}

	// Hand-rolled loop (rather than g_application_run) so terminate() can flip a
	// flag and return cleanly. g_main_context_iteration(nil, TRUE) blocks until an
	// event, processes it, and returns; the next iteration re-checks `running`.
	lin.running = true
	for lin.running {
		g_main_context_iteration(nil, 1)
	}
}

@(private = "file")
lin_terminate :: proc(app: ^App) {
	lin_dispatch(app, lin_stop, nil) // flip the flag on the UI thread (wakes the loop)
}

@(private = "file")
lin_stop :: proc(app: ^App, user: rawptr) {
	self_lin(app).running = false
}

@(private = "file")
lin_destroy :: proc(app: ^App) {
	lin := self_lin(app)
	lin.running = false
	// Release the single-instance lock: close the listening socket and remove its
	// file so the next launch can become primary.
	if lin.lock_fd >= 0 {
		posix.close(lin.lock_fd)
		if lin.lock_path != "" {
			posix.unlink(strings.clone_to_cstring(lin.lock_path, context.temp_allocator))
		}
	}
	free(lin, app.registry_allocator)
}
