# Window

heimdall gives you one **unified, platform-agnostic** window API — the same calls
on macOS, Linux, and Windows. Each backend implements the platform bits under the
hood; your code never branches on OS.

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
> work on macOS and Windows). Everything else is honored on all native backends.

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

## Title bar (macOS)

Choose the macOS title-bar style with `App_Config.titlebar`:

```odin
app, _ := hd.create(hd.App_Config{
    title    = "My App",
    titlebar = .Transparent,   // .Default | .Transparent
})
```

- **`.Default`** — the standard macOS title bar.
- **`.Transparent`** — a transparent title bar with a **full-size content view**, so
  your web content fills the whole window and tints through the top. The title text
  and traffic lights stay — the chrome is never fully removed.

With `.Transparent`, the traffic lights **float over your content**, so leave clear
space in the **top-left** for them (≈ the first 78 px wide, 28 px tall).

**Dragging just works.** Because the title bar is kept (just transparent), its strip
at the top of the window stays **natively draggable** — you don't implement window
dragging yourself. (That's deliberate: there's no fully-chrome-less style, so you
never end up needing a drag hook that doesn't exist — WKWebView doesn't honor
`-webkit-app-region: drag`.)

> **macOS only.** `titlebar` is ignored on Linux and Windows today (they keep their
> native title bars). macOS gets the transparent look almost for free; on
> Windows/Linux the native window controls are part of the frame, so a transparent
> title bar there is a larger feature — not yet wired up. The default (`.Default`)
> is unchanged on every platform.

## Lifecycle

`window_close` (and the window's close button) run your `should_quit` hook first —
return `false` to veto the close. After the window actually closes, `on_shutdown`
runs. See [Configuration](./configuration.md) for the lifecycle hooks.
