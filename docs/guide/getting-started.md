# Getting Started

## Prerequisites

- [Odin](https://odin-lang.org/docs/install/)
- [Bun](https://bun.sh)

Run `heimdall doctor` anytime to check your toolchain and platform dependencies,
or `heimdall docs` to open this documentation locally in your browser.

## Create an app

```sh
# 1. Build the heimdall CLI (from the heimdall repo)
odin build cli -out:heimdall -o:speed

# 2. Scaffold an app — vendors the framework and a dependency-free frontend
./heimdall new myapp --framework ./heimdall

# 3. Run it — a window opens with a button wired to Odin
cd myapp
heimdall dev
```

Edit your Odin or your frontend and `heimdall dev` reloads.

## Project structure

```
myapp/
  main.odin            # creates the app, registers services, runs
  services.odin        # your services + command procs
  heimdall/            # the vendored framework (import hd "heimdall")
  web/                 # your frontend → web/dist
    index.html
    src/main.js
  heimdall.toml        # optional config (window, packaging, signing)
  .github/workflows/   # a release workflow (signed builds)
```

The frontend is whatever produces `web/dist`. The vanilla template uses a tiny
Bun static server for `dev` and a copy step for `build` — swap in Vite, Svelte,
etc. by changing `dev_cmd` / `build_cmd` in `heimdall.toml`.

## Ship it

```sh
heimdall build                     # single binary with assets embedded
heimdall bundle                    # macOS .app  (needs [bundle].identifier)
heimdall bundle --sign --notarize  # signed, notarized .app for distribution
```

Next: [Commands](./commands.md) and [Events](./events.md).
