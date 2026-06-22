# Frontends

Heimdall is **bring-your-own-frontend**. Your UI is just a folder of static files
(`web/dist` by default) that gets embedded into the binary at build time and served
over the `app://` scheme. Heimdall ships no bundler, framework, or `node_modules` —
whether those files came from Vite, SvelteKit, Alpine, or hand-written HTML is up
to you.

`heimdall new` scaffolds one of three starters with `--frontend`, but **any web
stack works** — see [Bring your own](#bring-your-own) below.

## The built-in scaffolds

| `--frontend` | Reactivity | Deps / bundler | Dev loop | Best for |
| --- | --- | --- | --- | --- |
| `vanilla` *(default)* | none (plain DOM) | none — zero deps, offline | refresh (no HMR) | tiny apps, a starting point, full control |
| `alpine` | [Alpine.js](https://alpinejs.dev) | none — Alpine vendored, offline | refresh (no HMR) | lightweight reactivity without a build step |
| `sveltekit` | Svelte | npm + Vite | **Vite HMR** | full-featured apps, components, routing |

All three wire up the same things: the typed client, an example command round-trip,
the `heimdall.toml` build/dev commands, and CI.

### `vanilla`

A dependency-free, Bun-served static frontend. No `node_modules`, works offline,
instant. `dev` runs a tiny static server (no HMR — refresh to see changes); `build`
just copies `web/` into `dist/`. Great when you want zero magic and full control, or
as a base to drop in your own libraries.

### `alpine`

The same dependency-free, no-bundler setup as `vanilla`, plus
[Alpine.js](https://alpinejs.dev) for lightweight reactivity — `x-data`, `x-model`,
`@click`, and friends — without a build step.

Alpine is **vendored**: a pinned, minified build is written into
`web/src/vendor/alpine.min.js` and loaded with a plain `<script>` tag, so the app
stays offline and `node_modules`-free (it's embedded into the binary like the rest
of your assets). The scaffold includes an `x-data` component wired to an Odin
command through the typed client:

```html
<body x-data="greeter">
  <input x-model="name">
  <button @click="greet">greet</button>
  <p x-text="message"></p>
</body>
```
```js
document.addEventListener("alpine:init", () => {
  Alpine.data("greeter", () => ({
    name: "world", message: "",
    async greet() { this.message = (await greeting.greet({ name: this.name })).message },
  }));
});
```

Same refresh-to-reload dev loop as `vanilla`. To update Alpine later, replace
`web/src/vendor/alpine.min.js`.

### `sveltekit`

Delegates to the official [`sv create`](https://svelte.dev/docs/cli): you pick the
template and TypeScript/JSDoc interactively, and heimdall configures it for static
embedding (`@sveltejs/adapter-static`, `ssr = false`, an `index.html` SPA fallback)
and points `heimdall.toml` at `web/build`. You get full **Vite HMR** in
`heimdall dev`.

- `--pm bun|npm|pnpm|yarn|deno` — package manager (default `bun`).
- `--add <sv-addon>` (repeatable) — Svelte add-ons (Tailwind, Prettier, …), e.g.
  `--add tailwindcss=plugins:typography`. heimdall adds the static adapter itself —
  **don't add `sveltekit-adapter` yourself**.

The typed client lands at `web/src/lib/heimdall.gen` — import it via
`import { greeting } from "$lib/heimdall.gen.js"`.

> Because the app ships as static files inside the binary, SSR-only features
> (server `load`, form actions) don't apply — it builds as a client SPA.

## Bring your own

Any framework — React, Vue, Solid, Preact, htmx, plain Vite — works, because
Heimdall only cares about the **output**. The contract is four `heimdall.toml`
settings:

```toml
web_dir   = "web"                    # your frontend project
dist_dir  = "web/dist"               # where your build writes static files (embedded)
dev_url   = "http://localhost:5173"  # your dev server (heimdall dev points the webview here)
dev_cmd   = "bun run dev"            # starts that dev server
build_cmd = "bun run build"          # produces dist_dir
```

`heimdall dev` runs `dev_cmd` and loads `dev_url` (so you keep your bundler's HMR);
`heimdall build` runs `build_cmd`, embeds `dist_dir`, and compiles the binary. To
adopt, say, React + Vite: scaffold `vanilla`, replace `web/` with your Vite app,
and point those four keys at it.

A few things to keep in mind, because the shipped app is **offline and embedded**:

- **No remote resources at runtime.** A release has no network — vendor your fonts,
  CSS, and scripts (no CDN `<script>`/`<link>`). This is exactly why `alpine`
  vendors Alpine instead of using its CDN build.
- **Static output only.** There's no server runtime in the binary, so SSR/server
  routes don't run — build as a client-side SPA. Production loads
  `app://localhost/`, so use a hash router or an SPA fallback so client routing
  matches the index route.
- **Use root-relative or relative URLs** (`/assets/app.js`, not `https://…`) so they
  resolve under the `app://` origin.
- **Secure context + CSP** apply to your frontend — see
  [Configuration → CSP](./configuration.md#content-security-policy-csp). The bridge
  itself is CSP-safe; WASM-heavy apps need `script-src 'wasm-unsafe-eval'`.

## The typed client (any frontend)

`heimdall generate-bindings` writes a typed JS client (`heimdall.gen.js` + `.d.ts`)
from your Odin command/event types; `new`/`dev`/`build` regenerate it. It's plain
ES modules, so it works with any frontend:

```js
import { greeting, on } from "./heimdall.gen.js"   // path = heimdall.toml `bindings`
const { message } = await greeting.greet({ name: "Jake" })
on("file.progress", p => updateBar(p.read / p.total))
```

It's optional and additive — `window.heimdall.invoke("greeting.greet", {…})` works
without any build step. See [Commands](./commands.md) and [Events](./events.md).
