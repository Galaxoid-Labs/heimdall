package heimdall

import "core:strings"

// An embedded asset: raw bytes plus an optional precomputed MIME type. The
// `embed` CLI step generates a `map[string]Asset` (keyed by path relative to the
// dist root, e.g. "index.html", "assets/app.js") using `#load` for `data`. If
// `mime` is empty the server guesses it from the path extension at serve time.
Asset :: struct {
	data: []u8,
	mime: string,
}

// Guess a MIME type from a file path's extension. Shared by the runtime server
// and the CLI embed generator so both agree. Defaults to a binary type.
guess_mime :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	if dot < 0 {
		return "application/octet-stream"
	}
	switch path[dot:] {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".json", ".map":
		return "application/json; charset=utf-8"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".ico":
		return "image/x-icon"
	case ".wasm":
		return "application/wasm"
	case ".woff2":
		return "font/woff2"
	case ".woff":
		return "font/woff"
	case ".ttf":
		return "font/ttf"
	case ".txt":
		return "text/plain; charset=utf-8"
	case:
		return "application/octet-stream"
	}
}
