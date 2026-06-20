// Phase 0 smoke test — drives the raw webview bindings directly (no framework
// layer yet) to prove the vendored libwebview.a links and a window opens.
//
// Build/run from the repo root with the framework collection:
//   odin run examples/smoke -collection:src=.
package main

import "core:c"
import "core:fmt"
import wv "src:heimdall/webview"

main :: proc() {
	info := wv.version()
	fmt.printf(
		"heimdall smoke — webview %d.%d.%d\n",
		info.version.major,
		info.version.minor,
		info.version.patch,
	)

	w := wv.create(1, nil)
	if w == nil {
		fmt.eprintln("failed to create webview")
		return
	}
	defer wv.destroy(w)

	wv.set_title(w, "Heimdall — Phase 0")
	wv.set_size(w, 900, 600, .None)
	wv.navigate(w, "https://example.com")
	wv.run(w)
}
