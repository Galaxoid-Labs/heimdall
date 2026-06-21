#+build windows
package main

import "core:fmt"
import "core:os"
import "core:strings"

// Windows packaging — an Inno Setup installer (the same approach as the user's
// other Odin apps). The heimdall app .exe is self-contained (frontend assets are
// embedded, the WebView2 loader is linked statically, the WebView2 runtime is a
// system dependency), so there are no DLLs to stage — the installer ships one
// binary plus Start-menu / optional desktop shortcuts and an uninstaller.
//
// Outputs (under ./dist/windows):
//   <Display>-<version>-Setup.exe     ← Inno Setup installer (when iscc.exe is found)
//   <display>-<version>-portable.zip  ← portable zip (always, and the no-Inno fallback)
//
// Inno Setup: winget install JRSoftware.InnoSetup6.

@(private = "file")
WIN_DIST :: "dist\\windows"
@(private = "file")
WIN_BUILD :: "dist\\windows\\build"
@(private = "file")
WIN_STAGING :: "dist\\windows\\staging"

bundle_windows :: proc(p: Project, exe: string, do_sign: bool) {
	display := p.display_name if p.display_name != "" else p.name

	// Stage the redistributable (just the self-contained .exe + LICENSE).
	os.remove_all(WIN_STAGING)
	if os.make_directory_all(WIN_STAGING) != nil {
		fmt.eprintln("heimdall bundle: failed to create staging dir")
		os.exit(1)
	}
	staged_exe := join(WIN_STAGING, exe)
	if os.copy_file(staged_exe, exe) != nil {
		fmt.eprintfln("heimdall bundle: failed to copy %q into staging", exe)
		os.exit(1)
	}
	license_staged := ""
	for cand in ([?]string{"LICENSE", "LICENSE.txt", "LICENSE.md"}) {
		if file_exists(cand) {
			license_staged = join(WIN_STAGING, "LICENSE.txt")
			os.copy_file(license_staged, cand)
			break
		}
	}

	// Sign the staged binary (optional) before it goes into the installer/zip.
	if do_sign {
		if !sign_windows(p, staged_exe) {os.exit(1)}
	}

	ico := windows_ensure_ico(p) // abs path, or "" (installer uses the default icon)

	// Inno Setup installer (skipped with a hint if iscc.exe is absent).
	if iscc := windows_find_iscc(); iscc != "" {
		os.make_directory_all(WIN_BUILD)
		iss_path := join(WIN_BUILD, "setup.iss")
		iss := windows_iss_text(p, display, exe, win_abs(staged_exe), win_abs(license_staged) if license_staged != "" else "", ico)
		if os.write_entire_file(iss_path, transmute([]u8)iss) != nil {
			fmt.eprintln("heimdall bundle: failed to write setup.iss")
			os.exit(1)
		}
		installer := join(WIN_DIST, fmt.tprintf("%s-%s-Setup.exe", display, p.version))
		os.remove(installer) // iscc's EndUpdateResource fails if the prior exe is still mapped
		if run_inherit({iscc, "/Q", win_abs(iss_path)}) {
			fmt.printfln("heimdall bundle: wrote %s", installer)
			if do_sign {sign_windows(p, installer)}
		} else {
			fmt.eprintln("heimdall bundle: iscc failed")
		}
	} else {
		fmt.println("heimdall bundle: Inno Setup (iscc) not found — skipping installer (winget install JRSoftware.InnoSetup6)")
	}

	// Portable zip — always (and the no-Inno fallback). bsdtar ships with Win10+.
	zip := join(WIN_DIST, fmt.tprintf("%s-%s-portable.zip", strings.to_lower(display), p.version))
	os.remove(zip)
	if run_capture({"tar", "-a", "-c", "-C", WIN_STAGING, "-f", win_abs(zip), "."}).ok && file_exists(zip) {
		fmt.printfln("heimdall bundle: wrote %s", zip)
	} else {
		fmt.printfln("heimdall bundle: staging ready at %s (zip step skipped — `tar` unavailable)", WIN_STAGING)
	}
}

// ---- exe resource (icon + version), embedded at build time ----------------

// Generates an .ico (from App icon) + a versioned .rc, compiles it to .res with
// rc.exe, and returns the `-extra-linker-flags:"…res"` argument for `odin build`
// (or "" when there's no icon or rc.exe is unavailable — build still succeeds).
// Called from build_binary on Windows.
windows_build_resource :: proc(p: Project) -> string {
	if windows_ensure_ico(p) == "" {return ""} // nothing to embed
	rc_exe := windows_find_rc()
	if rc_exe == "" {
		fmt.eprintln("heimdall build: rc.exe not found (Windows SDK) — skipping embedded icon/version resource")
		return ""
	}
	rc_name := strings.concatenate({p.name, ".rc"}, context.temp_allocator)
	res_name := strings.concatenate({p.name, ".res"}, context.temp_allocator)
	if os.write_entire_file(join(WIN_BUILD, rc_name), transmute([]u8)windows_rc_text(p)) != nil {
		return ""
	}
	// Run rc with cwd = WIN_BUILD so the relative ICON "<name>.ico" + /fo resolve there.
	if !run_inherit({rc_exe, "/nologo", "/fo", res_name, rc_name}, WIN_BUILD) {
		fmt.eprintln("heimdall build: rc.exe failed — skipping embedded resource")
		return ""
	}
	// Pass the .res to the linker as an UNQUOTED relative path with native (back)
	// slashes — odin forwards the flag value verbatim; quotes get escaped by the
	// process layer and forward slashes confuse the linker's extension handling.
	return strings.concatenate({"-extra-linker-flags:", join(WIN_BUILD, res_name)}, context.temp_allocator)
}

// The .rc text: the app icon + a VERSIONINFO block. References the .ico by the
// relative name (rc runs with cwd = WIN_BUILD).
@(private = "file")
windows_rc_text :: proc(p: Project) -> string {
	display := p.display_name if p.display_name != "" else p.name
	fv := windows_file_version(p.version)
	q :: proc(s: string) -> string {return strings.concatenate({"\"", s, "\""}, context.temp_allocator)}
	return fmt.tprintf(
		`%s.ico ICON "%s.ico"

1 VERSIONINFO
 FILEVERSION    %s
 PRODUCTVERSION %s
 FILEFLAGSMASK  0x3FL
 FILEFLAGS      0x0L
 FILEOS         0x40004L
 FILETYPE       0x1L
 FILESUBTYPE    0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName",      %s
            VALUE "FileDescription",  %s
            VALUE "FileVersion",      %s
            VALUE "InternalName",     %s
            VALUE "OriginalFilename", %s
            VALUE "ProductName",      %s
            VALUE "ProductVersion",   %s
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
`,
		p.name,
		p.name,
		fv,
		fv,
		q(p.maintainer if p.maintainer != "" else display),
		q(p.summary if p.summary != "" else display),
		q(p.version),
		q(p.name),
		q(exe_name(p.name)),
		q(display),
		q(p.version),
	)
}

// SemVer "1.2.3-rc+5" -> a 4-component RC FILEVERSION "1,2,3,0" (unparseable -> 0).
@(private = "file")
windows_file_version :: proc(version: string) -> string {
	parts: [4]int
	n := 0
	for seg in strings.split_multi(version, []string{".", "-", "+"}, context.temp_allocator) {
		if n >= 4 {break}
		v := 0
		for c in seg {
			if c >= '0' && c <= '9' {v = v * 10 + int(c - '0')}
		}
		parts[n] = v
		n += 1
	}
	return fmt.tprintf("%d,%d,%d,%d", parts[0], parts[1], parts[2], parts[3])
}

// ---- icon (.ico) ----------------------------------------------------------

// Ensures dist/windows/build/<name>.ico exists, generated from p.bundle_icon
// (a .png is wrapped directly; a .ico is copied). Returns its absolute path, or
// "" when no usable icon is configured.
@(private = "file")
windows_ensure_ico :: proc(p: Project) -> string {
	if p.bundle_icon == "" {return ""}
	if !file_exists(p.bundle_icon) {
		fmt.eprintfln("heimdall bundle: icon %q not found — skipping app icon", p.bundle_icon)
		return ""
	}
	os.make_directory_all(WIN_BUILD)
	ico_rel := join(WIN_BUILD, strings.concatenate({p.name, ".ico"}, context.temp_allocator))

	if strings.has_suffix(strings.to_lower(p.bundle_icon), ".ico") {
		if os.copy_file(ico_rel, p.bundle_icon) != nil {return ""}
		return win_abs(ico_rel)
	}
	png, rerr := os.read_entire_file(p.bundle_icon, context.temp_allocator)
	if rerr != nil {return ""}
	if !windows_write_ico(png, ico_rel) {return ""}
	return win_abs(ico_rel)
}

// Wrap PNG bytes in a single-image .ico. Vista+ icons may embed a PNG payload
// directly, so this is a small header in front of the original bytes.
@(private = "file")
windows_write_ico :: proc(png: []u8, out_path: string) -> bool {
	if len(png) < 24 {return false}
	// PNG IHDR width/height: big-endian u32 at byte offsets 16 and 20.
	w := (u32(png[16]) << 24) | (u32(png[17]) << 16) | (u32(png[18]) << 8) | u32(png[19])
	h := (u32(png[20]) << 24) | (u32(png[21]) << 16) | (u32(png[22]) << 8) | u32(png[23])
	bw := u8(w) if w < 256 else 0 // 0 means 256 in an ICONDIRENTRY
	bh := u8(h) if h < 256 else 0
	n := u32(len(png))

	buf := make([dynamic]u8, 0, len(png) + 22, context.temp_allocator)
	append(&buf, 0, 0, 1, 0, 1, 0) // ICONDIR: reserved=0, type=1 (icon), count=1
	append(&buf, bw, bh, 0, 0) // entry: width, height, color count, reserved
	append(&buf, 1, 0, 32, 0) // planes=1, bitcount=32
	append(&buf, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)) // bytes in resource
	append(&buf, 22, 0, 0, 0) // image offset = sizeof(ICONDIR)+sizeof(ICONDIRENTRY)
	append(&buf, ..png)
	return os.write_entire_file(out_path, buf[:]) == nil
}

// ---- setup.iss ------------------------------------------------------------

// NOTE: built with plain concatenation, NOT fmt.tprintf — Inno's .iss is full of
// literal `{…}` constants ({app}, {group}, {autopf}, {cm:…}), and Odin's fmt
// treats `{}` as format verbs, which would mangle them.
@(private = "file")
windows_iss_text :: proc(p: Project, display, exe, src_exe, license_abs, ico_abs: string) -> string {
	app_id := p.bundle_id if strings.trim_space(p.bundle_id) != "" else display
	b := strings.builder_make(context.temp_allocator)
	w :: proc(b: ^strings.Builder, parts: ..string) {
		for s in parts {strings.write_string(b, s)}
		strings.write_byte(b, '\n')
	}

	w(&b, "; Generated by `heimdall bundle` — do not hand-edit; rerun to regenerate.")
	w(&b, "[Setup]")
	w(&b, "AppId={{", app_id, "}") // {{ is an escaped { in Inno -> the id ends up brace-wrapped
	w(&b, "AppName=", display)
	w(&b, "AppVersion=", p.version)
	if p.maintainer != "" {w(&b, "AppPublisher=", p.maintainer)}
	if p.homepage != "" {
		w(&b, "AppPublisherURL=", p.homepage)
		w(&b, "AppSupportURL=", p.homepage)
		w(&b, "AppUpdatesURL=", p.homepage)
	}
	w(&b, "DefaultDirName={autopf}\\", display)
	w(&b, "DefaultGroupName=", display)
	w(&b, "DisableProgramGroupPage=yes")
	if license_abs != "" {w(&b, "LicenseFile=", license_abs)}
	w(&b, "OutputDir=", win_abs(WIN_DIST))
	w(&b, "OutputBaseFilename=", display, "-", p.version, "-Setup")
	if ico_abs != "" {w(&b, "SetupIconFile=", ico_abs)}
	w(&b, "UninstallDisplayIcon={app}\\", exe)
	w(&b, "Compression=lzma2/ultra")
	w(&b, "SolidCompression=yes")
	w(&b, "WizardStyle=modern")
	w(&b, "PrivilegesRequired=lowest")
	w(&b, "PrivilegesRequiredOverridesAllowed=dialog")
	w(&b, "ArchitecturesAllowed=x64compatible")
	w(&b, "ArchitecturesInstallIn64BitMode=x64compatible")
	w(&b, "")
	w(&b, "[Languages]")
	w(&b, `Name: "english"; MessagesFile: "compiler:Default.isl"`)
	w(&b, "")
	w(&b, "[Tasks]")
	w(&b, `Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked`)
	w(&b, "")
	w(&b, "[Files]")
	w(&b, `Source: "`, src_exe, `"; DestDir: "{app}"; Flags: ignoreversion`)
	if license_abs != "" {
		w(&b, `Source: "`, license_abs, `"; DestDir: "{app}"; Flags: ignoreversion`)
	}
	w(&b, "")
	w(&b, "[Icons]")
	w(&b, `Name: "{group}\`, display, `"; Filename: "{app}\`, exe, `"`)
	w(&b, `Name: "{group}\{cm:UninstallProgram,`, display, `}"; Filename: "{uninstallexe}"`)
	w(&b, `Name: "{autodesktop}\`, display, `"; Filename: "{app}\`, exe, `"; Tasks: desktopicon`)
	w(&b, "")

	// Deep linking: register each URL scheme so Windows routes myapp://… to the
	// app (delivered as argv %1). HKA = per-user or per-machine to match install.
	if len(p.schemes) > 0 {
		w(&b, "[Registry]")
		for s in p.schemes {
			base := strings.concatenate({`Software\Classes\`, s}, context.temp_allocator)
			w(&b, `Root: HKA; Subkey: "`, base, `"; ValueType: string; ValueData: "URL:`, s, ` Protocol"; Flags: uninsdeletekey`)
			w(&b, `Root: HKA; Subkey: "`, base, `"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""`)
			w(&b, `Root: HKA; Subkey: "`, base, `\DefaultIcon"; ValueType: string; ValueData: "{app}\`, exe, `,0"`)
			w(&b, `Root: HKA; Subkey: "`, base, `\shell\open\command"; ValueType: string; ValueData: """{app}\`, exe, `"" ""%1"""`)
		}
		w(&b, "")
	}

	w(&b, "[Run]")
	w(&b, `Filename: "{app}\`, exe, `"; Description: "{cm:LaunchProgram,`, display, `}"; Flags: nowait postinstall skipifsilent`)
	return strings.to_string(b)
}

// ---- signtool -------------------------------------------------------------

// Authenticode-sign with signtool (Windows SDK). Cert subject from
// `[sign.windows] identity` when set, else /a auto-selects the best cert.
@(private = "file")
sign_windows :: proc(p: Project, target: string) -> bool {
	if !has_exe("signtool") {
		fmt.eprintln("heimdall bundle: signtool not found — install the Windows SDK (or drop --sign)")
		return false
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "signtool", "sign", "/fd", "SHA256", "/tr", "http://timestamp.digicert.com", "/td", "SHA256")
	if strings.trim_space(p.sign_identity) != "" {
		append(&cmd, "/n", p.sign_identity)
	} else {
		append(&cmd, "/a")
	}
	append(&cmd, target)
	if !run_inherit(cmd[:]) {
		fmt.eprintln("heimdall bundle: signtool failed")
		return false
	}
	return true
}

// ---- tool discovery + path helpers ----------------------------------------

windows_find_iscc :: proc() -> string {
	if has_exe("iscc") {return "iscc"}
	for cand in ([?]string {
		"C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe",
		"C:\\Program Files\\Inno Setup 6\\ISCC.exe",
	}) {
		if file_exists(cand) {return cand}
	}
	if local := os.get_env("LOCALAPPDATA", context.temp_allocator); local != "" {
		cand := join(local, "Programs\\Inno Setup 6\\ISCC.exe")
		if file_exists(cand) {return cand}
	}
	return ""
}

// Newest x64 rc.exe under the Windows SDK, or "" if none.
windows_find_rc :: proc() -> string {
	root := "C:\\Program Files (x86)\\Windows Kits\\10\\bin"
	f, err := os.open(root)
	if err != nil {return ""}
	defer os.close(f)
	infos, rerr := os.read_directory(f, -1, context.temp_allocator)
	if rerr != nil {return ""}

	best := ""
	for info in infos {
		if info.type != .Directory {continue}
		cand := join(join(root, info.name), "x64\\rc.exe")
		if file_exists(cand) && cand > best { // dir names sort by SDK version
			best = cand
		}
	}
	return best
}

@(private = "file")
join :: proc(a, b: string) -> string {
	return strings.concatenate({a, "\\", b}, context.temp_allocator)
}

// Absolute path for a cwd-relative one (Inno/iscc/linker want absolute paths).
@(private = "file")
win_abs :: proc(rel: string) -> string {
	if len(rel) >= 2 && rel[1] == ':' {return rel} // already absolute (e.g. C:\…)
	wd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {return rel}
	return join(wd, rel)
}
