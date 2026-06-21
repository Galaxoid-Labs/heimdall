# Security

## Model

Heimdall apps follow the webview-app boundary: **the web layer cannot touch the
OS directly — everything privileged goes through a command you register in Odin.**
That boundary holds only if your frontend is trusted code. Loading untrusted or
remote content into the webview breaks the model (that content can call any
registered command and drive the `win` window-control service). Keep the frontend
your own.

## Audit (2026-06)

Scope: the bridge/IPC, asset serving, the CLI, the installers, and deep linking.

### Findings

**F1 — Shell injection in `heimdall dev` via `dev_url` (FIXED).**
`cli/cmd_dev.odin:free_port` interpolated the port (parsed from `dev_url` in
`heimdall.toml`) into `/bin/sh -c "lsof … kill"` without validation. A malicious
`heimdall.toml` (e.g. `dev_url = "http://x:1;<command>"`) would run an arbitrary
command when someone ran `heimdall dev` on that project. **Fixed:** the port is
now rejected unless it is purely numeric before any shell use.

**F3 — Unbounded recursion on deeply-nested request JSON (FIXED).**
Found by the bridge fuzz tests (`heimdall/bridge_test.odin`). `core:encoding/json`
parses recursively, so a deeply-nested request (`[[[[…]]]]`) overflowed the stack
and crashed the process — a DoS reachable from the webview (e.g. via an XSS in the
frontend). **Fixed:** an O(n) pre-scan (`within_limits`) rejects a request before
parsing if it exceeds 16 MiB or nests past 200 brackets (well above any real
command args). The guard is applied at **both** JSON entry points: `parse_request`
*and* `parse_native_message` — the latter is the actual native delivery path (the
backends' message handler parses the raw `{i,n,a}` envelope first, which initially
bypassed the guard until extended fuzzing caught it). All three native backends
now share that one guarded parser.

**F2 — Installer download integrity (FIXED).**
The release workflow now publishes a `SHA256SUMS` asset (computed over every CLI
binary + the framework tarball), and both installers download it and verify each
file's SHA-256 before installing — aborting on any mismatch. `HEIMDALL_SKIP_VERIFY=1`
opts out (not recommended). *Still recommended later:* signing/notarizing the
released CLI binaries themselves (the checksums protect integrity, not provenance).

### Reviewed and OK

- **Bridge reply does not allow `eval` injection.** Odin replies by eval-ing
  `window.heimdall._resolve(<id>, <result>)`. Both `<id>` and `<result>` are
  `json.marshal` output (the id is re-serialized from the wire message), so they
  are always valid JS literals — a crafted `id`/payload cannot break out of the
  call. The bridge fuzz tests (`heimdall/bridge_test.odin`) feed ~5,000 random +
  hostile inputs (including eval-breakout attempts) through the real inbound path
  and confirm it never crashes and always replies exactly once.
- **Event payloads + deep-link URLs are JSON-encoded** before delivery to JS
  (`emit` marshals the payload), so they cannot inject script. The reject path is
  fuzzed too: `reject_json` re-parses as valid JSON for thousands of hostile +
  invalid-UTF-8 inputs, and `url_matches_scheme` / `deliver_open_url` never crash
  on crafted `myapp://…` URLs.
- **No path traversal in asset serving.** The `app://` scheme handlers (and the
  unused loopback `server.odin`) resolve paths against the in-memory embedded
  `ASSETS` map — there is no filesystem access, so `../` cannot escape.

### Inherent behaviors to know (not bugs)

- **`heimdall dev` / `build` run the project's configured `dev_cmd` / `build_cmd`**
  (from `heimdall.toml`), like `npm` scripts or a Makefile. Running these on an
  untrusted project executes its build commands. Inspect a cloned project's
  `heimdall.toml` before running.
- **Deep-link URLs are untrusted input** — anyone can invoke `myapp://…`. Validate
  the URL in your `on_open_url` hook / `open-url` handler before acting on it.
- **The `win` service is callable from any page script** (window minimize/close/…).
  Intended for your own UI; another reason to keep the frontend trusted.

## Reporting

Pre-release, no formal process yet. Open an issue (or contact the maintainer) for
anything sensitive.
