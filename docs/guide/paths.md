# Paths

Every desktop app needs somewhere to put things: a settings file, a SQLite
database, a cache, a log. The right location differs per OS, and Odin's standard
library doesn't hand it to you. heimdall does — through one **unified,
platform-agnostic** API. Your code never branches on OS; the per-platform
locations live behind the scenes.

There are four kinds of directory:

| Kind     | For                                  | Odin           |
| -------- | ------------------------------------ | -------------- |
| `Config` | settings, preferences                | `config_dir`   |
| `Data`   | databases, user content, saved state | `data_dir`     |
| `Cache`  | regenerable scratch (safe to delete) | `cache_dir`    |
| `Log`    | log files                            | `log_dir`      |

Each is **namespaced by your app** (so two heimdall apps never collide) and
**created on first access**, so you can write into it immediately.

## App identity

Directories are named after your app. Set `app_id` in `App_Config` — a
reverse-DNS-style identifier is conventional:

```odin
app, _ := hd.create(hd.App_Config{
    title  = "My App",
    app_id = "com.example.myapp",   // used to name the per-app dirs
})
```

If you don't set `app_id`, heimdall falls back to a sanitized form of `title`
(and to `"heimdall-app"` if that's empty too). Setting `app_id` explicitly is
recommended — it's stable even if you rename the window title later.

## From Odin

```odin
cfg   := hd.config_dir(app)   // -> .../com.example.myapp
data  := hd.data_dir(app)
cache := hd.cache_dir(app)
logs  := hd.log_dir(app)

// Or a file path inside one — parent dirs (including any in the relative path)
// are created for you:
settings := hd.app_path(app, .Config, "settings.json")
db       := hd.app_path(app, .Data, "db/store.sqlite")   // makes .../db/ too
```

`app_dir(app, kind)` is the general form the four helpers wrap. **You own the
returned string** — it's allocated with `context.allocator` by default; pass a
different allocator as the last argument if you want (e.g.
`hd.config_dir(app, context.temp_allocator)`). The functions return `""` only if
the home / app-data location can't be resolved at all.

```odin
hd.app_dir      :: proc(app: ^App, kind: hd.Path_Kind, allocator := context.allocator) -> string
hd.app_path     :: proc(app: ^App, kind: hd.Path_Kind, rel: string, allocator := context.allocator) -> string
// Path_Kind :: enum { Config, Data, Cache, Log }
```

## From the frontend — the `paths` service

A built-in service named **`paths`** is always registered, so JS can ask for the
directories through the bridge. Each command returns `{ path }`:

```js
// untyped:
const { path } = await window.heimdall.invoke("paths.config")

// typed (generated client):
import { paths } from "./heimdall.gen.js"
const cfg   = (await paths.config()).path
const data  = (await paths.data()).path
const cache = (await paths.cache()).path
const logs  = (await paths.log()).path
```

> `paths` is a **reserved** service name — don't register your own service called
> `paths`. (`win` is the other reserved name; see [Window](./window.md).)

The frontend can't write files itself — it has no OS access. Use these paths to
*show* a location, or pass one back to a command that does the actual file I/O in
Odin. That boundary is the whole security model.

## Where the directories actually are

You don't need to know this to use the API, but for reference (with `app_id`
appended to each):

| Kind   | macOS                            | Linux (XDG)                         | Windows           |
| ------ | -------------------------------- | ----------------------------------- | ----------------- |
| Config | `~/Library/Application Support`  | `$XDG_CONFIG_HOME` (`~/.config`)    | `%APPDATA%`       |
| Data   | `~/Library/Application Support`  | `$XDG_DATA_HOME` (`~/.local/share`) | `%APPDATA%`       |
| Cache  | `~/Library/Caches`               | `$XDG_CACHE_HOME` (`~/.cache`)      | `%LOCALAPPDATA%`  |
| Log    | `~/Library/Logs`                 | `$XDG_STATE_HOME` (`~/.local/state`)| `%LOCALAPPDATA%`  |

On macOS and Windows some kinds share a physical root (Config == Data; on Windows
Cache == Log) — that's the platform convention. Use distinct filenames and it's a
non-issue.
