package heimdall

// The JS client injected (via webview_init) before any page loads. Exposes
// `window.__HEIMDALL__` with:
//   invoke(name, args) -> Promise   request/response to an Odin command
//   on(name, handler)  -> off()     subscribe to events emitted from Odin
//   _event(name, payload)           internal: called by Odin (eval) to fan out
//
// Kept as a single string const so there's one source of truth for the wire
// protocol. No template literals (the Odin literal is backtick-delimited).
SHIM_JS :: `
(function () {
  if (window.__HEIMDALL__) return;

  var listeners = new Map(); // name -> Set<handler>

  function invoke(name, args) {
    // window.__heimdall_invoke is the native binding registered from Odin.
    // It returns a Promise that resolves with the command's result or rejects
    // with the error string.
    return window.__heimdall_invoke(name, args === undefined ? {} : args);
  }

  function on(name, handler) {
    var set = listeners.get(name);
    if (!set) { set = new Set(); listeners.set(name, set); }
    set.add(handler);
    return function off() {
      var s = listeners.get(name);
      if (s) { s.delete(handler); if (s.size === 0) listeners.delete(name); }
    };
  }

  // Called by Odin via eval: __HEIMDALL__._event("name", <payload literal>).
  function _event(name, payload) {
    var set = listeners.get(name);
    if (!set) return;
    set.forEach(function (h) {
      try { h(payload); } catch (e) { console.error("[heimdall] event handler error:", e); }
    });
  }

  window.__HEIMDALL__ = { invoke: invoke, on: on, _event: _event };
})();
`

// The shim for the NATIVE backends (WKWebView/WebKitGTK/WebView2). Unlike
// webview/webview's `webview_bind` (which returns a Promise directly), the native
// message channels are one-way postMessage, so invoke generates a correlation id
// and the Odin side eval-calls _resolve/_reject. `__CHANNEL__` is substituted per
// platform with the message-handler post expression at backend init.
SHIM_JS_NATIVE :: `
(function () {
  if (window.__HEIMDALL__) return;

  var listeners = new Map(); // name -> Set<handler>
  var pending = new Map();   // id -> {resolve, reject}
  var counter = 0;

  function post(payload) { __CHANNEL__; }

  function invoke(name, args) {
    var id = ++counter;
    return new Promise(function (resolve, reject) {
      pending.set(id, { resolve: resolve, reject: reject });
      post(JSON.stringify({ i: id, n: name, a: args === undefined ? {} : args }));
    });
  }

  function _resolve(id, result) {
    var p = pending.get(id);
    if (p) { pending.delete(id); p.resolve(result); }
  }
  function _reject(id, err) {
    var p = pending.get(id);
    if (p) { pending.delete(id); p.reject(err); }
  }

  function on(name, handler) {
    var set = listeners.get(name);
    if (!set) { set = new Set(); listeners.set(name, set); }
    set.add(handler);
    return function off() {
      var s = listeners.get(name);
      if (s) { s.delete(handler); if (s.size === 0) listeners.delete(name); }
    };
  }

  function _event(name, payload) {
    var set = listeners.get(name);
    if (!set) return;
    set.forEach(function (h) {
      try { h(payload); } catch (e) { console.error("[heimdall] event handler error:", e); }
    });
  }

  window.__HEIMDALL__ = {
    invoke: invoke, on: on, _event: _event, _resolve: _resolve, _reject: _reject,
  };
})();
`

// The macOS message-channel post expression substituted into SHIM_JS_NATIVE.
DARWIN_CHANNEL :: "window.webkit.messageHandlers.__heimdall_invoke.postMessage(payload)"
