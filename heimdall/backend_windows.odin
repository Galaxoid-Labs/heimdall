#+build windows
package heimdall

// Native Windows backend — WebView2 via COM. Fills the same Backend vtable as the
// macOS and Linux backends, so the bridge / services / events / user code are
// platform-agnostic. This is the Windows backend.
//
// COM has no language support here: we hand-lay the vtable structs, call through
// function pointers, and IMPLEMENT the completion/event-handler + environment
// option interfaces ourselves (a vtable of `proc "system"` + QueryInterface +
// AddRef/Release). `core:sys/windows` provides the Win32 + base COM types (HWND,
// MSG, GUID, IStream, HRESULT, ...); only the WebView2 interfaces are bound here.
//
// Maps to the vtable as:
//   * RegisterClassExW + CreateWindowExW + WndProc + GetMessageW loop — window + loop
//   * CreateCoreWebView2EnvironmentWithOptions -> CreateCoreWebView2Controller
//       -> get_CoreWebView2                                            — async bootstrap
//   * AddScriptToExecuteOnDocumentCreated(SHIM_JS_NATIVE)              — the shim
//   * add_WebMessageReceived <- window.chrome.webview.postMessage      — JS -> Odin
//   * ExecuteScript                                                    — eval / reply / events
//   * PostMessageW(WM_APP_DISPATCH) to the UI window                   — dispatch (main-thread hop)
//   * custom "app" scheme (EnvironmentOptions4) + WebResourceRequested — serve embedded ASSETS
//   * WM_CLOSE                                                         — should_quit veto
//   * HMENU + WM_COMMAND + accelerators                               — the menu bar
//   * DwmSetWindowAttribute (immersive dark mode + rounded corners)    — modern Win11 title bar
//                                                                        that follows the system theme
//
// Link deps: WebView2LoaderStatic.lib (vendored, static — no DLL to ship) for the
// loader entry points, plus the Evergreen WebView2 *runtime* on the user's machine
// (present on current Win10/11; `heimdall doctor` checks). Ole32/User32/Dwmapi/
// Advapi32/Shlwapi are pulled in by core:sys/windows + the shlwapi import below.

import "core:mem"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// Substituted into SHIM_JS_NATIVE's __CHANNEL__ for the WebView2 message channel.
WINDOWS_CHANNEL :: "window.chrome.webview.postMessage(payload)"

// The browser version that the vendored WebView2 SDK targets
// (CORE_WEBVIEW_TARGET_PRODUCT_VERSION). Our EnvironmentOptions must report this
// from get_TargetCompatibleBrowserVersion or the runtime rejects creation with
// E_INVALIDARG. Bump this when the vendored WebView2LoaderStatic.lib is updated.
@(private = "file")
WEBVIEW2_TARGET_VERSION :: "144.0.3719.77"

WINDOWS_BACKEND_IMPLEMENTED :: true

// ---- foreign: WebView2 loader (static) + SHCreateMemStream + GDI+ ----------

foreign import webview2_loader "webview2/WebView2LoaderStatic.lib"
foreign import shlwapi "system:Shlwapi.lib"
foreign import gdiplus "system:Gdiplus.lib"

@(default_calling_convention = "system")
foreign webview2_loader {
	CreateCoreWebView2EnvironmentWithOptions :: proc(browserExecutableFolder: win.wstring, userDataFolder: win.wstring, environmentOptions: rawptr, environmentCreatedHandler: rawptr) -> win.HRESULT ---
	GetAvailableCoreWebView2BrowserVersionString :: proc(browserExecutableFolder: win.wstring, versionInfo: ^win.LPWSTR) -> win.HRESULT ---
}

@(default_calling_convention = "system")
foreign shlwapi {
	SHCreateMemStream :: proc(pInit: ^u8, cbInit: win.UINT) -> ^win.IStream ---
}

// GDI+ flat API — to decode the App_Config.icon PNG bytes into an HICON at
// runtime (the Windows analogue of macOS's NSImage-from-data Dock icon). Not in
// core:sys/windows, so bound here.
@(private = "file")
GdiplusStartupInput :: struct {
	GdiplusVersion:           u32,
	DebugEventCallback:       rawptr,
	SuppressBackgroundThread: win.BOOL,
	SuppressExternalCodecs:   win.BOOL,
}

@(default_calling_convention = "system")
foreign gdiplus {
	GdiplusStartup :: proc(token: ^uintptr, input: ^GdiplusStartupInput, output: rawptr) -> i32 ---
	GdiplusShutdown :: proc(token: uintptr) ---
	GdipCreateBitmapFromStream :: proc(stream: ^win.IStream, bitmap: ^rawptr) -> i32 ---
	GdipCreateHICONFromBitmap :: proc(bitmap: rawptr, hicon: ^win.HICON) -> i32 ---
	GdipDisposeImage :: proc(image: rawptr) -> i32 ---
}

// Named-mutex single-instance lock + cross-process foreground grant for deep-link
// forwarding (see windows_single_instance). Not bound in core:sys/windows.
foreign import kernel32_si "system:Kernel32.lib"
foreign import user32_si "system:User32.lib"

@(default_calling_convention = "system")
foreign kernel32_si {
	CreateMutexW :: proc(lpMutexAttributes: rawptr, bInitialOwner: win.BOOL, lpName: win.wstring) -> win.HANDLE ---
}

@(default_calling_convention = "system")
foreign user32_si {
	// Permit the process that owns `dwProcessId` to call SetForegroundWindow next —
	// the secondary grants the primary the right before forwarding the URL.
	AllowSetForegroundWindow :: proc(dwProcessId: win.DWORD) -> win.BOOL ---
}

@(private = "file")
ICON_SMALL :: 0
@(private = "file")
ICON_BIG :: 1

// ---- private window-message + menu-flag constants --------------------------

@(private = "file")
WM_APP_DISPATCH :: win.WM_APP + 1 // boxed UI-thread task in lParam
@(private = "file")
WM_APP_QUIT :: win.WM_APP + 2 // programmatic close (terminate / window_op Close)

// COPYDATASTRUCT.dwData tag identifying a forwarded deep-link URL (a secondary
// instance → the primary's wndproc). Arbitrary sentinel, just has to be unique
// among any WM_COPYDATA we might receive.
@(private = "file")
CDS_DEEPLINK: win.ULONG_PTR : 0x6864_0001 // 'hd', 1

@(private = "file")
MF_GRAYED: win.UINT : 0x00000001

// HRESULTs as typed constants. win.S_OK/E_* are untyped ints; the failure codes
// (0x8000_xxxx) overflow i32, so we use their signed two's-complement values
// (HRESULT is `distinct i32`).
@(private = "file")
HR_S_OK: win.HRESULT : 0
@(private = "file")
HR_E_NOINTERFACE: win.HRESULT : -2147467262 // 0x80004002
@(private = "file")
HR_E_POINTER: win.HRESULT : -2147467261 // 0x80004003

// Accelerator fVirt flags (ACCEL.fVirt) — not in core:sys/windows.
@(private = "file")
FVIRTKEY: win.BYTE : 0x01
@(private = "file")
FSHIFT: win.BYTE : 0x04
@(private = "file")
FCONTROL: win.BYTE : 0x08
@(private = "file")
FALT: win.BYTE : 0x10

// ════════════════════════════════════════════════════════════════════════════
//  CONSUMED WebView2 interfaces (runtime implements; we call through the vtable)
//
//  Each interface is a struct whose first field is a pointer to its vtable; the
//  vtable lists the methods IN ORDER. Slots we never call are typed `rawptr`
//  (pointer-sized fillers) so the offsets of the ones we DO call are exact. Slot
//  numbers / signatures are from WebView2.h (SDK 1.0.3719.77).
// ════════════════════════════════════════════════════════════════════════════

@(private = "file")
ICoreWebView2Environment :: struct {
	vtbl: ^ICoreWebView2Environment_Vtbl,
}
@(private = "file")
ICoreWebView2Environment_Vtbl :: struct {
	QueryInterface:            rawptr,
	AddRef:                    rawptr,
	Release:                   rawptr,
	CreateCoreWebView2Controller: proc "system" (this: ^ICoreWebView2Environment, parentWindow: win.HWND, handler: rawptr) -> win.HRESULT,
	CreateWebResourceResponse: proc "system" (this: ^ICoreWebView2Environment, content: rawptr, statusCode: i32, reasonPhrase: win.wstring, headers: win.wstring, response: ^rawptr) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2Controller :: struct {
	vtbl: ^ICoreWebView2Controller_Vtbl,
}
@(private = "file")
ICoreWebView2Controller_Vtbl :: struct {
	QueryInterface:                    rawptr,
	AddRef:                            rawptr,
	Release:                           rawptr,
	get_IsVisible:                     rawptr,
	put_IsVisible:                     proc "system" (this: ^ICoreWebView2Controller, isVisible: win.BOOL) -> win.HRESULT,
	get_Bounds:                        rawptr,
	put_Bounds:                        proc "system" (this: ^ICoreWebView2Controller, bounds: win.RECT) -> win.HRESULT,
	get_ZoomFactor:                    rawptr,
	put_ZoomFactor:                    rawptr,
	add_ZoomFactorChanged:             rawptr,
	remove_ZoomFactorChanged:          rawptr,
	SetBoundsAndZoomFactor:            rawptr,
	MoveFocus:                         proc "system" (this: ^ICoreWebView2Controller, reason: i32) -> win.HRESULT,
	add_MoveFocusRequested:            rawptr,
	remove_MoveFocusRequested:         rawptr,
	add_GotFocus:                      rawptr,
	remove_GotFocus:                   rawptr,
	add_LostFocus:                     rawptr,
	remove_LostFocus:                  rawptr,
	add_AcceleratorKeyPressed:         proc "system" (this: ^ICoreWebView2Controller, handler: rawptr, token: ^i64) -> win.HRESULT,
	remove_AcceleratorKeyPressed:      rawptr,
	get_ParentWindow:                  rawptr,
	put_ParentWindow:                  rawptr,
	NotifyParentWindowPositionChanged: rawptr,
	Close:                             proc "system" (this: ^ICoreWebView2Controller) -> win.HRESULT,
	get_CoreWebView2:                  proc "system" (this: ^ICoreWebView2Controller, coreWebView2: ^rawptr) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2 :: struct {
	vtbl: ^ICoreWebView2_Vtbl,
}
@(private = "file")
ICoreWebView2_Vtbl :: struct {
	QueryInterface:                            rawptr,
	AddRef:                                    rawptr,
	Release:                                   rawptr,
	get_Settings:                              proc "system" (this: ^ICoreWebView2, settings: ^rawptr) -> win.HRESULT,
	get_Source:                                rawptr,
	Navigate:                                  proc "system" (this: ^ICoreWebView2, uri: win.wstring) -> win.HRESULT,
	NavigateToString:                          proc "system" (this: ^ICoreWebView2, htmlContent: win.wstring) -> win.HRESULT,
	add_NavigationStarting:                    rawptr,
	remove_NavigationStarting:                 rawptr,
	add_ContentLoading:                        rawptr,
	remove_ContentLoading:                     rawptr,
	add_SourceChanged:                         rawptr,
	remove_SourceChanged:                      rawptr,
	add_HistoryChanged:                        rawptr,
	remove_HistoryChanged:                     rawptr,
	add_NavigationCompleted:                   rawptr,
	remove_NavigationCompleted:                rawptr,
	add_FrameNavigationStarting:               rawptr,
	remove_FrameNavigationStarting:            rawptr,
	add_FrameNavigationCompleted:              rawptr,
	remove_FrameNavigationCompleted:           rawptr,
	add_ScriptDialogOpening:                   rawptr,
	remove_ScriptDialogOpening:                rawptr,
	add_PermissionRequested:                   rawptr,
	remove_PermissionRequested:                rawptr,
	add_ProcessFailed:                         rawptr,
	remove_ProcessFailed:                      rawptr,
	AddScriptToExecuteOnDocumentCreated:       proc "system" (this: ^ICoreWebView2, javaScript: win.wstring, handler: rawptr) -> win.HRESULT,
	RemoveScriptToExecuteOnDocumentCreated:    rawptr,
	ExecuteScript:                             proc "system" (this: ^ICoreWebView2, javaScript: win.wstring, handler: rawptr) -> win.HRESULT,
	CapturePreview:                            rawptr,
	Reload:                                    rawptr,
	PostWebMessageAsJson:                      rawptr,
	PostWebMessageAsString:                    rawptr,
	add_WebMessageReceived:                    proc "system" (this: ^ICoreWebView2, handler: rawptr, token: ^i64) -> win.HRESULT,
	remove_WebMessageReceived:                 rawptr,
	CallDevToolsProtocolMethod:                rawptr,
	get_BrowserProcessId:                      rawptr,
	get_CanGoBack:                             rawptr,
	get_CanGoForward:                          rawptr,
	GoBack:                                    rawptr,
	GoForward:                                 rawptr,
	GetDevToolsProtocolEventReceiver:          rawptr,
	Stop:                                      rawptr,
	add_NewWindowRequested:                    rawptr,
	remove_NewWindowRequested:                 rawptr,
	add_DocumentTitleChanged:                  rawptr,
	remove_DocumentTitleChanged:               rawptr,
	get_DocumentTitle:                         rawptr,
	AddHostObjectToScript:                     rawptr,
	RemoveHostObjectFromScript:                rawptr,
	OpenDevToolsWindow:                        rawptr,
	add_ContainsFullScreenElementChanged:      rawptr,
	remove_ContainsFullScreenElementChanged:   rawptr,
	get_ContainsFullScreenElement:             rawptr,
	add_WebResourceRequested:                  proc "system" (this: ^ICoreWebView2, handler: rawptr, token: ^i64) -> win.HRESULT,
	remove_WebResourceRequested:               rawptr,
	AddWebResourceRequestedFilter:             proc "system" (this: ^ICoreWebView2, uri: win.wstring, resourceContext: i32) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2AcceleratorKeyPressedEventArgs :: struct {
	vtbl: ^ICoreWebView2AcceleratorKeyPressedEventArgs_Vtbl,
}
@(private = "file")
ICoreWebView2AcceleratorKeyPressedEventArgs_Vtbl :: struct {
	QueryInterface:       rawptr,
	AddRef:               rawptr,
	Release:              rawptr,
	get_KeyEventKind:     proc "system" (this: ^ICoreWebView2AcceleratorKeyPressedEventArgs, kind: ^i32) -> win.HRESULT,
	get_VirtualKey:       proc "system" (this: ^ICoreWebView2AcceleratorKeyPressedEventArgs, virtualKey: ^u32) -> win.HRESULT,
	get_KeyEventLParam:   proc "system" (this: ^ICoreWebView2AcceleratorKeyPressedEventArgs, lParam: ^i32) -> win.HRESULT,
	get_PhysicalKeyStatus: rawptr,
	get_Handled:          rawptr,
	put_Handled:          proc "system" (this: ^ICoreWebView2AcceleratorKeyPressedEventArgs, handled: win.BOOL) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2Settings :: struct {
	vtbl: ^ICoreWebView2Settings_Vtbl,
}
@(private = "file")
ICoreWebView2Settings_Vtbl :: struct {
	QueryInterface:                     rawptr,
	AddRef:                             rawptr,
	Release:                            rawptr,
	get_IsScriptEnabled:                rawptr,
	put_IsScriptEnabled:                rawptr,
	get_IsWebMessageEnabled:            rawptr,
	put_IsWebMessageEnabled:            rawptr,
	get_AreDefaultScriptDialogsEnabled: rawptr,
	put_AreDefaultScriptDialogsEnabled: rawptr,
	get_IsStatusBarEnabled:             rawptr,
	put_IsStatusBarEnabled:             rawptr,
	get_AreDevToolsEnabled:             rawptr,
	put_AreDevToolsEnabled:             proc "system" (this: ^ICoreWebView2Settings, enabled: win.BOOL) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2WebMessageReceivedEventArgs :: struct {
	vtbl: ^ICoreWebView2WebMessageReceivedEventArgs_Vtbl,
}
@(private = "file")
ICoreWebView2WebMessageReceivedEventArgs_Vtbl :: struct {
	QueryInterface:           rawptr,
	AddRef:                   rawptr,
	Release:                  rawptr,
	get_Source:               rawptr,
	get_WebMessageAsJson:     rawptr,
	TryGetWebMessageAsString: proc "system" (this: ^ICoreWebView2WebMessageReceivedEventArgs, value: ^win.LPWSTR) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2WebResourceRequestedEventArgs :: struct {
	vtbl: ^ICoreWebView2WebResourceRequestedEventArgs_Vtbl,
}
@(private = "file")
ICoreWebView2WebResourceRequestedEventArgs_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        rawptr,
	get_Request:    proc "system" (this: ^ICoreWebView2WebResourceRequestedEventArgs, request: ^rawptr) -> win.HRESULT,
	get_Response:   rawptr,
	put_Response:   proc "system" (this: ^ICoreWebView2WebResourceRequestedEventArgs, response: rawptr) -> win.HRESULT,
}

@(private = "file")
ICoreWebView2WebResourceRequest :: struct {
	vtbl: ^ICoreWebView2WebResourceRequest_Vtbl,
}
@(private = "file")
ICoreWebView2WebResourceRequest_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         rawptr,
	Release:        rawptr,
	get_Uri:        proc "system" (this: ^ICoreWebView2WebResourceRequest, uri: ^win.LPWSTR) -> win.HRESULT,
}

// Minimal IUnknown view for AddRef/Release on any consumed COM pointer (Release
// is always vtable slot 3, so this works for every interface).
@(private = "file")
IUnknown_Min :: struct {
	vtbl: ^IUnknown_Min_Vtbl,
}
@(private = "file")
IUnknown_Min_Vtbl :: struct {
	QueryInterface: rawptr,
	AddRef:         proc "system" (this: ^IUnknown_Min) -> u32,
	Release:        proc "system" (this: ^IUnknown_Min) -> u32,
}

@(private = "file")
com_addref :: proc "contextless" (p: rawptr) {
	if p != nil {u := cast(^IUnknown_Min)p;u.vtbl.AddRef(u)}
}
@(private = "file")
com_release :: proc "contextless" (p: rawptr) {
	if p != nil {u := cast(^IUnknown_Min)p;u.vtbl.Release(u)}
}

// ════════════════════════════════════════════════════════════════════════════
//  IMPLEMENTED COM objects (we provide the vtable; the runtime calls us)
//
//  Every object shares the Com_Base layout: a vtable pointer first (so the C ABI
//  `*(void***)this` finds it) and the interface IID (for QueryInterface). The
//  trampolines reach the backend through the single g_win global, like the macOS
//  /Linux backends reach theirs through g_dwn / g_lin.
// ════════════════════════════════════════════════════════════════════════════

@(private = "file")
Com_Base :: struct {
	vtbl: rawptr,    // -> one of the *_Vtbl statics below
	iid:  ^win.GUID, // this object's interface IID (used by com_qi)
}

@(private = "file")
QI_Proc :: #type proc "system" (this: ^Com_Base, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT
@(private = "file")
Ref_Proc :: #type proc "system" (this: ^Com_Base) -> u32
@(private = "file")
Str_Get :: #type proc "system" (this: ^Com_Base, value: ^win.LPWSTR) -> win.HRESULT
@(private = "file")
Str_Put :: #type proc "system" (this: ^Com_Base, value: win.wstring) -> win.HRESULT
@(private = "file")
Bool_Get :: #type proc "system" (this: ^Com_Base, value: ^win.BOOL) -> win.HRESULT
@(private = "file")
Bool_Put :: #type proc "system" (this: ^Com_Base, value: win.BOOL) -> win.HRESULT

@(private = "file")
EnvCompleted_Vtbl :: struct {
	QueryInterface: QI_Proc,
	AddRef:         Ref_Proc,
	Release:        Ref_Proc,
	Invoke:         proc "system" (this: ^Com_Base, errorCode: win.HRESULT, result: rawptr) -> win.HRESULT,
}
@(private = "file")
CtrlCompleted_Vtbl :: struct {
	QueryInterface: QI_Proc,
	AddRef:         Ref_Proc,
	Release:        Ref_Proc,
	Invoke:         proc "system" (this: ^Com_Base, errorCode: win.HRESULT, result: rawptr) -> win.HRESULT,
}
@(private = "file")
MsgReceived_Vtbl :: struct {
	QueryInterface: QI_Proc,
	AddRef:         Ref_Proc,
	Release:        Ref_Proc,
	Invoke:         proc "system" (this: ^Com_Base, sender: rawptr, args: rawptr) -> win.HRESULT,
}
@(private = "file")
ResRequested_Vtbl :: struct {
	QueryInterface: QI_Proc,
	AddRef:         Ref_Proc,
	Release:        Ref_Proc,
	Invoke:         proc "system" (this: ^Com_Base, sender: rawptr, args: rawptr) -> win.HRESULT,
}
@(private = "file")
AccelKey_Vtbl :: struct {
	QueryInterface: QI_Proc,
	AddRef:         Ref_Proc,
	Release:        Ref_Proc,
	Invoke:         proc "system" (this: ^Com_Base, sender: rawptr, args: rawptr) -> win.HRESULT,
}
@(private = "file")
ScriptCompleted_Vtbl :: struct {
	QueryInterface: QI_Proc,
	AddRef:         Ref_Proc,
	Release:        Ref_Proc,
	Invoke:         proc "system" (this: ^Com_Base, errorCode: win.HRESULT, id: win.wstring) -> win.HRESULT,
}
@(private = "file")
Options_Vtbl :: struct {
	QueryInterface:                             QI_Proc,
	AddRef:                                     Ref_Proc,
	Release:                                    Ref_Proc,
	get_AdditionalBrowserArguments:             Str_Get,
	put_AdditionalBrowserArguments:             Str_Put,
	get_Language:                               Str_Get,
	put_Language:                               Str_Put,
	get_TargetCompatibleBrowserVersion:         Str_Get,
	put_TargetCompatibleBrowserVersion:         Str_Put,
	get_AllowSingleSignOnUsingOSPrimaryAccount: Bool_Get,
	put_AllowSingleSignOnUsingOSPrimaryAccount: Bool_Put,
}
@(private = "file")
Options4_Vtbl :: struct {
	QueryInterface:               QI_Proc,
	AddRef:                       Ref_Proc,
	Release:                      Ref_Proc,
	GetCustomSchemeRegistrations: proc "system" (this: ^Com_Base, count: ^u32, schemeRegistrations: ^rawptr) -> win.HRESULT,
	SetCustomSchemeRegistrations: proc "system" (this: ^Com_Base, count: u32, schemeRegistrations: rawptr) -> win.HRESULT,
}
@(private = "file")
Scheme_Vtbl :: struct {
	QueryInterface:            QI_Proc,
	AddRef:                    Ref_Proc,
	Release:                   Ref_Proc,
	get_SchemeName:            Str_Get,
	get_TreatAsSecure:         Bool_Get,
	put_TreatAsSecure:         Bool_Put,
	GetAllowedOrigins:         proc "system" (this: ^Com_Base, count: ^u32, allowedOrigins: ^rawptr) -> win.HRESULT,
	SetAllowedOrigins:         proc "system" (this: ^Com_Base, count: u32, allowedOrigins: rawptr) -> win.HRESULT,
	get_HasAuthorityComponent: Bool_Get,
	put_HasAuthorityComponent: Bool_Put,
}

// Static vtable instances (proc pointers are compile-time constants).
@(private = "file")
g_env_ch_vtbl := EnvCompleted_Vtbl{com_qi, com_addref_self, com_release_self, env_completed_invoke}
@(private = "file")
g_ctrl_ch_vtbl := CtrlCompleted_Vtbl{com_qi, com_addref_self, com_release_self, ctrl_completed_invoke}
@(private = "file")
g_msg_vtbl := MsgReceived_Vtbl{com_qi, com_addref_self, com_release_self, msg_received_invoke}
@(private = "file")
g_res_vtbl := ResRequested_Vtbl{com_qi, com_addref_self, com_release_self, res_requested_invoke}
@(private = "file")
g_accel_key_vtbl := AccelKey_Vtbl{com_qi, com_addref_self, com_release_self, accel_key_invoke}
@(private = "file")
g_script_ch_vtbl := ScriptCompleted_Vtbl{com_qi, com_addref_self, com_release_self, script_completed_invoke}
@(private = "file")
g_options_vtbl := Options_Vtbl {
	opts_qi,
	com_addref_self,
	com_release_self,
	opt_get_str, // get_AdditionalBrowserArguments (empty default, like WRL)
	opt_set_str,
	opt_get_str, // get_Language (empty default)
	opt_set_str,
	opt_get_target_version, // get_TargetCompatibleBrowserVersion (must be a real version)
	opt_set_str,
	opt_get_bool_false,
	opt_set_bool,
}
@(private = "file")
g_options4_vtbl := Options4_Vtbl{opts4_qi, com_addref_self, com_release_self, opts4_get_schemes, opts4_set_schemes}
@(private = "file")
g_scheme_vtbl := Scheme_Vtbl {
	com_qi,
	com_addref_self,
	com_release_self,
	scheme_get_name,
	opt_get_bool_true,
	opt_set_bool,
	scheme_get_allowed_origins,
	scheme_set_allowed_origins,
	opt_get_bool_true,
	opt_set_bool,
}

// IIDs (from WebView2.h). Those for objects WE implement back QueryInterface.
@(private = "file")
IID_ENV_COMPLETED := win.GUID{0x4e8a3389, 0xc9d8, 0x4bd2, {0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d}}
@(private = "file")
IID_CTRL_COMPLETED := win.GUID{0x6c4819f3, 0xc9b7, 0x4260, {0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c}}
@(private = "file")
IID_MSG_HANDLER := win.GUID{0x57213f19, 0x00e6, 0x49fa, {0x8e, 0x07, 0x89, 0x8e, 0xa0, 0x1e, 0xcb, 0xd2}}
@(private = "file")
IID_RES_HANDLER := win.GUID{0xab00b74c, 0x15f1, 0x4646, {0x80, 0xe8, 0xe7, 0x63, 0x41, 0xd2, 0x5d, 0x71}}
@(private = "file")
IID_ACCEL_KEY := win.GUID{0xb29c7e28, 0xfa79, 0x41a8, {0x8e, 0x44, 0x65, 0x81, 0x1c, 0x76, 0xdc, 0xb2}}
@(private = "file")
IID_SCRIPT_COMPLETED := win.GUID{0xb99369f3, 0x9b11, 0x47b5, {0xbc, 0x6f, 0x8e, 0x78, 0x95, 0xfc, 0xea, 0x17}}
@(private = "file")
IID_OPTIONS := win.GUID{0x2fde08a8, 0x1e9a, 0x4766, {0x8c, 0x05, 0x95, 0xa9, 0xce, 0xb9, 0xd1, 0xc5}}
@(private = "file")
IID_OPTIONS4 := win.GUID{0xac52d13f, 0x0d38, 0x475a, {0x9d, 0xca, 0x87, 0x65, 0x80, 0xd6, 0x79, 0x3e}}
@(private = "file")
IID_SCHEME := win.GUID{0xd60ac92c, 0x37a6, 0x4b26, {0xa3, 0x9e, 0x95, 0xcf, 0xe5, 0x90, 0x47, 0xbb}}

// ---- backend state --------------------------------------------------------

@(private = "file")
Menu_Kind :: enum {
	Custom,
	Role,
}
@(private = "file")
Menu_Cmd :: struct {
	kind: Menu_Kind,
	id:   string, // custom id (emitted)
	role: Menu_Role,
}

@(private = "file")
Windows_Backend :: struct {
	app:          ^App,
	hinstance:    win.HINSTANCE,
	hwnd:         win.HWND,
	env:          rawptr, // ^ICoreWebView2Environment
	controller:   rawptr, // ^ICoreWebView2Controller
	webview:      rawptr, // ^ICoreWebView2
	ready:        bool,   // controller created, shim + handlers installed
	pending_url:  string, // navigation requested before the webview was ready
	pending_html: string,
	width:        int,
	height:       int,
	debug:        bool, // dev build — enables WebView2 DevTools
	// window icon (decoded from App_Config.icon PNG bytes)
	hicon:        win.HICON,
	// single-instance deep-link lock (only when url_schemes is set): the primary
	// holds this named mutex; a secondary forwards its URL and exits. nil when not
	// the primary / not enabled. Closed at destroy.
	mutex:        win.HANDLE,
	// menu
	accel:        win.HACCEL,
	menu_cmds:    [dynamic]Menu_Cmd,
	next_cmd:     u16,
	// fullscreen save/restore
	fs_saved:     bool,
	fs_style:     win.LONG_PTR,
	fs_rect:      win.RECT,
	// COM objects we implement (addresses handed to the runtime; must stay put)
	env_handler:        Com_Base,
	controller_handler: Com_Base,
	msg_handler:        Com_Base,
	res_handler:        Com_Base,
	accel_key_handler:  Com_Base,
	script_handler:     Com_Base,
	opts:               Com_Base,
	opts4:              Com_Base,
	scheme:             Com_Base,
}

// Single app per process — the C trampolines reach the app through this.
@(private = "file")
g_win: ^Windows_Backend

windows_backend_create :: proc(app: ^App, debug: bool) -> bool {
	win.CoInitializeEx(nil, .APARTMENTTHREADED) // WebView2 needs an STA UI thread

	w := new(Windows_Backend, app.registry_allocator)
	w.app = app
	w.debug = debug
	w.width = 800
	w.height = 600
	w.menu_cmds = make([dynamic]Menu_Cmd, app.registry_allocator)
	g_win = w

	w.hinstance = win.HINSTANCE(win.GetModuleHandleW(nil))

	// Single-instance deep-link forwarding (parity with macOS LaunchServices / the
	// Linux AF_UNIX socket): if a primary instance is already running, hand it our
	// launch URL and exit before opening a second window. Only engaged when the app
	// declares url_schemes.
	if !windows_single_instance(w) {
		os.exit(0)
	}

	// Per-app window class name so a secondary can FindWindowW the *right* primary
	// (the named mutex is per-app too; a fixed class would collide across heimdall
	// apps).
	class_name := win.utf8_to_wstring(windows_class_name(w.app), context.temp_allocator)
	wc := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = win_wndproc,
		hInstance     = w.hinstance,
		hCursor       = win.LoadCursorW(nil, transmute(win.wstring)rawptr(uintptr(32512))), // IDC_ARROW
		lpszClassName = class_name,
	}
	win.RegisterClassExW(&wc)

	title := app.cfg.title if app.cfg.title != "" else "Heimdall"
	w.hwnd = win.CreateWindowExW(
		0,
		class_name,
		win.utf8_to_wstring(title, context.temp_allocator),
		win.WS_OVERLAPPEDWINDOW,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		i32(w.width),
		i32(w.height),
		nil,
		nil,
		w.hinstance,
		nil,
	)
	if w.hwnd == nil {
		free(w, app.registry_allocator)
		return false
	}

	// Modern Win11 title bar: rounded corners + immersive dark mode following the
	// system light/dark preference (re-applied on WM_SETTINGCHANGE so it tracks
	// live theme switches — the Windows analogue of libadwaita's AdwStyleManager).
	windows_apply_theme(w.hwnd)

	// App_Config.icon (PNG bytes) → the title-bar + taskbar icon (the Windows
	// analogue of the macOS Dock icon), so a dev run looks finished without
	// bundling an .ico resource.
	windows_apply_icon(w)

	// Menu bar from App_Config.menu (built before set_size so AdjustWindowRect
	// accounts for the menu height).
	windows_install_menu(w)

	// Wire up the COM objects we implement.
	w.env_handler = {&g_env_ch_vtbl, &IID_ENV_COMPLETED}
	w.controller_handler = {&g_ctrl_ch_vtbl, &IID_CTRL_COMPLETED}
	w.msg_handler = {&g_msg_vtbl, &IID_MSG_HANDLER}
	w.res_handler = {&g_res_vtbl, &IID_RES_HANDLER}
	w.accel_key_handler = {&g_accel_key_vtbl, &IID_ACCEL_KEY}
	w.script_handler = {&g_script_ch_vtbl, &IID_SCRIPT_COMPLETED}
	w.opts = {&g_options_vtbl, &IID_OPTIONS}
	w.opts4 = {&g_options4_vtbl, &IID_OPTIONS4}
	w.scheme = {&g_scheme_vtbl, &IID_SCHEME}

	// Kick off the async WebView2 bootstrap. The completion handlers fire later on
	// this thread's message loop; the shim, message channel, app:// handler and the
	// initial navigation are all installed once the controller is ready.
	udf := windows_user_data_folder()
	CreateCoreWebView2EnvironmentWithOptions(nil, udf, &w.opts, &w.env_handler)

	app.backend = Backend {
		impl      = w,
		set_title = win_set_title,
		set_size  = win_set_size,
		window_op = win_window_op,
		navigate  = win_navigate,
		set_html  = win_set_html,
		init_js   = win_init_js,
		eval      = win_eval,
		reply     = win_reply,
		dispatch  = win_dispatch,
		run       = win_run,
		terminate = win_terminate,
		destroy   = win_destroy,
	}
	app.backend.serves_assets = true // we serve embedded assets over app://
	return true
}

// ---- helpers --------------------------------------------------------------

@(private = "file")
self_win :: proc(app: ^App) -> ^Windows_Backend {
	return cast(^Windows_Backend)app.backend.impl
}

// UTF-8 -> null-terminated UTF-16 (temp-allocated; transient).
@(private = "file")
wstr :: proc(s: string) -> win.wstring {
	return win.utf8_to_wstring(s, context.temp_allocator)
}

// UTF-8 -> CoTaskMem-owned UTF-16 (the runtime frees it). Used by the getters of
// the option/scheme objects we hand to the runtime.
@(private = "file")
co_wstr :: proc(s: string) -> win.LPWSTR {
	u := win.utf8_to_utf16(s, context.temp_allocator)
	n := len(u)
	p := win.CoTaskMemAlloc(win.SIZE_T((n + 1) * 2))
	if p == nil {return nil}
	if n > 0 {mem.copy(p, raw_data(u), n * 2)}
	(cast([^]u16)p)[n] = 0
	return cast(win.LPWSTR)p
}

@(private = "file")
guid_eq :: proc "contextless" (a, b: ^win.GUID) -> bool {
	if a == nil || b == nil {return false}
	return a.Data1 == b.Data1 && a.Data2 == b.Data2 && a.Data3 == b.Data3 && a.Data4 == b.Data4
}

@(private = "file")
windows_has_ext :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	dot := strings.last_index_byte(path, '.')
	return dot > slash
}

// "app://localhost/assets/app.js?x#y" -> "/assets/app.js"
@(private = "file")
windows_uri_path :: proc(uri: string) -> string {
	s := uri
	if i := strings.index(s, "://"); i >= 0 {s = s[i + 3:]}
	if j := strings.index_byte(s, '/'); j >= 0 {
		s = s[j:]
	} else {
		s = "/"
	}
	if q := strings.index_byte(s, '?'); q >= 0 {s = s[:q]}
	if h := strings.index_byte(s, '#'); h >= 0 {s = s[:h]}
	return s
}

// %LOCALAPPDATA%\heimdall as the WebView2 user-data folder (WebView2 creates it),
// so a packaged app in a read-only location still has somewhere writable. nil on
// failure -> the loader picks its default next to the executable.
@(private = "file")
windows_user_data_folder :: proc() -> win.wstring {
	buf := make([]u16, 512, context.temp_allocator)
	n := win.GetEnvironmentVariableW(win.utf8_to_wstring("LOCALAPPDATA", context.temp_allocator), cast(win.LPWSTR)raw_data(buf), 512)
	if n == 0 || int(n) >= 512 {return nil}
	base := win.wstring_to_utf8(transmute(win.wstring)raw_data(buf), -1, context.temp_allocator) or_else ""
	if base == "" {return nil}
	return win.utf8_to_wstring(strings.concatenate({base, "\\heimdall"}, context.temp_allocator), context.temp_allocator)
}

// ---- single-instance deep-link forwarding ---------------------------------
//
// Windows/Linux deliver a deep link as a launch argument, so opening myapp://…
// while the app already runs would otherwise spawn a SECOND window. macOS gets
// single-instance free from LaunchServices; Linux reproduces it with an AF_UNIX
// socket. Here we use the Win32 equivalents:
//
//   * The first instance creates a named mutex ("Global\heimdall-<app_id>") and
//     becomes the primary; it receives forwarded URLs via WM_COPYDATA in its
//     wndproc, re-activates its window, and delivers them like any other open-url.
//   * A later launch finds the mutex already exists, locates the primary's window
//     by its per-app class name, forwards its launch URL via WM_COPYDATA (granting
//     the primary foreground rights first), and exits without opening a window.
//
// Only engaged when the app declares url_schemes (deep links are the whole point
// of single-instance here). Returns false when this process is a secondary that
// has forwarded and should exit.

// Per-app window class name — pairs with the per-app mutex so the secondary's
// FindWindowW targets the right primary even with several heimdall apps running.
@(private = "file")
windows_class_name :: proc(app: ^App) -> string {
	id := app_identifier(app, context.temp_allocator)
	return strings.concatenate({"HeimdallWindowClass-", id}, context.temp_allocator)
}

// This process's launch deep-link URL (first argv entry matching a scheme), or "".
@(private = "file")
windows_launch_url :: proc(app: ^App) -> string {
	if len(os.args) < 2 {return ""}
	for arg in os.args[1:] {
		if url_matches_scheme(app, arg) {return arg}
	}
	return ""
}

@(private = "file")
windows_single_instance :: proc(w: ^Windows_Backend) -> (primary: bool) {
	app := w.app
	if len(app.cfg.url_schemes) == 0 {
		return true // no deep-link schemes → single-instance not needed
	}

	name := strings.concatenate({"Global\\heimdall-", app_identifier(app, context.temp_allocator)}, context.temp_allocator)
	w.mutex = CreateMutexW(nil, win.FALSE, wstr(name))
	if win.GetLastError() != win.ERROR_ALREADY_EXISTS {
		return true // we are the primary (or the mutex call failed → just run normally)
	}

	// A primary is already running. Find its window and forward our launch URL.
	hwnd := win.FindWindowW(wstr(windows_class_name(app)), nil)
	if hwnd != nil {
		pid: win.DWORD
		win.GetWindowThreadProcessId(hwnd, &pid)
		AllowSetForegroundWindow(pid) // let the primary raise itself on receipt
		url := windows_launch_url(app)
		cds := win.COPYDATASTRUCT {
			dwData = CDS_DEEPLINK,
			cbData = win.DWORD(len(url)),
			lpData = raw_data(transmute([]byte)url) if len(url) > 0 else nil,
		}
		win.SendMessageW(hwnd, win.WM_COPYDATA, 0, win.LPARAM(uintptr(&cds)))
	}
	if w.mutex != nil {win.CloseHandle(w.mutex)} // we're exiting; don't hold the handle open
	return false
}

// ---- theme (modern title bar) ---------------------------------------------

@(private = "file")
windows_is_dark :: proc() -> bool {
	data: u32
	size := win.DWORD(4)
	st := win.RegGetValueW(
		win.HKEY_CURRENT_USER,
		win.utf8_to_wstring("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", context.temp_allocator),
		win.utf8_to_wstring("AppsUseLightTheme", context.temp_allocator),
		win.RRF_RT_REG_DWORD,
		nil,
		&data,
		&size,
	)
	if st != 0 {return false} // ERROR_SUCCESS == 0; default to light
	return data == 0
}

// Decode App_Config.icon (PNG/any GDI+-supported bytes) into an HICON and set it
// as the window's small + large icon. GdipCreateHICONFromBitmap yields a
// standalone Win32 icon handle, so it stays valid after GDI+ is shut down; we
// keep it on the backend and DestroyIcon it at teardown.
@(private = "file")
windows_apply_icon :: proc(w: ^Windows_Backend) {
	if len(w.app.cfg.icon) == 0 {return}

	token: uintptr
	input := GdiplusStartupInput {
		GdiplusVersion = 1,
	}
	if GdiplusStartup(&token, &input, nil) != 0 {return}
	defer GdiplusShutdown(token)

	stream := SHCreateMemStream(raw_data(w.app.cfg.icon), win.UINT(len(w.app.cfg.icon)))
	if stream == nil {return}
	defer com_release(stream)

	bmp: rawptr
	if GdipCreateBitmapFromStream(stream, &bmp) != 0 || bmp == nil {return}
	defer GdipDisposeImage(bmp)

	hicon: win.HICON
	if GdipCreateHICONFromBitmap(bmp, &hicon) != 0 || hicon == nil {return}
	w.hicon = hicon

	win.SendMessageW(w.hwnd, win.WM_SETICON, ICON_SMALL, win.LPARAM(uintptr(hicon)))
	win.SendMessageW(w.hwnd, win.WM_SETICON, ICON_BIG, win.LPARAM(uintptr(hicon)))
}

@(private = "file")
windows_apply_theme :: proc(hwnd: win.HWND) {
	dark := win.BOOL(true) if windows_is_dark() else win.BOOL(false)
	win.DwmSetWindowAttribute(hwnd, win.DWORD(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &dark, size_of(win.BOOL))
	pref := win.DWM_WINDOW_CORNER_PREFERENCE.ROUND
	win.DwmSetWindowAttribute(hwnd, win.DWORD(win.DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE), &pref, size_of(pref))
}

// ---- generic COM QueryInterface / refcount (objects we implement) ---------

@(private = "file")
com_qi :: proc "system" (this: ^Com_Base, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT {
	if ppv == nil {return HR_E_POINTER}
	if guid_eq(riid, win.IUnknown_UUID) || guid_eq(riid, this.iid) {
		ppv^ = this
		return HR_S_OK
	}
	ppv^ = nil
	return HR_E_NOINTERFACE
}

// EnvironmentOptions QI cross-links to Options4 (the runtime QIs the options for
// IID_ICoreWebView2EnvironmentOptions4 to discover custom-scheme support).
@(private = "file")
opts_qi :: proc "system" (this: ^Com_Base, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT {
	if ppv == nil {return HR_E_POINTER}
	if guid_eq(riid, win.IUnknown_UUID) || guid_eq(riid, &IID_OPTIONS) {
		ppv^ = &g_win.opts
		return HR_S_OK
	}
	if guid_eq(riid, &IID_OPTIONS4) {
		ppv^ = &g_win.opts4
		return HR_S_OK
	}
	ppv^ = nil
	return HR_E_NOINTERFACE
}

@(private = "file")
opts4_qi :: proc "system" (this: ^Com_Base, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT {
	if ppv == nil {return HR_E_POINTER}
	if guid_eq(riid, win.IUnknown_UUID) || guid_eq(riid, &IID_OPTIONS4) {
		ppv^ = &g_win.opts4
		return HR_S_OK
	}
	if guid_eq(riid, &IID_OPTIONS) {
		ppv^ = &g_win.opts
		return HR_S_OK
	}
	ppv^ = nil
	return HR_E_NOINTERFACE
}

// The objects we implement are singletons living in the backend struct (freed at
// destroy, after the runtime is done), so refcounting is a no-op-ish constant.
@(private = "file")
com_addref_self :: proc "system" (this: ^Com_Base) -> u32 {return 1}
@(private = "file")
com_release_self :: proc "system" (this: ^Com_Base) -> u32 {return 1}

// ---- EnvironmentOptions / CustomSchemeRegistration getters ----------------

@(private = "file")
opt_get_str :: proc "system" (this: ^Com_Base, value: ^win.LPWSTR) -> win.HRESULT {
	context = g_win.app.ctx
	if value != nil {value^ = co_wstr("")}
	return HR_S_OK
}
@(private = "file")
opt_get_target_version :: proc "system" (this: ^Com_Base, value: ^win.LPWSTR) -> win.HRESULT {
	context = g_win.app.ctx
	if value != nil {value^ = co_wstr(WEBVIEW2_TARGET_VERSION)}
	return HR_S_OK
}
@(private = "file")
opt_set_str :: proc "system" (this: ^Com_Base, value: win.wstring) -> win.HRESULT {
	return HR_S_OK
}
@(private = "file")
opt_get_bool_false :: proc "system" (this: ^Com_Base, value: ^win.BOOL) -> win.HRESULT {
	if value != nil {value^ = win.BOOL(false)}
	return HR_S_OK
}
@(private = "file")
opt_get_bool_true :: proc "system" (this: ^Com_Base, value: ^win.BOOL) -> win.HRESULT {
	if value != nil {value^ = win.BOOL(true)}
	return HR_S_OK
}
@(private = "file")
opt_set_bool :: proc "system" (this: ^Com_Base, value: win.BOOL) -> win.HRESULT {
	return HR_S_OK
}

// Options4: hand the runtime our single "app" scheme registration. The array is
// CoTaskMem-allocated (the runtime frees it) and each element is AddRef'd.
@(private = "file")
opts4_get_schemes :: proc "system" (this: ^Com_Base, count: ^u32, schemeRegistrations: ^rawptr) -> win.HRESULT {
	arr := win.CoTaskMemAlloc(size_of(rawptr))
	if arr == nil {return HR_E_POINTER}
	(cast(^rawptr)arr)^ = &g_win.scheme
	if count != nil {count^ = 1}
	if schemeRegistrations != nil {schemeRegistrations^ = arr}
	return HR_S_OK
}
@(private = "file")
opts4_set_schemes :: proc "system" (this: ^Com_Base, count: u32, schemeRegistrations: rawptr) -> win.HRESULT {
	return HR_S_OK
}

@(private = "file")
scheme_get_name :: proc "system" (this: ^Com_Base, value: ^win.LPWSTR) -> win.HRESULT {
	context = g_win.app.ctx
	if value != nil {value^ = co_wstr("app")}
	return HR_S_OK
}
@(private = "file")
scheme_get_allowed_origins :: proc "system" (this: ^Com_Base, count: ^u32, allowedOrigins: ^rawptr) -> win.HRESULT {
	// No cross-origin allow-list needed: the page IS app://localhost, so its
	// subresource fetches are same-origin.
	if count != nil {count^ = 0}
	if allowedOrigins != nil {allowedOrigins^ = nil}
	return HR_S_OK
}
@(private = "file")
scheme_set_allowed_origins :: proc "system" (this: ^Com_Base, count: u32, allowedOrigins: rawptr) -> win.HRESULT {
	return HR_S_OK
}

// ---- completion / event handler Invokes -----------------------------------

// Environment ready -> create the controller for our HWND.
@(private = "file")
env_completed_invoke :: proc "system" (this: ^Com_Base, errorCode: win.HRESULT, result: rawptr) -> win.HRESULT {
	context = g_win.app.ctx
	if result == nil {return HR_S_OK}
	w := g_win
	w.env = result
	com_addref(result)
	env := cast(^ICoreWebView2Environment)result
	env.vtbl.CreateCoreWebView2Controller(env, w.hwnd, &w.controller_handler)
	return HR_S_OK
}

// Controller ready -> grab the webview, size it, install the shim + channel +
// app:// handler, then apply any navigation requested before we were ready.
@(private = "file")
ctrl_completed_invoke :: proc "system" (this: ^Com_Base, errorCode: win.HRESULT, result: rawptr) -> win.HRESULT {
	context = g_win.app.ctx
	if result == nil {return HR_S_OK}
	w := g_win
	c := cast(^ICoreWebView2Controller)result
	w.controller = result
	com_addref(result)

	wv_ptr: rawptr
	c.vtbl.get_CoreWebView2(c, &wv_ptr)
	w.webview = wv_ptr
	com_addref(wv_ptr)

	rc: win.RECT
	win.GetClientRect(w.hwnd, &rc)
	c.vtbl.put_Bounds(c, rc)
	c.vtbl.put_IsVisible(c, win.BOOL(true))
	c.vtbl.MoveFocus(c, 0) // PROGRAMMATIC — give the web content initial keyboard focus

	wv := cast(^ICoreWebView2)wv_ptr

	// DevTools (F12 / right-click Inspect) only in dev builds — matches the other
	// backends' developer-extras gating. WebView2 defaults these to ON.
	settings: rawptr
	wv.vtbl.get_Settings(wv, &settings)
	if settings != nil {
		s := cast(^ICoreWebView2Settings)settings
		s.vtbl.put_AreDevToolsEnabled(s, win.BOOL(w.debug))
	}

	shim, _ := strings.replace_all(SHIM_JS_NATIVE, "__CHANNEL__", WINDOWS_CHANNEL, context.temp_allocator)
	wv.vtbl.AddScriptToExecuteOnDocumentCreated(wv, wstr(shim), &w.script_handler)

	tok: i64
	wv.vtbl.add_WebMessageReceived(wv, &w.msg_handler, &tok)
	wv.vtbl.AddWebResourceRequestedFilter(wv, wstr("app://*"), 0) // 0 == _CONTEXT_ALL
	wv.vtbl.add_WebResourceRequested(wv, &w.res_handler, &tok)
	// Forward host menu accelerators even when the web content has focus (the
	// controller fires this before the page sees the key). Without it, accelerators
	// would only work while the top-level window had focus.
	c.vtbl.add_AcceleratorKeyPressed(c, &w.accel_key_handler, &tok)

	w.ready = true
	if w.pending_url != "" {
		wv.vtbl.Navigate(wv, wstr(w.pending_url))
	} else if w.pending_html != "" {
		wv.vtbl.NavigateToString(wv, wstr(w.pending_html))
	}
	delete(w.pending_url, w.app.registry_allocator)
	delete(w.pending_html, w.app.registry_allocator)
	w.pending_url = ""
	w.pending_html = ""
	return HR_S_OK
}

@(private = "file")
script_completed_invoke :: proc "system" (this: ^Com_Base, errorCode: win.HRESULT, id: win.wstring) -> win.HRESULT {
	return HR_S_OK
}

// A key reached the webview before the page — run it through the host accelerator
// table so menu shortcuts (e.g. Ctrl+N) fire even when the web content has focus.
// If it matched, mark Handled so the page doesn't also act on it.
@(private = "file")
accel_key_invoke :: proc "system" (this: ^Com_Base, sender: rawptr, args: rawptr) -> win.HRESULT {
	w := g_win
	if w.accel == nil {return HR_S_OK} // no accelerators registered
	a := cast(^ICoreWebView2AcceleratorKeyPressedEventArgs)args

	kind: i32
	a.vtbl.get_KeyEventKind(a, &kind)
	if kind != 0 && kind != 2 {return HR_S_OK} // only KEY_DOWN / SYSTEM_KEY_DOWN

	vk: u32
	a.vtbl.get_VirtualKey(a, &vk)
	lp: i32
	a.vtbl.get_KeyEventLParam(a, &lp)

	msg := win.MSG {
		hwnd    = w.hwnd,
		message = win.WM_SYSKEYDOWN if kind == 2 else win.WM_KEYDOWN,
		wParam  = win.WPARAM(vk),
		lParam  = win.LPARAM(lp),
	}
	if win.TranslateAcceleratorW(w.hwnd, w.accel, &msg) != 0 {
		a.vtbl.put_Handled(a, win.BOOL(true)) // we handled it; don't pass to the page
	}
	return HR_S_OK
}

// JS -> Odin: the shim posts a JSON string; pull it out and dispatch.
@(private = "file")
msg_received_invoke :: proc "system" (this: ^Com_Base, sender: rawptr, args: rawptr) -> win.HRESULT {
	context = g_win.app.ctx
	a := cast(^ICoreWebView2WebMessageReceivedEventArgs)args
	sp: win.LPWSTR
	if a.vtbl.TryGetWebMessageAsString(a, &sp) >= 0 && sp != nil {
		s := win.wstring_to_utf8(transmute(win.wstring)sp, -1, context.temp_allocator) or_else ""
		win.CoTaskMemFree(sp)
		windows_handle_message(g_win.app, s)
	}
	return HR_S_OK
}

// app:// request -> serve from the embedded asset map (or a 404 response).
@(private = "file")
res_requested_invoke :: proc "system" (this: ^Com_Base, sender: rawptr, args: rawptr) -> win.HRESULT {
	context = g_win.app.ctx
	defer free_all(context.temp_allocator)
	w := g_win
	a := cast(^ICoreWebView2WebResourceRequestedEventArgs)args

	req_ptr: rawptr
	a.vtbl.get_Request(a, &req_ptr)
	uri := ""
	if req_ptr != nil {
		r := cast(^ICoreWebView2WebResourceRequest)req_ptr
		up: win.LPWSTR
		r.vtbl.get_Uri(r, &up)
		if up != nil {
			uri = win.wstring_to_utf8(transmute(win.wstring)up, -1, context.temp_allocator) or_else ""
			win.CoTaskMemFree(up)
		}
		com_release(req_ptr)
	}

	path := strings.trim_prefix(windows_uri_path(uri), "/")
	if path == "" {path = "index.html"}
	asset, ok := w.app.cfg.assets[path]
	if !ok && !windows_has_ext(path) {
		asset, ok = w.app.cfg.assets["index.html"] // SPA fallback
	}

	env := cast(^ICoreWebView2Environment)w.env
	resp: rawptr
	if ok {
		mime := asset.mime if asset.mime != "" else guess_mime(path)
		headers := wstr(strings.concatenate({"Content-Type: ", mime}, context.temp_allocator))
		stream := SHCreateMemStream(raw_data(asset.data), win.UINT(len(asset.data)))
		env.vtbl.CreateWebResourceResponse(env, stream, 200, wstr("OK"), headers, &resp)
		com_release(stream)
	} else {
		env.vtbl.CreateWebResourceResponse(env, nil, 404, wstr("Not Found"), wstr(""), &resp)
	}
	if resp != nil {
		a.vtbl.put_Response(a, resp)
		com_release(resp)
	}
	return HR_S_OK
}

// Parse the native wire message {i, n, a}, rebuild the `[name, args]` envelope
// (shared with backend_on_request), carry the JS id through Request_Id. Mirrors
// darwin_handle_message / linux_handle_message exactly.
@(private = "file")
windows_handle_message :: proc(app: ^App, body: string) {
	context = app.ctx
	id_json, req_json, ok := parse_native_message(body)
	if !ok {return}
	id_c := strings.clone_to_cstring(id_json, context.temp_allocator)
	backend_on_request(app, transmute(Request_Id)id_c, req_json)
}

// ---- WndProc + dispatch ---------------------------------------------------

@(private = "file")
Dispatch_Box :: struct {
	app:  ^App,
	fn:   proc(app: ^App, user: rawptr),
	user: rawptr,
}

@(private = "file")
win_wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	w := g_win
	switch msg {
	case win.WM_SIZE:
		if w != nil && w.controller != nil {
			rc: win.RECT
			win.GetClientRect(hwnd, &rc)
			c := cast(^ICoreWebView2Controller)w.controller
			c.vtbl.put_Bounds(c, rc)
		}
		return 0
	case WM_APP_DISPATCH:
		box := cast(^Dispatch_Box)rawptr(uintptr(lparam))
		if box != nil {
			context = box.app.ctx
			box.fn(box.app, box.user)
			free(box, box.app.event_allocator)
		}
		return 0
	case win.WM_COMMAND:
		if w != nil {
			id := u16(wparam & 0xFFFF)
			if id != 0 {
				context = w.app.ctx
				windows_menu_command(w, id)
				return 0
			}
		}
	case win.WM_GETMINMAXINFO:
		if w != nil && (w.app.cfg.min_width > 0 || w.app.cfg.min_height > 0) {
			mmi := cast(^win.MINMAXINFO)rawptr(uintptr(lparam))
			if w.app.cfg.min_width > 0 {mmi.ptMinTrackSize.x = i32(w.app.cfg.min_width)}
			if w.app.cfg.min_height > 0 {mmi.ptMinTrackSize.y = i32(w.app.cfg.min_height)}
			return 0
		}
	case win.WM_SETTINGCHANGE:
		if w != nil {
			context = w.app.ctx
			windows_apply_theme(hwnd)
		}
	case win.WM_COPYDATA:
		// A secondary instance forwarded a deep-link URL (single-instance, above).
		// Windows copies the payload into our address space for the duration of this
		// synchronous call, so consume it now: re-activate the window and deliver.
		if w != nil {
			cds := cast(^win.COPYDATASTRUCT)rawptr(uintptr(lparam))
			if cds != nil && cds.dwData == CDS_DEEPLINK {
				context = w.app.ctx
				if win.IsIconic(hwnd) {win.ShowWindow(hwnd, win.SW_RESTORE)}
				win.SetForegroundWindow(hwnd)
				if cds.cbData > 0 && cds.lpData != nil {
					url := string((cast([^]byte)cds.lpData)[:cds.cbData])
					deliver_open_url(w.app, url)
				}
				return 1 // TRUE — processed
			}
		}
	case win.WM_CLOSE:
		if w != nil {
			context = w.app.ctx
			if w.app.cfg.should_quit != nil && !w.app.cfg.should_quit(w.app) {
				return 0 // vetoed
			}
		}
		win.DestroyWindow(hwnd)
		return 0
	case WM_APP_QUIT:
		win.DestroyWindow(hwnd)
		return 0
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// UI-thread dispatch. Box {app, fn, user} and post it to the UI window; WndProc
// unboxes and runs it. PostMessageW is thread-safe, so this is the main-thread
// hop for emit()/terminate().
@(private = "file")
win_dispatch :: proc(app: ^App, fn: proc(app: ^App, user: rawptr), user: rawptr) {
	box := new(Dispatch_Box, app.event_allocator)
	box^ = Dispatch_Box{app = app, fn = fn, user = user}
	win.PostMessageW(self_win(app).hwnd, WM_APP_DISPATCH, 0, win.LPARAM(uintptr(box)))
}

// ---- menu bar -------------------------------------------------------------
//
// Top-level App_Config.menu entries become popups in the window's menu bar.
// Custom items emit "menu" { id }; role items map to a Win32/WebView2 behavior.
// Like the Linux backend (and unlike macOS), only the user's menus are rendered
// — WebView2 already provides copy/paste + a context menu. Accelerators go into a
// HACCEL translated in the message loop.

@(private = "file")
windows_install_menu :: proc(w: ^Windows_Backend) {
	if len(w.app.cfg.menu) == 0 {return}
	accels := make([dynamic]win.ACCEL, context.temp_allocator)
	bar := win.CreateMenu()
	for top in w.app.cfg.menu {
		sub := win.CreatePopupMenu()
		windows_build_menu(w, sub, top.submenu, &accels)
		win.AppendMenuW(bar, win.MF_POPUP | win.MF_STRING, uintptr(sub), wstr(top.label))
	}
	win.SetMenu(w.hwnd, bar)
	if len(accels) > 0 {
		w.accel = win.CreateAcceleratorTableW(raw_data(accels[:]), i32(len(accels)))
	}
}

@(private = "file")
windows_build_menu :: proc(w: ^Windows_Backend, menu: win.HMENU, items: []Menu_Item, accels: ^[dynamic]win.ACCEL) {
	for it in items {
		if it.separator {
			win.AppendMenuW(menu, win.MF_SEPARATOR, 0, nil)
			continue
		}
		if len(it.submenu) > 0 && it.role == .None && it.id == "" {
			sub := win.CreatePopupMenu()
			windows_build_menu(w, sub, it.submenu, accels)
			win.AppendMenuW(menu, win.MF_POPUP | win.MF_STRING, uintptr(sub), wstr(it.label))
			continue
		}

		cmd := windows_add_cmd(w, it)
		label := it.label
		accel := it.accelerator
		if it.role != .None {
			rl, ra := windows_role_default(it.role)
			if label == "" {label = rl}
			if accel == "" {accel = ra}
		}
		flags := win.UINT(win.MF_STRING)
		if it.disabled {flags |= MF_GRAYED}
		win.AppendMenuW(menu, flags, uintptr(cmd), wstr(label))
		if accel != "" {
			if a, okk := windows_parse_accel(accel, cmd); okk {append(accels, a)}
		}
	}
}

@(private = "file")
windows_add_cmd :: proc(w: ^Windows_Backend, it: Menu_Item) -> u16 {
	w.next_cmd += 1
	mc: Menu_Cmd
	if it.role != .None {
		mc = Menu_Cmd{kind = .Role, role = it.role}
	} else {
		mc = Menu_Cmd{kind = .Custom, id = strings.clone(it.id, w.app.registry_allocator)}
	}
	append(&w.menu_cmds, mc)
	return w.next_cmd
}

// Default label + accelerator for a role (when the user didn't override them).
@(private = "file")
windows_role_default :: proc(role: Menu_Role) -> (label: string, accel: string) {
	#partial switch role {
	case .Quit:
		return "Quit", ""
	case .Undo:
		return "Undo", "CmdOrCtrl+Z"
	case .Redo:
		return "Redo", "CmdOrCtrl+Y"
	case .Cut:
		return "Cut", "CmdOrCtrl+X"
	case .Copy:
		return "Copy", "CmdOrCtrl+C"
	case .Paste:
		return "Paste", "CmdOrCtrl+V"
	case .Select_All:
		return "Select All", "CmdOrCtrl+A"
	case .Minimize:
		return "Minimize", ""
	}
	return "", ""
}

@(private = "file")
windows_menu_command :: proc(w: ^Windows_Backend, cmd: u16) {
	idx := int(cmd) - 1
	if idx < 0 || idx >= len(w.menu_cmds) {return}
	mc := w.menu_cmds[idx]
	switch mc.kind {
	case .Custom:
		_ = emit(w.app, "menu", Menu_Event{id = mc.id})
	case .Role:
		windows_role_action(w, mc.role)
	}
}

@(private = "file")
windows_role_action :: proc(w: ^Windows_Backend, role: Menu_Role) {
	#partial switch role {
	case .Quit:
		if w.app.cfg.should_quit != nil && !w.app.cfg.should_quit(w.app) {return}
		win.PostMessageW(w.hwnd, WM_APP_QUIT, 0, 0)
	case .Minimize:
		win.ShowWindow(w.hwnd, win.SW_MINIMIZE)
	case .Undo:
		win_eval(w.app, "document.execCommand('undo')")
	case .Redo:
		win_eval(w.app, "document.execCommand('redo')")
	case .Cut:
		win_eval(w.app, "document.execCommand('cut')")
	case .Copy:
		win_eval(w.app, "document.execCommand('copy')")
	case .Paste:
		win_eval(w.app, "document.execCommand('paste')")
	case .Select_All:
		win_eval(w.app, "document.execCommand('selectAll')")
	}
	// macOS-only roles (About/Hide/Show All/Zoom) have no Win32 equivalent — skip.
}

// "CmdOrCtrl+Shift+S" -> ACCEL{fVirt, key(vk), cmd}. Last segment is the key; the
// rest are modifiers. Returns ok=false for keys we can't map to a virtual key.
@(private = "file")
windows_parse_accel :: proc(accel: string, cmd: u16) -> (win.ACCEL, bool) {
	parts := strings.split(accel, "+", context.temp_allocator)
	fvirt := FVIRTKEY
	key := ""
	for p, i in parts {
		t := strings.to_lower(strings.trim_space(p), context.temp_allocator)
		if i == len(parts) - 1 {
			key = t
		} else {
			switch t {
			case "cmd", "command", "cmdorctrl", "ctrl", "control", "super", "meta":
				fvirt |= FCONTROL
			case "shift":
				fvirt |= FSHIFT
			case "alt", "option", "opt":
				fvirt |= FALT
			}
		}
	}
	vk := windows_vk(key)
	if vk == 0 {return {}, false}
	return win.ACCEL{fVirt = fvirt, key = vk, cmd = cmd}, true
}

// Virtual-key code for a single-character accelerator key (letters/digits). VK
// codes for A-Z and 0-9 equal their ASCII uppercase byte.
@(private = "file")
windows_vk :: proc(key: string) -> u16 {
	if len(key) != 1 {return 0}
	c := key[0]
	if c >= 'a' && c <= 'z' {return u16(c - 'a' + 'A')}
	if c >= 'A' && c <= 'Z' {return u16(c)}
	if c >= '0' && c <= '9' {return u16(c)}
	return 0
}

// ---- vtable procs ---------------------------------------------------------

@(private = "file")
win_set_title :: proc(app: ^App, title: string) {
	win.SetWindowTextW(self_win(app).hwnd, wstr(title))
}

@(private = "file")
win_set_size :: proc(app: ^App, width, height: int, fixed: bool) {
	w := self_win(app)
	w.width = width
	w.height = height
	style := win.DWORD(win.GetWindowLongPtrW(w.hwnd, win.GWL_STYLE))
	if fixed {
		style &~= win.DWORD(win.WS_THICKFRAME) | win.DWORD(win.WS_MAXIMIZEBOX)
	} else {
		style |= win.DWORD(win.WS_THICKFRAME) | win.DWORD(win.WS_MAXIMIZEBOX)
	}
	win.SetWindowLongPtrW(w.hwnd, win.GWL_STYLE, win.LONG_PTR(style))

	rc := win.RECT{0, 0, i32(width), i32(height)}
	has_menu := win.BOOL(true) if len(w.app.cfg.menu) > 0 else win.BOOL(false)
	win.AdjustWindowRect(&rc, style, has_menu)
	win.SetWindowPos(w.hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top, win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_FRAMECHANGED)
}

@(private = "file")
win_navigate :: proc(app: ^App, url: string) {
	w := self_win(app)
	if w.ready && w.webview != nil {
		wv := cast(^ICoreWebView2)w.webview
		wv.vtbl.Navigate(wv, wstr(url))
	} else {
		delete(w.pending_url, app.registry_allocator)
		delete(w.pending_html, app.registry_allocator)
		w.pending_url = strings.clone(url, app.registry_allocator)
		w.pending_html = ""
	}
}

@(private = "file")
win_set_html :: proc(app: ^App, html: string) {
	w := self_win(app)
	if w.ready && w.webview != nil {
		wv := cast(^ICoreWebView2)w.webview
		wv.vtbl.NavigateToString(wv, wstr(html))
	} else {
		delete(w.pending_url, app.registry_allocator)
		delete(w.pending_html, app.registry_allocator)
		w.pending_html = strings.clone(html, app.registry_allocator)
		w.pending_url = ""
	}
}

@(private = "file")
win_init_js :: proc(app: ^App, js: string) {
	w := self_win(app)
	if w.webview != nil {
		wv := cast(^ICoreWebView2)w.webview
		wv.vtbl.AddScriptToExecuteOnDocumentCreated(wv, wstr(js), &w.script_handler)
	}
}

@(private = "file")
win_eval :: proc(app: ^App, js: string) {
	w := self_win(app)
	if w.webview == nil {return}
	wv := cast(^ICoreWebView2)w.webview
	wv.vtbl.ExecuteScript(wv, wstr(js), nil)
}

@(private = "file")
win_reply :: proc(app: ^App, id_tok: Request_Id, ok: bool, json_result: string) {
	id_str := string(transmute(cstring)id_tok)
	fn := "window.heimdall._resolve(" if ok else "window.heimdall._reject("
	js := strings.concatenate({fn, id_str, ",", json_result, ")"}, context.temp_allocator)
	win_eval(app, js)
}

@(private = "file")
win_window_op :: proc(app: ^App, op: Window_Op) {
	w := self_win(app)
	hwnd := w.hwnd
	switch op {
	case .Minimize:
		win.ShowWindow(hwnd, win.SW_MINIMIZE)
	case .Maximize:
		win.ShowWindow(hwnd, win.SW_MAXIMIZE)
	case .Unmaximize:
		win.ShowWindow(hwnd, win.SW_RESTORE)
	case .Fullscreen_On:
		win_set_fullscreen(w, true)
	case .Fullscreen_Off:
		win_set_fullscreen(w, false)
	case .Show:
		win.ShowWindow(hwnd, win.SW_SHOW)
		win.SetForegroundWindow(hwnd)
	case .Hide:
		win.ShowWindow(hwnd, win.SW_HIDE)
	case .Focus:
		win.SetForegroundWindow(hwnd)
	case .Center:
		win_center(w)
	case .Close:
		win.PostMessageW(hwnd, WM_APP_QUIT, 0, 0)
	}
}

@(private = "file")
win_center :: proc(w: ^Windows_Backend) {
	mon := win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST)
	mi: win.MONITORINFO
	mi.cbSize = size_of(win.MONITORINFO)
	if !bool(win.GetMonitorInfoW(mon, &mi)) {return}
	wr: win.RECT
	win.GetWindowRect(w.hwnd, &wr)
	ww := wr.right - wr.left
	wh := wr.bottom - wr.top
	x := mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - ww) / 2
	y := mi.rcWork.top + ((mi.rcWork.bottom - mi.rcWork.top) - wh) / 2
	win.SetWindowPos(w.hwnd, nil, x, y, 0, 0, win.SWP_NOSIZE | win.SWP_NOZORDER)
}

// Borderless-fullscreen: drop the overlapped style and cover the monitor; restore
// the saved style + rect on the way out.
@(private = "file")
win_set_fullscreen :: proc(w: ^Windows_Backend, on: bool) {
	if on {
		if w.fs_saved {return}
		w.fs_style = win.GetWindowLongPtrW(w.hwnd, win.GWL_STYLE)
		win.GetWindowRect(w.hwnd, &w.fs_rect)
		w.fs_saved = true
		mon := win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST)
		mi: win.MONITORINFO
		mi.cbSize = size_of(win.MONITORINFO)
		if !bool(win.GetMonitorInfoW(mon, &mi)) {return}
		win.SetWindowLongPtrW(w.hwnd, win.GWL_STYLE, win.LONG_PTR(win.DWORD(w.fs_style) &~ win.DWORD(win.WS_OVERLAPPEDWINDOW)))
		r := mi.rcMonitor
		win.SetWindowPos(w.hwnd, win.HWND_TOPMOST, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_FRAMECHANGED)
	} else {
		if !w.fs_saved {return}
		win.SetWindowLongPtrW(w.hwnd, win.GWL_STYLE, w.fs_style)
		r := w.fs_rect
		win.SetWindowPos(w.hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_FRAMECHANGED)
		w.fs_saved = false
	}
}

@(private = "file")
win_run :: proc(app: ^App) {
	w := self_win(app)

	// Initial window state from App_Config.
	if app.cfg.always_on_top {
		win.SetWindowPos(w.hwnd, win.HWND_TOPMOST, 0, 0, 0, 0, win.SWP_NOSIZE | win.SWP_NOMOVE)
	}
	if app.cfg.center {win_center(w)}
	if !app.cfg.hidden {
		show := win.SW_MAXIMIZE if app.cfg.maximized else win.SW_SHOWNORMAL
		win.ShowWindow(w.hwnd, show)
		win.UpdateWindow(w.hwnd)
		win.SetForegroundWindow(w.hwnd)
	}
	if app.cfg.fullscreen {win_set_fullscreen(w, true)}

	// Standard GetMessage loop. Accelerators are translated first; WM_QUIT (from
	// WM_DESTROY -> PostQuitMessage) ends the loop so run() returns cleanly.
	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		if w.accel != nil && win.TranslateAcceleratorW(w.hwnd, w.accel, &msg) != 0 {
			continue
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

@(private = "file")
win_terminate :: proc(app: ^App) {
	win.PostMessageW(self_win(app).hwnd, WM_APP_QUIT, 0, 0) // thread-safe
}

@(private = "file")
win_destroy :: proc(app: ^App) {
	w := self_win(app)
	if w.mutex != nil {win.CloseHandle(w.mutex)} // release the single-instance lock
	if w.accel != nil {win.DestroyAcceleratorTable(w.accel)}
	if w.hicon != nil {win.DestroyIcon(w.hicon)}
	if w.controller != nil {
		c := cast(^ICoreWebView2Controller)w.controller
		c.vtbl.Close(c)
	}
	com_release(w.webview)
	com_release(w.controller)
	com_release(w.env)
	delete(w.pending_url, app.registry_allocator)
	delete(w.pending_html, app.registry_allocator)
	delete(w.menu_cmds)
	free(w, app.registry_allocator)
	win.CoUninitialize()
}
