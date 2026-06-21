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

Import `on` from the generated client (same place as your commands):

```js
import { on } from "./heimdall.gen.js"

const off = on("file.progress", p => {
    updateBar(p.read / p.total)
})

// later, to stop listening:
off()
```

Declare the event's payload type and `on` is typed too — see
[Typed events](#typed-events-optional). No build step? `window.heimdall.on(...)`
is the untyped escape hatch.

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

## Typed events (optional)

`emit` and `on` work with any name and payload. To get a **typed `on()`** in the
generated client — autocomplete on the event name and a typed payload — declare
the event's payload type once with `hd.event`, the same way `hd.command` declares
a command:

```odin
Progress :: struct { read, total: int }

hd.event(app, "file.progress", Progress)   // declare the payload type
```

Then `heimdall generate-bindings` (see [Commands → Typed calls](./commands.md))
emits an event map and a generic `on`:

```ts
export interface HeimdallEvents {
  "file.progress": { read: number; total: number };
  "menu": { id: string };
}
export declare function on<K extends keyof HeimdallEvents>(
  name: K, handler: (payload: HeimdallEvents[K]) => void): () => void;
export declare function on(name: string, handler: (payload: any) => void): () => void;
```

```js
import { on } from "./heimdall.gen.js"

on("file.progress", p => updateBar(p.read / p.total))  // p is fully typed
```

Declaration is additive: undeclared events still type-check via the string
fallback, and untyped `emit`/`on` keep working. The built-in **`menu`** event
(emitted when a native menu item is clicked) is declared for you, so it's always
typed.
