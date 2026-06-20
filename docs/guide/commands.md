# Commands (`invoke`)

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

The bridge is exposed as `window.heimdall` (and `window.__HEIMDALL__`, kept for
back-compat). Two ways to call a command:

```js
// 1) Untyped — quick, no build step:
const { message } = await window.heimdall.invoke("greeting.greet", { name: "Jake" })

// 2) Typed client (recommended) — generated from your Odin types:
import { greeting } from "./heimdall.gen.js"
const { message } = await greeting.greet({ name: "Jake" })   // args + result are typed
```

The command name is `"service.command"`. Arguments are an object matching your
`Args` struct; the resolved value matches your `Result` struct. The typed client
(see [Typed calls](#typed-calls)) just calls `window.heimdall.invoke` under the
hood — same wire protocol, nicer DX.

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
    await window.heimdall.invoke("greeting.boom", {})   // or greeting.boom() via the client
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
const off = on("file.progress", p => updateBar(p))          // events too
```

`heimdall dev` and `heimdall build` regenerate it automatically (it's also created
by `heimdall new`), so it stays in sync with your Odin code. It's optional and
additive — the untyped `window.heimdall.invoke(...)` always works.
