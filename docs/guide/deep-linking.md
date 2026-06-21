# Deep linking

Open your app from a custom URL scheme — `myapp://order/42` from a browser,
another app, or `open myapp://…` / `xdg-open` / a Windows shortcut.

There are two halves: **registering** the scheme with the OS (done at packaging
time), and **receiving** the URL in your running app.

## 1. Declare the scheme

Two places, kept in sync:

```odin
// main.odin — recognize the scheme in argv at runtime (Windows/Linux)
app, _ := hd.create(hd.App_Config{
    url_schemes = {"myapp"},
    on_open_url = proc(app: ^hd.App, url: string) {
        fmt.println("opened with:", url)
    },
})
```

```toml
# heimdall.toml — register the scheme with the OS (used by `heimdall bundle`)
[bundle]
schemes = "myapp"        # comma-separate for multiple: "myapp,acme"
```

`[bundle].schemes` is what makes the installed app *own* the scheme;
`url_schemes` is what the running app matches against. Use the same value(s).

## 2. Receive the URL

The incoming URL is delivered two ways — use whichever fits:

```odin
// Odin hook — fires immediately, even on cold start
on_open_url = proc(app: ^hd.App, url: string) { route(url) }
```

```js
// Frontend event — typed if you generate bindings
on("open-url", e => router.navigate(e.url))
```

A **cold-start** URL (the app wasn't running) is queued and delivered to the
frontend once the page is ready, so you won't miss it. The Odin hook always fires
immediately.

## Registration happens at bundle time

`heimdall bundle` wires the scheme into each platform's packaging:

- **macOS** — `CFBundleURLTypes` in `Info.plist`. The app must be a bundle the OS
  knows about (run the `.app`, or it's registered on install).
- **Linux** — `MimeType=x-scheme-handler/myapp` in the `.desktop` file; the
  `.deb`/`.rpm` post-install runs `update-desktop-database`.
- **Windows** — `HKCR\myapp\shell\open\command` registry keys in the Inno Setup
  installer.

During `heimdall dev` the scheme isn't registered with the OS (there's no
installed bundle), so test deep links against an installed/bundled build.

## Platform support

| | Cold start (app not running) | Already running |
| --- | --- | --- |
| **macOS** | ✅ `application:openURLs:` | ✅ same — LaunchServices reuses the instance |
| **Linux** | ✅ URL via argv | ⏳ needs single-instance forwarding |
| **Windows** | ✅ URL via argv | ⏳ needs single-instance forwarding |

macOS works fully. On Linux/Windows, **cold start works today**; the
"already-running" case (forwarding the URL to the live instance instead of
launching a second one) needs single-instance IPC and is not yet implemented —
see [internals](../internals.md). Until then, a second launch with a URL on
those platforms starts a new instance that receives the URL via argv.
