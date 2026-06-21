package heimdall

// Robustness / fuzz tests for the inbound bridge path. The request JSON is
// attacker-influenceable (it comes from the webview), so `backend_on_request`
// must never crash and must always produce exactly one reply, whatever it's fed.
//
//   odin test heimdall
//
// We drive the real `backend_on_request` through a MOCK backend whose `reply`
// just records that a reply happened (and whether it was ok or a reject) — so the
// full parse → registry-lookup → thunk → reply path runs headlessly, no webview.

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Deterministic LCG — reproducible fuzz, no dependency on rand's API.
@(private = "file")
lcg :: proc(s: ^u64) -> u64 {
	s^ = s^ * 6364136223846793005 + 1442695040888963407
	return s^
}

// ---- mock backend + a registered command ----------------------------------
//
// Reply state is per-app (stored in app.backend.impl), NOT global — the test
// runner runs test procs concurrently, so a shared global would race.

@(private = "file")
Capture :: struct {
	count: int,
	ok:    bool,
}

@(private = "file")
mock_reply :: proc(app: ^App, id: Request_Id, ok: bool, json: string) {
	cap := cast(^Capture)app.backend.impl
	cap.count += 1
	cap.ok = ok
}

@(private = "file")
Echo :: struct {}
@(private = "file")
Echo_Args :: struct {
	msg: string,
	n:   int,
}
@(private = "file")
Echo_Result :: struct {
	msg: string,
}
@(private = "file")
echo_cmd :: proc(s: ^Echo, a: Echo_Args) -> (Echo_Result, Error) {
	return Echo_Result{msg = a.msg}, nil
}

@(private = "file")
setup_app :: proc(app: ^App, echo: ^Echo, cap: ^Capture) {
	app.ctx = context
	app.registry_allocator = context.allocator
	app.event_allocator = context.allocator
	app.registry = make(map[string]Thunk)
	app.events = make(map[string]typeid)
	app.backend = Backend {
		impl  = cap,
		reply = mock_reply,
	}
	app.backend_ready = true
	s := service(app, "svc", echo)
	command(s, "echo", echo_cmd)
}

@(private = "file")
teardown_app :: proc(app: ^App) {
	for k in app.registry {
		delete(k, app.registry_allocator)
	}
	delete(app.registry)
	delete(app.events)
}

@(private = "file")
DUMMY_ID :: Request_Id(uintptr(1))

// Feed one request and confirm exactly one reply came back.
@(private = "file")
feed :: proc(t: ^testing.T, app: ^App, cap: ^Capture, req: string) {
	cap.count = 0
	backend_on_request(app, DUMMY_ID, req)
	testing.expectf(
		t,
		cap.count == 1,
		"expected exactly 1 reply, got %d for input %q",
		cap.count,
		req,
	)
}

// ---- hostile corpus: every one must reply exactly once, no crash ----------

@(test)
test_bridge_hostile_corpus :: proc(t: ^testing.T) {
	echo: Echo
	cap: Capture
	app: App
	setup_app(&app, &echo, &cap)
	defer teardown_app(&app)

	corpus := []string {
		"", // empty
		" ", // whitespace
		"[]", // empty array (no command name)
		"[123]", // name is not a string
		"[null]",
		"[true]",
		`["svc.echo"]`, // missing args -> defaults to {}
		`["svc.echo", {"msg": "hi", "n": 1}]`, // valid
		`["svc.echo", {"msg": 123}]`, // wrong field type
		`["svc.echo", {"n": "not a number"}]`,
		`["svc.echo", null]`,
		`["svc.echo", [1,2,3]]`, // args is an array, not an object
		`["svc.echo", "a string"]`,
		`["svc.echo", 42]`,
		`["unknown.cmd", {}]`, // unknown command
		`["", {}]`, // empty name
		`[".", {}]`,
		`["svc.", {}]`,
		`[".echo", {}]`,
		`["svc.echo.extra", {}]`,
		`{"not": "an array"}`, // object, not array
		`"just a string"`,
		"42",
		"null",
		"true",
		"not json at all",
		"[", // truncated
		"]",
		`["svc.echo",`, // truncated mid-array
		`["svc.echo", {`, // truncated mid-object
		`["svc.echo", {"msg":}]`, // malformed value
		`["svc.echo", {"msg": "</script><script>alert(1)//"}]`, // injection attempt in a value
		`["svc.echo", {"msg": "\"); window.heimdall._resolve(99,1); (\""}]`, // eval-breakout attempt
		`["svc\".echo", {}]`,
		`[["nested","name"], {}]`, // name is an array
	}
	for input in corpus {
		feed(t, &app, &cap, input)
	}

	// Spot-check semantics: valid -> ok; bad -> reject.
	cap.count = 0
	backend_on_request(&app, DUMMY_ID, `["svc.echo", {"msg": "hi"}]`)
	testing.expect(t, cap.ok, "valid request should resolve (ok)")

	cap.count = 0
	backend_on_request(&app, DUMMY_ID, `["unknown.cmd", {}]`)
	testing.expect(t, !cap.ok, "unknown command should reject")

	cap.count = 0
	backend_on_request(&app, DUMMY_ID, "garbage")
	testing.expect(t, !cap.ok, "malformed JSON should reject")
}

// ---- deep nesting (recursive-descent stack safety) ------------------------

@(test)
test_bridge_deep_nesting :: proc(t: ^testing.T) {
	echo: Echo
	cap: Capture
	app: App
	setup_app(&app, &echo, &cap)
	defer teardown_app(&app)

	// Includes depths well past MAX_NESTING — without the guard these overflow the
	// parser's stack and crash; with it they're rejected (still exactly one reply).
	for depth in ([]int{16, 256, 4096, 200_000}) {
		buf := make([dynamic]u8, context.temp_allocator)
		append(&buf, '[')
		append(&buf, ..transmute([]u8)string(`"svc.echo", `))
		for _ in 0 ..< depth {append(&buf, '[')}
		for _ in 0 ..< depth {append(&buf, ']')}
		append(&buf, ']')
		feed(t, &app, &cap, string(buf[:]))
	}
}

// ---- random bytes / strings: never crash, always one reply ----------------

@(test)
test_bridge_random_fuzz :: proc(t: ^testing.T) {
	echo: Echo
	cap: Capture
	app: App
	setup_app(&app, &echo, &cap)
	defer teardown_app(&app)

	// Deterministic LCG — no dependency on rand's API, reproducible failures.
	s: u64 = 0x2545F4914F6CDD1D
	next :: proc(s: ^u64) -> u64 {
		s^ = s^ * 6364136223846793005 + 1442695040888963407
		return s^
	}

	ITER :: 5000
	for _ in 0 ..< ITER {
		kind := next(&s) % 3
		n := int(next(&s) % 96)
		buf := make([dynamic]u8, context.temp_allocator)
		switch kind {
		case 0:
			// arbitrary bytes (may be invalid UTF-8, may contain nulls)
			for _ in 0 ..< n {append(&buf, u8(next(&s)))}
		case 1:
			// printable ASCII soup (more likely to look JSON-ish)
			for _ in 0 ..< n {append(&buf, u8(0x20 + next(&s) % 0x5f))}
		case 2:
			// a valid-prefix request with a random-bytes suffix
			append(&buf, ..transmute([]u8)string(`["svc.echo", {"msg": "`))
			for _ in 0 ..< n {append(&buf, u8(0x20 + next(&s) % 0x5f))}
		}
		feed(t, &app, &cap, string(buf[:]))
		free_all(context.temp_allocator)
	}
}

// ---- native wire envelope {i,n,a} (the real native delivery path) ---------

@(test)
test_native_message_fuzz :: proc(t: ^testing.T) {
	corpus := []string {
		"",
		"{}",
		"null",
		"[]",
		"not json",
		`{"i":1,"n":"svc.echo","a":{"msg":"hi"}}`, // valid
		`{"i":"x","n":"svc.echo"}`, // missing a
		`{"n":"svc.echo","a":{}}`, // missing i
		`{"i":1}`, // missing n + a
		`{"i":{"x":true},"n":["arr"],"a":42}`, // odd value types
		`{`,
		`}`,
		`{"i":`,
		`{"i":1,"n":"x","a":"</script><script>"}`,
	}
	for input in corpus {
		_, _, _ = parse_native_message(input) // must not crash / panic
		free_all(context.temp_allocator)
	}

	// Valid -> ok, rebuilds ["name", args].
	_, req, ok := parse_native_message(`{"i":7,"n":"svc.echo","a":{"msg":"hi"}}`)
	testing.expect(t, ok, "valid native message should parse")
	testing.expect(t, strings.has_prefix(req, `["svc.echo"`), "rebuilds [name, args]")
	free_all(context.temp_allocator)

	// Deeply-nested args must be REJECTED (the guard), not crash. This is the path
	// the native backends actually use — it was unguarded before.
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, ..transmute([]u8)string(`{"i":1,"n":"x","a":`))
	for _ in 0 ..< 200_000 {append(&b, '[')}
	for _ in 0 ..< 200_000 {append(&b, ']')}
	append(&b, '}')
	_, _, ok2 := parse_native_message(string(b[:]))
	testing.expect(t, !ok2, "deeply-nested native message must be rejected, not crash")
	free_all(context.temp_allocator)

	// Random bytes -> never crash.
	s: u64 = 0x9E3779B97F4A7C15
	for _ in 0 ..< 3000 {
		n := int(lcg(&s) % 80)
		buf := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< n {append(&buf, u8(lcg(&s)))}
		_, _, _ = parse_native_message(string(buf[:]))
		free_all(context.temp_allocator)
	}
}

// ---- loopback HTTP request line (reachable by any local process) ----------

@(test)
test_request_path_fuzz :: proc(t: ^testing.T) {
	corpus := []string {
		"",
		" ",
		"GET",
		"GET ",
		"GET /",
		"GET / HTTP/1.1",
		"GET /index.html HTTP/1.1",
		"GET /a/b/c?x=1&y=2 HTTP/1.1",
		"GET /../../../etc/passwd HTTP/1.1", // traversal attempt (harmless: map key only)
		"POST /x",
		"GARBAGE",
		"\x00\x00",
		"GET  /  ",
		"GET /?",
		"GET /%00 HTTP/1.1",
	}
	for input in corpus {
		_ = request_path(input) // must not crash
	}
	s: u64 = 0xD1B54A32D192ED03
	for _ in 0 ..< 3000 {
		n := int(lcg(&s) % 96)
		buf := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< n {append(&buf, u8(lcg(&s)))}
		_ = request_path(string(buf[:]))
		free_all(context.temp_allocator)
	}
	testing.expect(t, request_path("GET / HTTP/1.1") == "index.html", "/ -> index.html")
	testing.expect(t, request_path("GET /app.js HTTP/1.1") == "app.js", "strips leading slash")
}

// ---- guess_mime (path -> mime) --------------------------------------------

@(test)
test_guess_mime_fuzz :: proc(t: ^testing.T) {
	for in_ in ([]string{"", ".", "..", "a.", ".js", "x.JS", "no-ext", "a.b.c.css", "/", "weird.\x00"}) {
		_ = guess_mime(in_)
	}
	s: u64 = 0x2545F4914F6CDD1D
	for _ in 0 ..< 2000 {
		n := int(lcg(&s) % 40)
		buf := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< n {append(&buf, u8(lcg(&s)))}
		_ = guess_mime(string(buf[:]))
		free_all(context.temp_allocator)
	}
	testing.expect(t, guess_mime("x.html") != "", "known extension resolves")
}

// ---- deep-link URL matching + delivery queueing ---------------------------

@(test)
test_deeplink_fuzz :: proc(t: ^testing.T) {
	app: App
	app.event_allocator = context.allocator
	app.cfg.url_schemes = {"myapp", "acme"}
	app.frontend_ready = false // queue path — no backend needed
	defer {
		for u in app.pending_urls {delete(u, app.event_allocator)}
		delete(app.pending_urls)
	}

	// url_matches_scheme correctness.
	testing.expect(t, url_matches_scheme(&app, "myapp://x"), "matches scheme")
	testing.expect(t, url_matches_scheme(&app, "acme://y"), "matches 2nd scheme")
	testing.expect(t, !url_matches_scheme(&app, "http://evil"), "rejects other scheme")
	testing.expect(t, !url_matches_scheme(&app, "myapp"), "no :// -> no match")
	testing.expect(t, !url_matches_scheme(&app, ""), "empty -> no match")
	testing.expect(t, !url_matches_scheme(&app, "xmyapp://"), "must be a prefix")

	for u in ([]string {
			"",
			"myapp",
			"myapp:",
			"myapp://",
			"myapp://a/b?c=1#d",
			"MYAPP://x",
			"://",
			"myapp://\x00\x01",
			"  myapp://x",
			"javascript:alert(1)",
			"file:///etc/passwd",
			"myapp://../../x",
		}) {
		_ = url_matches_scheme(&app, u) // must not crash
	}

	// deliver_open_url queueing: hostile URLs must queue without crashing; a
	// non-empty URL queues exactly once, empty is dropped.
	s: u64 = 0x6C078965A3DBF2B1
	for _ in 0 ..< 3000 {
		n := int(lcg(&s) % 80)
		buf := make([dynamic]u8, context.temp_allocator)
		if lcg(&s) & 1 == 0 {append(&buf, ..transmute([]u8)string("myapp://"))}
		for _ in 0 ..< n {append(&buf, u8(lcg(&s)))}
		url := string(buf[:])
		before := len(app.pending_urls)
		deliver_open_url(&app, url)
		want := before + (0 if url == "" else 1)
		testing.expect(t, len(app.pending_urls) == want, "url queued correctly")
		free_all(context.temp_allocator)
	}
}

// ---- reject_json: must ALWAYS emit valid JSON (reject-path eval guard) -----

@(test)
test_reject_json_fuzz :: proc(t: ^testing.T) {
	// reject_json's output is interpolated into window.heimdall._reject(id, <here>),
	// so it must always be a valid JSON string — otherwise the reject eval could be
	// broken or, worse, injected. Verify by re-parsing every output.
	check :: proc(t: ^testing.T, msg: string) {
		out := reject_json(msg)
		v, err := json.parse(transmute([]u8)out, allocator = context.temp_allocator)
		testing.expectf(t, err == .None, "reject_json output must be valid JSON (msg %q -> %q)", msg, out)
		_, is_str := v.(json.String)
		testing.expect(t, is_str, "reject_json output must be a JSON string literal")
	}

	for msg in ([]string {
			"",
			"simple",
			`with "double" quotes`,
			"new\nline\ttab",
			`</script><script>alert(1)`,
			`"); window.heimdall._resolve(1,1); ("`,
			"back\\slash",
			"control \x07 \x1b \x00 bytes",
			"unicode é 😀",
		}) {
		check(t, msg)
		free_all(context.temp_allocator)
	}

	s: u64 = 0xC2B2AE3D27D4EB4F
	for _ in 0 ..< 3000 {
		n := int(lcg(&s) % 80)
		buf := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< n {append(&buf, u8(lcg(&s)))} // arbitrary bytes (often invalid UTF-8)
		check(t, string(buf[:]))
		free_all(context.temp_allocator)
	}
}
