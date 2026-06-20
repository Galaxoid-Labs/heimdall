# Window

heimdall gives you one **unified, platform-agnostic** window API — the same calls
on macOS, Linux, and (later) Windows. Each backend implements the platform bits
under the hood; your code never branches on OS.

## Initial state (`App_Config`)

Set the window's starting state when you create the app:

```odin
app, _ := hd.create(hd.App_Config{
    title  = "My App",
    width  = 1000, height = 700,
    resizable = true,

    min_width = 600, min_height = 400,  // minimum size (0 = none)
    maximized     = false,              // start maximized
    fullscreen    = false,              // start fullscreen
    always_on_top = false,              // keep above other windows
    center        = true,               // center on screen at startup
    hidden        = false,              // start hidden; show later with window_show
})
```

> **Platform note:** `center` and `always_on_top` are best-effort. Under **Wayland**
> a client can't position or raise its own window, so they're no-ops there (they
> work on macOS). Everything else is honored on all native backends.

## Control it at runtime — from Odin

```odin
hd.window_minimize(app)
hd.window_maximize(app)
hd.window_unmaximize(app)
hd.window_set_fullscreen(app, true)
hd.window_show(app)
hd.window_hide(app)
hd.window_focus(app)
hd.window_center(app)
hd.window_set_title(app, "New Title")
hd.window_set_size(app, 1200, 800)
hd.window_close(app)                 // honors should_quit, then ends the loop
```

## Control it from the frontend — the `win` service

A built-in service named **`win`** is always registered, so JS can drive the
window through the bridge:

```js
// untyped:
await window.heimdall.invoke("win.minimize")
await window.heimdall.invoke("win.fullscreen", { on: true })
await window.heimdall.invoke("win.set_title", { title: "New Title" })

// typed (generated client):
import { win } from "./heimdall.gen.js"
await win.minimize()
await win.maximize()
await win.fullscreen({ on: true })
await win.set_title({ title: "New Title" })
await win.close()
```

Commands: `minimize`, `maximize`, `unmaximize`, `show`, `hide`, `focus`, `center`,
`close`, `fullscreen({on})`, `set_title({title})`, `set_size({width,height})`.

> `win` is a **reserved** service name — don't register your own service called
> `win`.

## Lifecycle

`window_close` (and the window's close button) run your `should_quit` hook first —
return `false` to veto the close. After the window actually closes, `on_shutdown`
runs. See [Configuration](./configuration.md) for the lifecycle hooks.
