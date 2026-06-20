# Menus

Define a native menu bar by setting `menu` on `App_Config` — you describe your own
menus (File, View, Help, …) and heimdall renders them per platform.

> Native menus are a **native-backend** feature (the default on macOS and Linux).
> Platform behavior differs where it should:
>
> - **macOS** — a global menu bar. The standard **Application**, **Edit**, and
>   **Window** menus are added automatically (Edit is what makes ⌘C/⌘V work in
>   WKWebView); your menus are appended.
> - **Linux** — an in-window GTK menu bar showing **only your menus** (no menu bar
>   appears if you set none — WebKitGTK already provides copy/paste + a context
>   menu). Role items map to GTK/WebKit where one exists; macOS-only roles
>   (About, Hide, Show All, Zoom) are skipped.
>
> If you opt into the webview/webview backend with `--webview`, it has no menu
> support and ignores `menu`. Use `"CmdOrCtrl+…"` accelerators for cross-platform
> shortcuts.

## Define menus

```odin
app, _ := hd.create(hd.App_Config{
    title = "My App",
    menu = {
        {label = "File", submenu = {
            {label = "New",   id = "file.new",  accelerator = "Cmd+N"},
            {label = "Open…", id = "file.open", accelerator = "Cmd+O"},
            {separator = true},
            {label = "Close", role = .Quit},
        }},
        {label = "View", submenu = {
            {label = "Reload", id = "view.reload", accelerator = "Cmd+R"},
        }},
    },
})
```

Each top-level entry becomes a menu; its `submenu` holds the items.

## Two kinds of item

**Custom items** — give an item an `id`. Clicking it (or pressing its accelerator)
emits a `"menu"` event with that id. Handle it in your frontend:

```js
import { on } from "./heimdall.gen.js"   // or: const { on } = window.heimdall
on("menu", e => {
    if (e.id === "file.open") openFileDialog()
    if (e.id === "file.new")  newDocument()
})
```

**Role items** — set `role` for standard behavior (and the right keyboard
shortcut) without writing any handler:

| Group | Roles |
| --- | --- |
| App | `.About` `.Hide` `.Hide_Others` `.Show_All` `.Quit` |
| Edit | `.Undo` `.Redo` `.Cut` `.Copy` `.Paste` `.Select_All` |
| Window | `.Minimize` `.Zoom` |

(The App/Edit/Window menus already include these — use roles when you want a
standard action inside your *own* menu, e.g. `.Quit` at the bottom of File.)

## Item fields

```odin
Menu_Item :: struct {
    label:       string,
    id:          string,      // custom action id (emitted as "menu" { id })
    role:        Menu_Role,   // predefined behavior (takes precedence over id)
    accelerator: string,      // e.g. "Cmd+S", "Cmd+Shift+P"
    separator:   bool,        // draw a divider
    disabled:    bool,        // greyed out
    submenu:     []Menu_Item, // nested items
}
```

## Accelerators

A `+`-separated string: modifiers then the key, e.g. `"Cmd+S"`,
`"Cmd+Shift+P"`, `"Cmd+Alt+I"`. Recognized modifiers: `Cmd` / `Command` /
`CmdOrCtrl`, `Shift`, `Alt` / `Option`, `Ctrl` / `Control`.
