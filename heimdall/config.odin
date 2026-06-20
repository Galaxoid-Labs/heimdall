package heimdall

// Compile-time configuration, set via `-define:` flags at build time.

// HEIMDALL_DEV selects the dev path: the webview points at the bundler's dev
// server (App_Config.dev_url) and devtools are enabled. In a release build this
// is false and the app loads its embedded assets over the loopback server.
//   dev build:  odin build . -define:HEIMDALL_DEV=true
HEIMDALL_DEV :: #config(HEIMDALL_DEV, false)

// HEIMDALL_SCHEMA selects schema-dump mode for `heimdall generate-bindings`:
// `run` populates the registry, dumps the command schema as JSON, and exits
// without opening a window. (Wired in Phase 6.)
HEIMDALL_SCHEMA :: #config(HEIMDALL_SCHEMA, false)

// Backend selection. On macOS (WKWebView) and Linux (WebKitGTK) the native
// backend is the DEFAULT; HEIMDALL_WEBVIEW forces the cross-platform
// webview/webview backend instead. Windows uses webview/webview until its native
// backend lands.
//   odin build . -define:HEIMDALL_WEBVIEW=true   # opt out of native
HEIMDALL_WEBVIEW :: #config(HEIMDALL_WEBVIEW, false)

VERSION :: "0.0.1"
