package heimdall

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

// A tiny loopback HTTP server for production asset serving — a fallback for any
// backend that can't register a custom `app://` scheme (all current native
// backends do, via Backend.serves_assets, so this is unused today but kept as a
// seam). Serves the embedded asset map over http://127.0.0.1:<random-free-port>,
// bound to loopback only (never reachable off-box), read-only, one response per
// connection.
Asset_Server :: struct {
	socket:   net.TCP_Socket,
	endpoint: net.Endpoint,
	assets:   ^map[string]Asset, // borrowed; read-only for the server's lifetime
	worker:   ^thread.Thread,
	running:  bool, // cleared (with the socket closed) to stop the accept loop
	url:      string, // owned base URL ("http://127.0.0.1:<port>")
	alloc:    runtime.Allocator, // owns `url` and this struct
}

// Bind a free loopback port and start serving `assets` on a background thread.
// Returns the server handle and its base URL ("http://127.0.0.1:<port>").
@(require_results)
start_asset_server :: proc(
	app: ^App,
	assets: ^map[string]Asset,
) -> (
	srv: ^Asset_Server,
	url: string,
	err: Error,
) {
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 0, // 0 = let the OS pick a free port
	}
	sock, lerr := net.listen_tcp(ep)
	if lerr != nil {
		return nil, "", .Server_Failed
	}
	bound, berr := net.bound_endpoint(sock)
	if berr != nil {
		net.close(sock)
		return nil, "", .Server_Failed
	}

	srv = new(Asset_Server, app.event_allocator)
	srv.socket = sock
	srv.endpoint = bound
	srv.assets = assets
	srv.running = true
	srv.alloc = app.event_allocator
	srv.url = fmt.aprintf("http://127.0.0.1:%d", bound.port, allocator = app.event_allocator)

	srv.worker = thread.create_and_start_with_poly_data(srv, server_loop, app.ctx, self_cleanup = true)

	return srv, srv.url, nil
}

// Stop serving, release the listener, and free the server.
stop_asset_server :: proc(srv: ^Asset_Server) {
	if srv == nil {
		return
	}
	sync.atomic_store(&srv.running, false)
	net.close(srv.socket) // unblocks the accept() in server_loop
	delete(srv.url, srv.alloc)
	free(srv, srv.alloc)
}

@(private)
server_loop :: proc(srv: ^Asset_Server) {
	for sync.atomic_load(&srv.running) {
		client, _, aerr := net.accept_tcp(srv.socket)
		if aerr != nil {
			if !sync.atomic_load(&srv.running) {
				break // listener was closed by stop_asset_server
			}
			continue
		}
		serve_client(srv, client)
		net.close(client)
	}
}

@(private)
serve_client :: proc(srv: ^Asset_Server, client: net.TCP_Socket) {
	buf: [8192]u8
	n, rerr := net.recv_tcp(client, buf[:])
	if rerr != nil || n == 0 {
		return
	}

	path := request_path(string(buf[:n]))
	asset, ok := srv.assets[path]
	if !ok {
		// SPA fallback: a path with no file extension is a client-side route;
		// serve index.html so the frontend router can handle it.
		if !has_extension(path) {
			asset, ok = srv.assets["index.html"]
		}
	}
	if !ok {
		send_all(client, transmute([]u8)string("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return
	}

	mime := asset.mime if asset.mime != "" else guess_mime(path)
	header := fmt.tprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
		mime,
		len(asset.data),
	)
	send_all(client, transmute([]u8)header)
	send_all(client, asset.data)
}

// Extract and normalize the request target from "GET /path?query HTTP/1.1".
// Strips the query string, drops the leading slash, and maps "" -> "index.html".
@(private)
request_path :: proc(req: string) -> string {
	sp := strings.index_byte(req, ' ')
	if sp < 0 {
		return "index.html"
	}
	rest := req[sp + 1:]
	sp2 := strings.index_byte(rest, ' ')
	target := rest if sp2 < 0 else rest[:sp2]

	if q := strings.index_byte(target, '?'); q >= 0 {
		target = target[:q]
	}
	target = strings.trim_prefix(target, "/")
	if target == "" {
		return "index.html"
	}
	return target
}

@(private)
has_extension :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	dot := strings.last_index_byte(path, '.')
	return dot > slash
}

@(private)
send_all :: proc(client: net.TCP_Socket, data: []u8) {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(client, data[sent:])
		if err != nil {
			return
		}
		sent += n
	}
}
