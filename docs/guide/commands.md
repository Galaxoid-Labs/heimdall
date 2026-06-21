# Commands

Request/response from JS to Odin. A **service** is a struct that holds state; a
**command** is a proc over it taking and returning JSON-marshalable Odin types.
The JSON marshalling glue is generated from your types at compile time — no
macros, no runtime reflection.

## Define a service and command

```odin
// services.odin
package main

import "core:fmt"
import hd "heimdall"

Greeting :: struct {            // service state
    prefix: string,
}

Greet_Args   :: struct { name: string }      // input  (from JS)
Greet_Result :: struct { message: string }   // output (to JS)

greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
    return {message = fmt.tprintf("%s%s", s.prefix, args.name)}, nil
}
```

## Register it

```odin
// main.odin
package main

import "core:os"
import hd "heimdall"

main :: proc() {
    app, err := hd.create(hd.App_Config{
        title = "My App", width = 900, height = 600, resizable = true,
        dev_url = "http://localhost:5173",  // used by `heimdall dev`
        assets  = ASSETS,                   // embedded by `heimdall build`
    })
    if err != nil { os.exit(1) }
    defer hd.destroy(app)

    greeting := Greeting{prefix = "Hello, "}
    g := hd.service(app, "greeting", &greeting)
    hd.command(g, "greet", greet)

    hd.run(app)
}
```

## Call it from JS

**Use the generated typed client** — `heimdall new`/`dev`/`build` keep it in sync
with your Odin code, so you get autocomplete and typed args + results:

```js
import { greeting } from "./heimdall.gen.js"

const { message } = await greeting.greet({ name: "Jake" })   // typed args + result
```

Each service becomes an object; each command an async method. See
[Typed calls](#typed-calls) for where the file lives and how it's regenerated.

::: details No build step? Use window.heimdall (the escape hatch)
The runtime bridge is always available as `window.heimdall`, so you can call
commands without generating anything — untyped:

```js
const { message } = await window.heimdall.invoke("greeting.greet", { name: "Jake" })
```

The typed client just wraps this — same `"service.command"` name, same wire
protocol, nicer DX.
:::

The command name is `"service.command"`. Arguments match your `Args` struct; the
resolved value matches your `Result` struct.

## Errors

A command returns `(Result, hd.Error)`. Returning a non-nil `Error` **rejects** the
JS promise:

```odin
boom :: proc(s: ^Greeting, args: Boom_Args) -> (Boom_Result, hd.Error) {
    return {}, hd.Bridge_Error.Handler_Failed
}
```
```js
try {
    await greeting.boom()        // (or window.heimdall.invoke("greeting.boom", {}))
} catch (e) {
    console.error("rejected:", e)
}
```

## Off-thread work

Commands run on the UI thread. If a command spawns a worker, that worker must hop
back to the UI thread before touching the webview — use `hd.dispatch_main`, or
just `hd.emit` (which is already thread-safe) to report results. See
[Events](./events.md).

## Typed calls

`heimdall generate-bindings` reads your Odin command types and writes a typed
**client module** — `heimdall.gen.js` + `heimdall.gen.d.ts` (default
`web/src/heimdall.gen`, set by `bindings` in `heimdall.toml`). It exposes one
object per service:

```js
import { greeting, on } from "./heimdall.gen.js"

const { message } = await greeting.greet({ name: "Jake" })  // typed args + result
const off = on("greeting.tick", t => updateCount(t.count))  // typed event payload
```

Events are typed too when you declare their payload with `hd.event(...)` — see
[Events → Typed events](./events.md#typed-events-optional).

`heimdall dev` and `heimdall build` regenerate it automatically (it's also created
by `heimdall new`), so it stays in sync with your Odin code. It's optional and
additive — the untyped `window.heimdall.invoke(...)` always works.
