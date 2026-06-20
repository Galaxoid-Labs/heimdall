#+build windows
package main

import win "core:sys/windows"

// Windows-only doctor helpers. The native backend needs the WebView2 *runtime*
// (the Evergreen runtime ships on current Win10/11). Its presence + version live
// in the EdgeUpdate "pv" registry value under the WebView2 client GUID; we read
// it directly rather than calling the loader, so `doctor` needs no WebView2 link.

@(private = "file")
WEBVIEW2_CLIENT :: "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

// Returns the installed WebView2 runtime version (e.g. "120.0.2210.91") and true,
// or "", false if not installed. Checks the system-wide (HKLM, incl. WOW6432Node)
// and per-user (HKCU) install locations.
check_webview2_runtime :: proc(allocator := context.allocator) -> (version: string, ok: bool) {
	key := "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\" + WEBVIEW2_CLIENT
	key_wow := "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\" + WEBVIEW2_CLIENT
	if v, found := reg_read_sz(win.HKEY_LOCAL_MACHINE, key_wow, "pv", allocator); found {return v, true}
	if v, found := reg_read_sz(win.HKEY_LOCAL_MACHINE, key, "pv", allocator); found {return v, true}
	if v, found := reg_read_sz(win.HKEY_CURRENT_USER, key, "pv", allocator); found {return v, true}
	return "", false
}

@(private = "file")
reg_read_sz :: proc(root: win.HKEY, subkey, value: string, allocator := context.allocator) -> (string, bool) {
	buf: [256]u16
	size := win.DWORD(size_of(buf))
	st := win.RegGetValueW(
		root,
		win.utf8_to_wstring(subkey, context.temp_allocator),
		win.utf8_to_wstring(value, context.temp_allocator),
		win.RRF_RT_REG_SZ,
		nil,
		&buf[0],
		&size,
	)
	if st != 0 {return "", false} // ERROR_SUCCESS == 0
	s := win.wstring_to_utf8(transmute(win.wstring)&buf[0], -1, allocator) or_else ""
	if s == "" || s == "0.0.0.0" {return "", false} // 0.0.0.0 == registered but not installed
	return s, true
}
