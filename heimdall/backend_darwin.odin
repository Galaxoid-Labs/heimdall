#+build darwin
package heimdall

// Native macOS backend — WKWebView via Objective-C interop. Fills the Backend
// vtable (backend.odin); the bridge / services / events / user code are
// platform-agnostic. This is the macOS backend (WebKit/Cocoa linked below).
//
// objc calls go through `intrinsics.objc_send` (the blessed builtin). It requires
// a receiver typed as an @(objc_class) struct, so every runtime `id` is wrapped
// as ^OC (a minimal NSObject view) via `oc()`; sending to a class object (for
// alloc/sharedApplication/etc.) uses `cls()`. The selector must be a compile-time
// string literal — which all of ours are.

import "base:intrinsics"
import "core:encoding/json"
import "core:strings"
import NS "core:sys/darwin/Foundation"

id :: NS.id

@(objc_class = "NSObject")
OC :: struct {
	using _: intrinsics.objc_object,
}

@(private = "file")
msg :: intrinsics.objc_send

@(private = "file")
oc :: #force_inline proc "contextless" (x: id) -> ^OC {
	return transmute(^OC)x
}

@(private = "file")
cls :: #force_inline proc "contextless" (name: cstring) -> ^OC {
	return transmute(^OC)NS.objc_lookUpClass(name)
}

// Link the frameworks this backend needs. @(require) forces the link even though
// we reference no C symbols from them directly (objc classes are resolved at
// runtime), so without it the linker would dead-strip the frameworks.
@(require) foreign import _webkit "system:WebKit.framework"
@(require) foreign import _cocoa "system:Cocoa.framework"

// libdispatch (in libSystem) for the main-thread hop. dispatch_get_main_queue()
// is a macro for &_dispatch_main_q, so we take the global's address directly.
foreign import dispatch_lib "system:System"
@(default_calling_convention = "c")
foreign dispatch_lib {
	_dispatch_main_q: u64
	dispatch_async_f :: proc(queue: rawptr, ctx: rawptr, work: proc "c" (ctx: rawptr)) ---
}

@(private = "file")
Darwin_Backend :: struct {
	app:     ^App,
	nsapp:   id,
	window:  id,
	webview: id,
	ucc:     id, // WKUserContentController
	handler: id, // the shared NSObject (message handler, window + menu delegate)
	width:   int,
	height:  int,
	running: bool,
}

// Single app per process (Heimdall is one window today) — the C message-handler
// trampoline reaches the app through this.
@(private = "file")
g_dwn: ^Darwin_Backend

@(private = "file")
CGPoint :: struct {x, y: f64}
@(private = "file")
CGSize :: struct {width, height: f64}
@(private = "file")
CGRect :: struct {origin: CGPoint, size: CGSize}

NS_UTF8 :: NS.UInteger(4) // NSUTF8StringEncoding

darwin_backend_create :: proc(app: ^App, debug: bool) -> bool {
	dwn := new(Darwin_Backend, app.registry_allocator)
	dwn.app = app
	dwn.width = 800
	dwn.height = 600
	g_dwn = dwn

	// NSApplication.sharedApplication; regular (Dock) activation policy.
	dwn.nsapp = msg(id, cls("NSApplication"), "sharedApplication")
	msg(nil, oc(dwn.nsapp), "setActivationPolicy:", NS.Integer(0))

	// App_Config.icon (PNG bytes) → the Dock icon at runtime, so a dev run looks
	// finished without bundling. (Bundled apps get their icon from the .app.)
	if len(app.cfg.icon) > 0 {
		data := msg(id, cls("NSData"), "dataWithBytes:length:", raw_data(app.cfg.icon), NS.UInteger(len(app.cfg.icon)))
		img := msg(id, oc(msg(id, cls("NSImage"), "alloc")), "initWithData:", data)
		if img != nil {
			msg(nil, oc(dwn.nsapp), "setApplicationIconImage:", img)
		}
	}

	// NSWindow.
	rect := CGRect{{0, 0}, {f64(dwn.width), f64(dwn.height)}}
	style := NS.UInteger(1 | 2 | 4 | 8) // Titled|Closable|Miniaturizable|Resizable
	win := msg(id, cls("NSWindow"), "alloc")
	win = msg(id, oc(win), "initWithContentRect:styleMask:backing:defer:", rect, style, NS.UInteger(2), bool(false))
	dwn.window = win

	// WKWebViewConfiguration + user content controller (the message channel).
	cfg := msg(id, oc(msg(id, cls("WKWebViewConfiguration"), "alloc")), "init")
	dwn.ucc = msg(id, oc(cfg), "userContentController")

	// Register a class implementing WKScriptMessageHandler, install under
	// "__heimdall_invoke".
	handler := make_message_handler()
	msg(nil, oc(dwn.ucc), "addScriptMessageHandler:name:", handler, nsstring("__heimdall_invoke"))

	// The same object is the app:// URL-scheme handler: serve embedded assets
	// directly (no loopback server). Must be set on the config BEFORE the webview
	// is created.
	msg(nil, oc(cfg), "setURLSchemeHandler:forURLScheme:", handler, nsstring("app"))

	// Inject the native shim at document start.
	shim, _ := strings.replace_all(SHIM_JS_NATIVE, "__CHANNEL__", DARWIN_CHANNEL, context.temp_allocator)
	us := msg(id, cls("WKUserScript"), "alloc")
	us = msg(id, oc(us), "initWithSource:injectionTime:forMainFrameOnly:", nsstring(shim), NS.UInteger(0), bool(false))
	msg(nil, oc(dwn.ucc), "addUserScript:", us)

	// WKWebView as the window content view.
	wk := msg(id, cls("WKWebView"), "alloc")
	wk = msg(id, oc(wk), "initWithFrame:configuration:", rect, cfg)
	dwn.webview = wk
	msg(nil, oc(win), "setContentView:", wk)
	msg(nil, oc(win), "center")

	// Same object is the window delegate, so closing the window stops the loop
	// (and runs should_quit). See window_should_close.
	msg(nil, oc(win), "setDelegate:", handler)
	dwn.handler = handler

	// Menu bar (App + Edit + the user's menus + Window).
	darwin_install_menu(dwn)

	// Initial window state from App_Config.
	if app.cfg.min_width > 0 || app.cfg.min_height > 0 {
		msg(nil, oc(win), "setContentMinSize:", CGSize{f64(app.cfg.min_width), f64(app.cfg.min_height)})
	}
	if app.cfg.always_on_top {
		msg(nil, oc(win), "setLevel:", NS.Integer(3)) // NSFloatingWindowLevel
	}
	if app.cfg.center {
		msg(nil, oc(win), "center")
	}
	if app.cfg.maximized {
		msg(nil, oc(win), "zoom:", id(nil))
	}
	if app.cfg.fullscreen {
		msg(nil, oc(win), "toggleFullScreen:", id(nil))
	}

	app.backend = Backend {
		impl      = dwn,
		set_title = dwn_set_title,
		set_size  = dwn_set_size,
		window_op = dwn_window_op,
		navigate  = dwn_navigate,
		set_html  = dwn_set_html,
		init_js   = dwn_init_js,
		eval      = dwn_eval,
		reply     = dwn_reply,
		dispatch  = dwn_dispatch,
		run       = dwn_run,
		terminate = dwn_terminate,
		destroy   = dwn_destroy,
	}
	app.backend.serves_assets = true // we serve embedded assets over app://
	return true
}

// ---- helpers --------------------------------------------------------------

@(private = "file")
self_dwn :: proc(app: ^App) -> ^Darwin_Backend {
	return cast(^Darwin_Backend)app.backend.impl
}

// Copying NSString from an Odin string (initWithBytes copies, so `s` is transient).
@(private = "file")
nsstring :: proc(s: string) -> id {
	obj := msg(id, cls("NSString"), "alloc")
	return msg(id, oc(obj), "initWithBytes:length:encoding:", raw_data(s), NS.UInteger(len(s)), NS_UTF8)
}

// Build a class implementing -userContentController:didReceiveScriptMessage: and
// instantiate it.
@(private = "file")
make_message_handler :: proc() -> id {
	cls_h := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "HeimdallMsgHandler", 0)
	if cls_h != nil {
		NS.class_addMethod(
			cls_h,
			intrinsics.objc_find_selector("userContentController:didReceiveScriptMessage:"),
			auto_cast on_script_message,
			"v@:@@",
		)
		// Also acts as the NSWindowDelegate: -windowShouldClose: ends the run
		// loop (honoring should_quit) so closing the window quits the app.
		NS.class_addMethod(
			cls_h,
			intrinsics.objc_find_selector("windowShouldClose:"),
			auto_cast window_should_close,
			"B@:@",
		)
		// Also the app:// URL-scheme handler (WKURLSchemeHandler protocol).
		NS.class_addMethod(
			cls_h,
			intrinsics.objc_find_selector("webView:startURLSchemeTask:"),
			auto_cast start_url_scheme_task,
			"v@:@@",
		)
		NS.class_addMethod(
			cls_h,
			intrinsics.objc_find_selector("webView:stopURLSchemeTask:"),
			auto_cast stop_url_scheme_task,
			"v@:@@",
		)
		// Custom menu actions: Quit (clean shutdown) and custom items (emit event).
		NS.class_addMethod(
			cls_h,
			intrinsics.objc_find_selector("heimdallQuit:"),
			auto_cast heimdall_quit,
			"v@:@",
		)
		NS.class_addMethod(
			cls_h,
			intrinsics.objc_find_selector("heimdallMenu:"),
			auto_cast heimdall_menu_action,
			"v@:@",
		)
		if proto := NS.objc_getProtocol("WKScriptMessageHandler"); proto != nil {
			NS.class_addProtocol(cls_h, proto)
		}
		if proto := NS.objc_getProtocol("WKURLSchemeHandler"); proto != nil {
			NS.class_addProtocol(cls_h, proto)
		}
		NS.objc_registerClassPair(cls_h)
	} else {
		cls_h = NS.objc_lookUpClass("HeimdallMsgHandler") // already registered
	}
	inst := msg(id, oc(transmute(id)cls_h), "alloc")
	return msg(id, oc(inst), "init")
}

// The objc message-handler method: extract the JSON body string and dispatch.
@(private = "file")
on_script_message :: proc "c" (self: id, cmd: NS.SEL, ucc: id, message: id) {
	dwn := g_dwn
	if dwn == nil {return}
	context = dwn.app.ctx
	body := msg(id, oc(message), "body") // NSString (we postMessage a string)
	utf8 := msg(cstring, oc(body), "UTF8String")
	darwin_handle_message(dwn.app, string(utf8))
}

// WKURLSchemeHandler -webView:startURLSchemeTask:. Serves the embedded asset map
// for app:// requests directly (no loopback server). Synchronous: we have the
// bytes in memory, so we respond fully and finish in one go.
@(private = "file")
start_url_scheme_task :: proc "c" (self: id, cmd: NS.SEL, webview: id, task: id) {
	dwn := g_dwn
	if dwn == nil {return}
	context = dwn.app.ctx

	req := msg(id, oc(task), "request")
	url := msg(id, oc(req), "URL")
	path_ns := msg(id, oc(url), "path") // "/index.html"
	path_c := msg(cstring, oc(path_ns), "UTF8String")

	path := strings.trim_prefix(string(path_c), "/")
	if path == "" {
		path = "index.html"
	}
	asset, ok := dwn.app.cfg.assets[path]
	if !ok && !darwin_has_ext(path) {
		// SPA fallback: extension-less route -> index.html.
		asset, ok = dwn.app.cfg.assets["index.html"]
	}
	if !ok {
		err := msg(id, cls("NSError"), "errorWithDomain:code:userInfo:", nsstring("heimdall"), NS.Integer(404), id(nil))
		msg(nil, oc(task), "didFailWithError:", err)
		return
	}

	mime := asset.mime if asset.mime != "" else guess_mime(path)

	// NSHTTPURLResponse 200 with a Content-Type header. (A bare NSURLResponse is
	// not enough for WebKit to execute a main-frame document.)
	headers := msg(id, cls("NSDictionary"), "dictionaryWithObject:forKey:", nsstring(mime), nsstring("Content-Type"))
	resp := msg(id, cls("NSHTTPURLResponse"), "alloc")
	resp = msg(
		id, oc(resp), "initWithURL:statusCode:HTTPVersion:headerFields:",
		url, NS.Integer(200), nsstring("HTTP/1.1"), headers,
	)
	data := msg(id, cls("NSData"), "dataWithBytes:length:", raw_data(asset.data), NS.UInteger(len(asset.data)))
	msg(nil, oc(task), "didReceiveResponse:", resp)
	msg(nil, oc(task), "didReceiveData:", data)
	msg(nil, oc(task), "didFinish")
}

// -webView:stopURLSchemeTask: — nothing to cancel; we serve synchronously.
@(private = "file")
stop_url_scheme_task :: proc "c" (self: id, cmd: NS.SEL, webview: id, task: id) {}

@(private = "file")
darwin_has_ext :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	dot := strings.last_index_byte(path, '.')
	return dot > slash
}

// NSWindowDelegate -windowShouldClose:. Honors should_quit (return false to
// veto), otherwise ends the run loop so the app exits — the native window-close
// hook for should_quit.
@(private = "file")
window_should_close :: proc "c" (self: id, cmd: NS.SEL, sender: id) -> bool {
	dwn := g_dwn
	if dwn == nil {return true}
	context = dwn.app.ctx
	if dwn.app.cfg.should_quit != nil && !dwn.app.cfg.should_quit(dwn.app) {
		return false // vetoed
	}
	dwn.running = false
	return true
}

// ---- menu bar -------------------------------------------------------------

@(private = "file")
sel :: proc(name: cstring) -> NS.SEL {return NS.sel_registerName(name)}

@(private = "file")
cat :: proc(a, b: string) -> string {return strings.concatenate({a, b}, context.temp_allocator)}

@(private = "file")
MOD_SHIFT :: NS.UInteger(1 << 17)
@(private = "file")
MOD_CONTROL :: NS.UInteger(1 << 18)
@(private = "file")
MOD_OPTION :: NS.UInteger(1 << 19)
@(private = "file")
MOD_COMMAND :: NS.UInteger(1 << 20)

// Quit action — clean shutdown via the run loop (honors should_quit), the same
// path as closing the window.
@(private = "file")
heimdall_quit :: proc "c" (self: id, cmd: NS.SEL, sender: id) {
	dwn := g_dwn
	if dwn == nil {return}
	context = dwn.app.ctx
	if dwn.app.cfg.should_quit != nil && !dwn.app.cfg.should_quit(dwn.app) {
		return
	}
	dwn.running = false
}

// Custom menu item action — emit "menu" { id } to JS. The id is stored as the
// item's representedObject.
@(private = "file")
heimdall_menu_action :: proc "c" (self: id, cmd: NS.SEL, sender: id) {
	dwn := g_dwn
	if dwn == nil {return}
	context = dwn.app.ctx
	rep := msg(id, oc(sender), "representedObject")
	if rep == nil {return}
	utf8 := msg(cstring, oc(rep), "UTF8String")
	_ = emit(dwn.app, "menu", Menu_Event{id = string(utf8)})
}

@(private = "file")
new_menu :: proc(title: string) -> id {
	m := msg(id, cls("NSMenu"), "alloc")
	return msg(id, oc(m), "initWithTitle:", nsstring(title))
}

@(private = "file")
add_submenu :: proc(parent: id, title: string) -> id {
	item := msg(id, oc(msg(id, cls("NSMenuItem"), "alloc")), "init")
	msg(nil, oc(item), "setTitle:", nsstring(title))
	msg(nil, oc(parent), "addItem:", item)
	sub := new_menu(title)
	msg(nil, oc(item), "setSubmenu:", sub)
	return sub
}

@(private = "file")
add_separator :: proc(menu: id) {
	msg(nil, oc(menu), "addItem:", msg(id, cls("NSMenuItem"), "separatorItem"))
}

@(private = "file")
add_action :: proc(menu: id, title: string, action: cstring, key: string, mask: NS.UInteger = 0) -> id {
	item := msg(id, oc(menu), "addItemWithTitle:action:keyEquivalent:", nsstring(title), sel(action), nsstring(key))
	if mask != 0 {
		msg(nil, oc(item), "setKeyEquivalentModifierMask:", mask)
	}
	return item
}

// Build and install the menu bar: App + Edit + the user's menus + Window.
darwin_install_menu :: proc(dwn: ^Darwin_Backend) {
	name := dwn.app.cfg.title
	if name == "" {name = "App"}

	main := msg(id, oc(msg(id, cls("NSMenu"), "alloc")), "init")

	// Application menu (first item; macOS shows the app name here).
	app_menu := add_submenu(main, name)
	add_action(app_menu, cat("About ", name), "orderFrontStandardAboutPanel:", "")
	add_separator(app_menu)
	add_action(app_menu, cat("Hide ", name), "hide:", "h")
	add_action(app_menu, "Hide Others", "hideOtherApplications:", "h", MOD_COMMAND | MOD_OPTION)
	add_action(app_menu, "Show All", "unhideAllApplications:", "")
	add_separator(app_menu)
	quit := add_action(app_menu, cat("Quit ", name), "heimdallQuit:", "q")
	msg(nil, oc(quit), "setTarget:", dwn.handler)

	// Edit menu — gives the web view working undo/cut/copy/paste/select-all.
	edit := add_submenu(main, "Edit")
	add_action(edit, "Undo", "undo:", "z")
	add_action(edit, "Redo", "redo:", "z", MOD_COMMAND | MOD_SHIFT)
	add_separator(edit)
	add_action(edit, "Cut", "cut:", "x")
	add_action(edit, "Copy", "copy:", "c")
	add_action(edit, "Paste", "paste:", "v")
	add_action(edit, "Select All", "selectAll:", "a")

	// The user's menus (File, View, Help, …).
	for top in dwn.app.cfg.menu {
		sub := add_submenu(main, top.label)
		build_menu_items(dwn, sub, top.submenu)
	}

	// Window menu.
	win := add_submenu(main, "Window")
	add_action(win, "Minimize", "performMiniaturize:", "m")
	add_action(win, "Zoom", "performZoom:", "")
	msg(nil, oc(dwn.nsapp), "setWindowsMenu:", win)

	msg(nil, oc(dwn.nsapp), "setMainMenu:", main)
}

@(private = "file")
build_menu_items :: proc(dwn: ^Darwin_Backend, menu: id, items: []Menu_Item) {
	for it in items {
		if it.separator {
			add_separator(menu)
			continue
		}
		if it.role != .None {
			add_role_item(dwn, menu, it)
			continue
		}
		// Custom item → emits "menu" { id }.
		key, mask := parse_accelerator(it.accelerator)
		item := add_action(menu, it.label, "heimdallMenu:", key, mask)
		msg(nil, oc(item), "setTarget:", dwn.handler)
		msg(nil, oc(item), "setRepresentedObject:", nsstring(it.id))
		if it.disabled {
			msg(nil, oc(item), "setEnabled:", bool(false))
		}
		if len(it.submenu) > 0 {
			sub := new_menu(it.label)
			build_menu_items(dwn, sub, it.submenu)
			msg(nil, oc(item), "setSubmenu:", sub)
		}
	}
}

@(private = "file")
add_role_item :: proc(dwn: ^Darwin_Backend, menu: id, it: Menu_Item) {
	action: cstring
	key := ""
	mask := NS.UInteger(0)
	target := id(nil)
	label := it.label

	#partial switch it.role {
	case .About:
		action = "orderFrontStandardAboutPanel:";if label == "" {label = "About"}
	case .Hide:
		action = "hide:";key = "h";if label == "" {label = "Hide"}
	case .Hide_Others:
		action = "hideOtherApplications:";key = "h";mask = MOD_COMMAND | MOD_OPTION;if label == "" {label = "Hide Others"}
	case .Show_All:
		action = "unhideAllApplications:";if label == "" {label = "Show All"}
	case .Quit:
		action = "heimdallQuit:";key = "q";target = dwn.handler;if label == "" {label = "Quit"}
	case .Undo:
		action = "undo:";key = "z";if label == "" {label = "Undo"}
	case .Redo:
		action = "redo:";key = "z";mask = MOD_COMMAND | MOD_SHIFT;if label == "" {label = "Redo"}
	case .Cut:
		action = "cut:";key = "x";if label == "" {label = "Cut"}
	case .Copy:
		action = "copy:";key = "c";if label == "" {label = "Copy"}
	case .Paste:
		action = "paste:";key = "v";if label == "" {label = "Paste"}
	case .Select_All:
		action = "selectAll:";key = "a";if label == "" {label = "Select All"}
	case .Minimize:
		action = "performMiniaturize:";key = "m";if label == "" {label = "Minimize"}
	case .Zoom:
		action = "performZoom:";if label == "" {label = "Zoom"}
	case:
		return
	}
	if it.accelerator != "" {
		key, mask = parse_accelerator(it.accelerator)
	}
	item := add_action(menu, label, action, key, mask)
	if target != nil {
		msg(nil, oc(item), "setTarget:", target)
	}
}

// "Cmd+Shift+S" → (key, modifier-mask). Last segment is the key; the rest are
// modifiers (Cmd/Command/CmdOrCtrl, Shift, Alt/Option, Ctrl/Control).
@(private = "file")
parse_accelerator :: proc(accel: string) -> (key: string, mask: NS.UInteger) {
	if accel == "" {return "", 0}
	parts := strings.split(accel, "+", context.temp_allocator)
	for p, i in parts {
		t := strings.to_lower(strings.trim_space(p), context.temp_allocator)
		if i == len(parts) - 1 {
			key = t
		} else {
			switch t {
			case "cmd", "command", "cmdorctrl", "super", "meta":
				mask |= MOD_COMMAND
			case "shift":
				mask |= MOD_SHIFT
			case "alt", "option", "opt":
				mask |= MOD_OPTION
			case "ctrl", "control":
				mask |= MOD_CONTROL
			}
		}
	}
	return
}

// Parse the native wire message {i, n, a}, rebuild the `[name, args]` envelope
// (shared with backend_on_request), carry the JS id through Request_Id.
@(private = "file")
darwin_handle_message :: proc(app: ^App, body: string) {
	context = app.ctx
	val, jerr := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	if jerr != .None {return}
	obj, ok := val.(json.Object)
	if !ok {return}

	n_bytes, _ := json.marshal(obj["n"], allocator = context.temp_allocator)
	a_bytes, _ := json.marshal(obj["a"], allocator = context.temp_allocator)
	i_bytes, _ := json.marshal(obj["i"], allocator = context.temp_allocator)

	req_json := strings.concatenate({"[", string(n_bytes), ",", string(a_bytes), "]"}, context.temp_allocator)
	id_c := strings.clone_to_cstring(string(i_bytes), context.temp_allocator)
	backend_on_request(app, transmute(Request_Id)id_c, req_json)
}

// ---- vtable procs ---------------------------------------------------------

@(private = "file")
dwn_set_title :: proc(app: ^App, title: string) {
	msg(nil, oc(self_dwn(app).window), "setTitle:", nsstring(title))
}

@(private = "file")
dwn_set_size :: proc(app: ^App, width, height: int, fixed: bool) {
	dwn := self_dwn(app)
	dwn.width = width
	dwn.height = height
	msg(nil, oc(dwn.window), "setContentSize:", CGSize{f64(width), f64(height)})
	msg(nil, oc(dwn.window), "center")
}

@(private = "file")
dwn_navigate :: proc(app: ^App, url: string) {
	dwn := self_dwn(app)
	nsurl := msg(id, cls("NSURL"), "URLWithString:", nsstring(url))
	req := msg(id, cls("NSURLRequest"), "requestWithURL:", nsurl)
	msg(nil, oc(dwn.webview), "loadRequest:", req)
}

@(private = "file")
dwn_set_html :: proc(app: ^App, html: string) {
	msg(nil, oc(self_dwn(app).webview), "loadHTMLString:baseURL:", nsstring(html), id(nil))
}

@(private = "file")
dwn_init_js :: proc(app: ^App, js: string) {
	dwn := self_dwn(app)
	us := msg(id, cls("WKUserScript"), "alloc")
	us = msg(id, oc(us), "initWithSource:injectionTime:forMainFrameOnly:", nsstring(js), NS.UInteger(0), bool(false))
	msg(nil, oc(dwn.ucc), "addUserScript:", us)
}

@(private = "file")
dwn_eval :: proc(app: ^App, js: string) {
	msg(nil, oc(self_dwn(app).webview), "evaluateJavaScript:completionHandler:", nsstring(js), id(nil))
}

@(private = "file")
dwn_reply :: proc(app: ^App, id_tok: Request_Id, ok: bool, json_result: string) {
	id_str := string(transmute(cstring)id_tok)
	fn := "window.__HEIMDALL__._resolve(" if ok else "window.__HEIMDALL__._reject("
	js := strings.concatenate({fn, id_str, ",", json_result, ")"}, context.temp_allocator)
	dwn_eval(app, js)
}

@(private = "file")
Dispatch_Box :: struct {
	app:  ^App,
	fn:   proc(app: ^App, user: rawptr),
	user: rawptr,
}

@(private = "file")
dwn_dispatch :: proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr) {
	box := new(Dispatch_Box, app.event_allocator)
	box^ = Dispatch_Box{app = app, fn = fn, user = user}
	dispatch_async_f(&_dispatch_main_q, box, dwn_dispatch_cb)
}

@(private = "file")
dwn_dispatch_cb :: proc "c" (ctx: rawptr) {
	box := cast(^Dispatch_Box)ctx
	context = box.app.ctx
	box.fn(box.app, box.user)
	free(box, box.app.event_allocator)
}

// Unified window control (NSWindow). Mirrors lin_window_op / wvb_window_op.
@(private = "file")
NS_FULLSCREEN_MASK :: NS.UInteger(1 << 14) // NSWindowStyleMaskFullScreen

@(private = "file")
dwn_window_op :: proc(app: ^App, op: Window_Op) {
	dwn := self_dwn(app)
	win := dwn.window
	switch op {
	case .Minimize:
		msg(nil, oc(win), "miniaturize:", id(nil))
	case .Maximize:
		if !bool(msg(bool, oc(win), "isZoomed")) {msg(nil, oc(win), "zoom:", id(nil))}
	case .Unmaximize:
		if bool(msg(bool, oc(win), "isZoomed")) {msg(nil, oc(win), "zoom:", id(nil))}
	case .Fullscreen_On:
		if (msg(NS.UInteger, oc(win), "styleMask") & NS_FULLSCREEN_MASK) == 0 {
			msg(nil, oc(win), "toggleFullScreen:", id(nil))
		}
	case .Fullscreen_Off:
		if (msg(NS.UInteger, oc(win), "styleMask") & NS_FULLSCREEN_MASK) != 0 {
			msg(nil, oc(win), "toggleFullScreen:", id(nil))
		}
	case .Show:
		msg(nil, oc(win), "makeKeyAndOrderFront:", id(nil))
		msg(nil, oc(dwn.nsapp), "activateIgnoringOtherApps:", bool(true))
	case .Hide:
		msg(nil, oc(win), "orderOut:", id(nil))
	case .Focus:
		msg(nil, oc(win), "makeKeyAndOrderFront:", id(nil))
		msg(nil, oc(dwn.nsapp), "activateIgnoringOtherApps:", bool(true))
	case .Center:
		msg(nil, oc(win), "center")
	case .Close:
		dwn.running = false
	}
}

@(private = "file")
dwn_run :: proc(app: ^App) {
	dwn := self_dwn(app)
	if !app.cfg.hidden {
		msg(nil, oc(dwn.window), "makeKeyAndOrderFront:", id(nil))
		msg(nil, oc(dwn.nsapp), "activateIgnoringOtherApps:", bool(true))
	}

	// Hand-rolled event loop so terminate() can return cleanly (vs [NSApp run]).
	mode := nsstring("kCFRunLoopDefaultMode")
	distant := msg(id, cls("NSDate"), "distantFuture")
	dwn.running = true
	for dwn.running {
		ev := msg(
			id,
			oc(dwn.nsapp),
			"nextEventMatchingMask:untilDate:inMode:dequeue:",
			~u64(0), // NSEventMaskAny
			distant,
			mode,
			bool(true),
		)
		if ev != nil {
			msg(nil, oc(dwn.nsapp), "sendEvent:", ev)
		}
	}
}

@(private = "file")
dwn_terminate :: proc(app: ^App) {
	dwn := self_dwn(app)
	dwn.running = false
	// Wake the loop if blocked in nextEventMatchingMask (e.g. terminate from a
	// worker thread): delivering anything to the main queue returns an event.
	dispatch_async_f(&_dispatch_main_q, nil, dwn_wake)
}

@(private = "file")
dwn_wake :: proc "c" (ctx: rawptr) {}

@(private = "file")
dwn_destroy :: proc(app: ^App) {
	dwn := self_dwn(app)
	dwn.running = false
	free(dwn, app.registry_allocator)
}
