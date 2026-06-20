# Events (`emit` / `on`)

`invoke` is request/response. For the **push** direction — progress bars,
background work, live updates — Odin emits events and JS subscribes. Events are
fire-and-forget (no return value) and safe to emit from **any thread**.

## Emit from Odin

```odin
Progress :: struct { read, total: int }

hd.emit(app, "file.progress", Progress{read = 512, total = 1000})
```

The payload is any JSON-marshalable Odin value.

## Subscribe in JS

```js
const { on } = window.heimdall          // or: import { on } from "./heimdall.gen.js"

const off = on("file.progress", p => {
    updateBar(p.read / p.total)
})

// later, to stop listening:
off()
```

(`window.__HEIMDALL__` still works as an alias.) The generated typed client also
re-exports `on`, so you can import everything from one place.

## From a worker thread

`emit` is thread-safe — it marshals immediately and hops onto the UI thread for
you. So a command can kick off background work that streams events:

```odin
worker :: proc(app: ^hd.App) {
    for i in 0 ..< 100 {
        // ... do a chunk of work ...
        hd.emit(app, "job.progress", Progress{read = i + 1, total = 100})
    }
    hd.emit(app, "job.done", Done{})
}

start :: proc(s: ^Jobs, args: Start_Args) -> (Start_Result, hd.Error) {
    thread.create_and_start_with_poly_data(s.app, worker, s.app.ctx, self_cleanup = true)
    return {}, nil
}
```

> Raw webview calls (`eval`, resolving an invoke) must happen on the UI thread.
> `emit` already handles that hop; for your own UI-thread work use
> `hd.dispatch_main(app, fn, user)`.
