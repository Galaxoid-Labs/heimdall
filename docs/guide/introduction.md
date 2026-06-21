# Introduction

Heimdall lets you build native desktop apps with an **Odin backend** and a **web
frontend**. You write your application logic in [Odin](https://odin-lang.org) and
your UI in whatever web stack you like (or plain HTML). Heimdall connects the two,
embeds your frontend into the executable, and produces a single native binary.

Think Tauri or Electron — but small, fast to iterate on, and Odin all the way down.

```odin
// Odin: expose a command
greet :: proc(s: ^Greeting, args: Greet_Args) -> (Greet_Result, hd.Error) {
    return {message = fmt.tprintf("Hello, %s", args.name)}, nil
}
```
```js
// JS: call it (typed client generated from your Odin types)
import { greeting } from "./heimdall.gen.js"
const { message } = await greeting.greet({ name: "Jake" })
```

## Why Heimdall

- **Bring your own frontend.** Your UI is just a folder of static files
  (`web/dist`). Vite, Svelte, React, or hand-written HTML — Heimdall ships none of
  it as a dependency.
- **One file to ship.** Your frontend is baked into the binary at compile time. A
  release is a single executable (or a `.app` on macOS).
- **A typed bridge.** Call Odin commands and subscribe to events from JS through a
  generated, fully-typed client — args, results, and event payloads all checked
  from your Odin types. (Plain JSON underneath; an untyped escape hatch is always
  there.)
- **Fast inner loop.** `heimdall dev` rebuilds and relaunches quickly — the main
  reason this is written in Odin.
- **Native shell.** A hand-written native backend per platform — WKWebView on
  macOS, WebKitGTK on Linux, WebView2 on Windows — with a custom `app://` scheme,
  native menus, and enforced `should_quit`.

## How it works

Three layers, one boundary:

```
WEB  (your frontend)   invoke("svc.cmd", {...})  ──►   BRIDGE (Odin)
  window.heimdall       on("event", handler)      ◄──   your procs
                                                         │
                                                         ▼
                                              NATIVE SHELL (window + webview)
```

Your web layer can never touch the OS directly. Anything privileged — files,
network, system APIs — goes through a **command** you register in Odin. That
boundary is the entire security model.

Next: [Getting Started](./getting-started.md).
