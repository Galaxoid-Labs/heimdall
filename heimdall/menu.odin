package heimdall

// Native menu bar.
//
// Build a `[]Menu_Item` and set it on `App_Config.menu`. Each top-level entry
// becomes a menu in the bar; its `submenu` holds the entries. Two kinds of item:
//
//   - a `role` item uses the platform's standard behavior (Quit, Copy, …);
//   - a custom item (give it an `id`) emits a `"menu"` event `{ id }` when
//     clicked — subscribe in JS with `on("menu", e => …)`.
//
// The standard Application, Edit, and Window menus are added automatically, so
// you only describe your own menus (File, View, Help, …). A `separator` item
// draws a divider.
//
// Native menus are a native-backend feature (macOS today). The webview/webview
// bootstrap backend has no menu support and ignores this.
//
//   app, _ := hd.create(hd.App_Config{
//       title = "My App",
//       menu = {
//           { label = "File", submenu = {
//               { label = "New",  id = "file.new",  accelerator = "Cmd+N" },
//               { label = "Open", id = "file.open", accelerator = "Cmd+O" },
//               { separator = true },
//               { label = "Close", role = .Quit },
//           }},
//       },
//   })
//
//   // JS:  on("menu", e => { if (e.id === "file.open") openDialog() })

Menu_Item :: struct {
	label:       string,
	id:          string,    // custom action id — clicking emits "menu" { id }
	role:        Menu_Role, // predefined native behavior (takes precedence over id)
	accelerator: string,    // e.g. "Cmd+S", "Cmd+Shift+P" (CmdOrCtrl also accepted)
	separator:   bool,      // draw a divider (other fields ignored)
	disabled:    bool,      // default is enabled
	submenu:     []Menu_Item,
}

Menu_Role :: enum {
	None = 0,
	// Application menu
	About,
	Hide,
	Hide_Others,
	Show_All,
	Quit,
	// Edit menu
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
	// Window menu
	Minimize,
	Zoom,
}

// Payload of the "menu" event emitted when a custom item is clicked.
Menu_Event :: struct {
	id: string,
}
