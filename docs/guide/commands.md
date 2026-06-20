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

```js
const { invoke } = window.__HEIMDALL__

const result = await invoke("greeting.greet", { name: "Jake" })
console.log(result.message)   // "Hello, Jake"
```

The command name is `"service.command"`. Arguments are an object matching your
`Args` struct; the resolved value matches your `Result` struct.

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
    await invoke("greeting.boom", {})
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

`heimdall generate-bindings` writes a `web/bindings.d.ts` from your Odin command
types, so `invoke` is fully typed in your editor. Optional and additive.
