package heimdall

import "base:runtime"

// App is the opaque handle the user threads through the API. Holds the native
// shell (via the Backend vtable), the command registry, the event bus, and a
// stored Odin `context` for use inside FFI callbacks.
App :: struct {
	backend:            Backend,
	backend_ready:      bool, // false in schema-dump mode (no native shell)
	cfg:                App_Config,
	registry:           map[string]Thunk,
	registry_allocator: runtime.Allocator, // owns the registry keys; freed on destroy
	ctx:                runtime.Context,    // restored at the top of every FFI callback

	// Event bus.
	event_allocator:    runtime.Allocator,

	// Production asset server (Phase 3); nil in dev or when no assets are set.
	server:             ^Asset_Server,
}

// App_Config is the user-facing configuration passed to `create`. Lifecycle
// hooks are all optional (nil == skip).
App_Config :: struct {
	title:         string,
	width, height: int,
	resizable:     bool,
	dev_url:       string,             // dev builds point the webview here (bundler HMR)
	icon:          []u8,               // embedded PNG — macOS Dock icon + Windows title-bar/taskbar icon at runtime; Linux/GTK4 has no per-window raw-bytes icon, so installed apps get it from the bundle's .desktop instead
	assets:        map[string]Asset,   // prod builds serve these (from `embed`)
	menu:          []Menu_Item,        // custom menu bar (native backend; see menu.odin)

	// Initial window state (all optional; applied by the native backend at create).
	// Some are best-effort per platform — e.g. `center`/`always_on_top` are no-ops
	// under Wayland, where a client can't position or raise its own window.
	min_width:     int,                // minimum window size (0 = none)
	min_height:    int,
	maximized:     bool,               // start maximized
	fullscreen:    bool,               // start fullscreen
	always_on_top: bool,               // keep above other windows (best-effort)
	center:        bool,               // center on screen at startup (best-effort)
	hidden:        bool,               // start hidden; show later with window_show

	// Lifecycle hooks. All optional (nil == skip).
	on_startup:    proc(app: ^App) -> Error, // after shell init, before frontend loads; Error aborts run
	on_shutdown:   proc(app: ^App),          // after the event loop exits; clean up here
	should_quit:   proc(app: ^App) -> bool,  // return false to veto a close — enforced via each
	                                         // backend's native window-close hook
}

// Create the app and its native shell. Registers the JS shim and the single
// invoke entry point, but does NOT navigate — call `navigate`/`set_html` (or let
// `run` pick dev vs. embedded) before `run`.
@(require_results)
create :: proc(cfg: App_Config) -> (^App, Error) {
	app := new(App)
	app.cfg = cfg
	// Capture the caller's context (not default_context) so FFI callbacks use the
	// same allocator/logger the user set up — including a tracking allocator, so
	// leaks across the bridge boundary are visible in a debug build.
	app.ctx = context
	app.registry_allocator = context.allocator
	app.event_allocator = context.allocator
	app.registry = make(map[string]Thunk, 16, context.allocator)

	// Built-in `win` window-control service. Registered before the schema-dump
	// early return so it also lands in generated bindings (the typed `win`
	// namespace); its handlers only touch the backend at runtime, never in schema
	// mode.
	register_window_service(app)

	// Schema-dump mode: no native shell (no display needed). The registry still
	// gets populated by service()/command(); `run` dumps it.
	when HEIMDALL_SCHEMA {
		return app, nil
	}

	debug := false
	when HEIMDALL_DEV {
		debug = true
	}

	// Select the native backend for the host OS: WKWebView (macOS), WebKitGTK
	// (Linux), or WebView2 (Windows). All implement the same Backend vtable, so the
	// bridge / services / events / user code are identical across platforms.
	ok: bool
	when ODIN_OS == .Darwin {
		ok = darwin_backend_create(app, debug)
	} else when ODIN_OS == .Linux {
		ok = linux_backend_create(app, debug)
	} else when ODIN_OS == .Windows {
		ok = windows_backend_create(app, debug)
	} else {
		#panic("heimdall: no native backend for this platform")
	}
	if !ok {
		free(app)
		return nil, Webview_Error.Create_Failed
	}
	app.backend_ready = true

	app.backend.set_title(app, cfg.title)
	w := cfg.width if cfg.width > 0 else 800
	h := cfg.height if cfg.height > 0 else 600
	app.backend.set_size(app, w, h, !cfg.resizable)

	return app, nil
}

// Point the webview at a URL (e.g. the dev server, or the loopback asset server).
navigate :: proc(app: ^App, url: string) {
	if !app.backend_ready {return} // no shell in schema-dump mode
	app.backend.navigate(app, url)
}

// Load an inline HTML string directly. Handy for self-contained examples/tests
// that don't need a bundler or a server.
set_html :: proc(app: ^App, html: string) {
	if !app.backend_ready {return} // no shell in schema-dump mode
	app.backend.set_html(app, html)
}

// Run the app: pick the frontend source (dev server vs. embedded assets), then
// enter the platform event loop. Blocks until the window closes.
//
// If neither dev_url (dev) nor assets (prod) is configured, no navigation
// happens here — handy for examples that called `set_html`/`navigate` directly.
run :: proc(app: ^App) {
	// Schema-dump mode: emit the command schema as JSON and exit, no window.
	when HEIMDALL_SCHEMA {
		dump_schema(app)
		return
	}

	// Lifecycle: on_startup runs after shell init, before the frontend loads.
	// A non-nil Error aborts the run (the window never shows its content).
	if app.cfg.on_startup != nil {
		if err := app.cfg.on_startup(app); err != nil {
			return
		}
	}

	when HEIMDALL_DEV {
		if app.cfg.dev_url != "" {
			navigate(app, app.cfg.dev_url)
		}
	} else {
		if len(app.cfg.assets) > 0 {
			if app.backend.serves_assets {
				// Native backend serves the asset map over its own app:// scheme;
				// no loopback server needed. Navigate to the ROOT (not
				// /index.html) so SPA client routers (SvelteKit, etc.) see
				// location.pathname == "/" and match their index route instead of
				// rendering a 404. The scheme handler maps "/" -> index.html.
				navigate(app, "app://localhost/")
			} else {
				srv, url, serr := start_asset_server(app, &app.cfg.assets)
				if serr == nil {
					app.server = srv
					navigate(app, url)
				}
			}
		}
	}

	app.backend.run(app) // blocks until the window closes

	// Lifecycle: on_shutdown runs once the loop exits. (should_quit — vetoing a
	// close — needs a native window-close hook the bootstrap backend can't give
	// us; enforced once the native backends land. See Phase 7.)
	if app.cfg.on_shutdown != nil {
		app.cfg.on_shutdown(app)
	}
}

// Tear down the app and free its resources.
destroy :: proc(app: ^App) {
	if app == nil {
		return
	}
	stop_asset_server(app.server)
	if app.backend_ready {
		app.backend.destroy(app)
	}
	for key in app.registry {
		delete(key, app.registry_allocator)
	}
	delete(app.registry)
	free(app)
}
