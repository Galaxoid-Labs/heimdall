#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strings"

// Linux packaging: stage a /usr tree (binary + .desktop + icon) once, then emit
// both a `.deb` (via dpkg-deb) and an `.rpm` (via rpmbuild). Called from
// cmd_bundle on Linux.
//
//   .deb — Depends defaults to the GTK4/WebKit runtime libs (override with
//          [bundle.linux].deb_depends); built with `dpkg-deb --root-owner-group`
//          (no fakeroot needed).
//   .rpm — Requires are auto-detected by rpmbuild from the ELF's linked .so's
//          (override with [bundle.linux].rpm_requires).
bundle_linux :: proc(p: Project) {
	app_id := p.bundle_id if strings.trim_space(p.bundle_id) != "" else p.name
	display := p.display_name if p.display_name != "" else p.name
	summary := p.summary if p.summary != "" else display
	description := p.description if p.description != "" else summary

	deb_arch, rpm_arch := pkg_arch()

	// Stage the install tree under a fresh temp dir.
	root := fmt.tprintf("/tmp/heimdall-bundle-%s", p.name)
	_ = run_capture({"rm", "-rf", root})
	bin_dir := fmt.tprintf("%s/usr/bin", root)
	apps_dir := fmt.tprintf("%s/usr/share/applications", root)
	if !run_capture({"mkdir", "-p", bin_dir}).ok || !run_capture({"mkdir", "-p", apps_dir}).ok {
		fmt.eprintln("heimdall bundle: failed to stage package tree")
		os.exit(1)
	}

	// Executable.
	if !run_capture({"cp", p.name, fmt.tprintf("%s/%s", bin_dir, p.name)}).ok {
		fmt.eprintln("heimdall bundle: failed to copy executable")
		os.exit(1)
	}

	// .desktop entry.
	desktop_path := fmt.tprintf("%s/%s.desktop", apps_dir, app_id)
	if os.write_entire_file(desktop_path, transmute([]u8)desktop_entry(p, display, summary)) != nil {
		fmt.eprintln("heimdall bundle: failed to write .desktop file")
		os.exit(1)
	}

	// Icon (optional, .png only on Linux) → hicolor 256x256.
	icon_rel := "" // path under the package root, for %files
	if p.bundle_icon != "" {
		if !strings.has_suffix(p.bundle_icon, ".png") {
			fmt.eprintfln("heimdall bundle: Linux icon must be a .png (got %q), skipping", p.bundle_icon)
		} else if !file_exists(p.bundle_icon) {
			fmt.eprintfln("heimdall bundle: icon %q not found, skipping", p.bundle_icon)
		} else {
			icon_dir := fmt.tprintf("%s/usr/share/icons/hicolor/512x512/apps", root)
			_ = run_capture({"mkdir", "-p", icon_dir})
			if run_capture({"cp", p.bundle_icon, fmt.tprintf("%s/%s.png", icon_dir, app_id)}).ok {
				icon_rel = fmt.tprintf("/usr/share/icons/hicolor/512x512/apps/%s.png", app_id)
			}
		}
	}

	ok_deb := build_deb(p, root, deb_arch)
	ok_rpm := build_rpm(p, root, rpm_arch, app_id, summary, description, icon_rel)

	if !ok_deb && !ok_rpm {
		os.exit(1)
	}
}

@(private = "file")
pkg_arch :: proc() -> (deb: string, rpm: string) {
	when ODIN_ARCH == .arm64 {
		return "arm64", "aarch64"
	} else {
		return "amd64", "x86_64"
	}
}

// freedesktop .desktop entry. Categories come from [bundle.linux].category (a
// freedesktop list like "Utility;Development;"); defaults to "Utility;".
@(private = "file")
desktop_entry :: proc(p: Project, display, summary: string) -> string {
	cats := p.category if p.category != "" else "Utility;"
	if !strings.has_suffix(cats, ";") {
		cats = strings.concatenate({cats, ";"}, context.temp_allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "[Desktop Entry]")
	fmt.sbprintln(&b, "Type=Application")
	fmt.sbprintfln(&b, "Name=%s", display)
	fmt.sbprintfln(&b, "Comment=%s", summary)
	// `%u` passes a deep-link URL as argv when launched via x-scheme-handler.
	if len(p.schemes) > 0 {
		fmt.sbprintfln(&b, "Exec=%s %%u", p.name)
	} else {
		fmt.sbprintfln(&b, "Exec=%s", p.name)
	}
	fmt.sbprintfln(&b, "Icon=%s", p.bundle_id if p.bundle_id != "" else p.name)
	fmt.sbprintln(&b, "Terminal=false")
	fmt.sbprintfln(&b, "Categories=%s", cats)
	// Deep linking: declare the URL schemes this app handles so the desktop
	// environment routes myapp://… here. (update-desktop-database, run by the
	// package's post-install, builds the scheme->app map.)
	if len(p.schemes) > 0 {
		strings.write_string(&b, "MimeType=")
		for s in p.schemes {
			fmt.sbprintf(&b, "x-scheme-handler/%s;", s)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Default DEB Depends — the GTK4 + libadwaita + WebKit runtime (Debian/Ubuntu
// package names). Override with [bundle.linux].deb_depends if they differ on your
// target. (RPM auto-detects these from the ELF, so it needs no equivalent.)
@(private = "file")
DEB_DEPENDS_DEFAULT :: "libwebkitgtk-6.0-4, libadwaita-1-0, libgtk-4-1"

@(private = "file")
build_deb :: proc(p: Project, root: string, arch: string) -> bool {
	if !has_exe("dpkg-deb") {
		fmt.eprintln("heimdall bundle: dpkg-deb not found, skipping .deb (install the `dpkg` package)")
		return false
	}
	depends := p.deb_depends if p.deb_depends != "" else DEB_DEPENDS_DEFAULT
	maint := p.maintainer if p.maintainer != "" else "Unknown <unknown@example.com>"

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "Package: %s", p.name)
	fmt.sbprintfln(&b, "Version: %s", p.version)
	fmt.sbprintfln(&b, "Architecture: %s", arch)
	fmt.sbprintfln(&b, "Maintainer: %s", maint)
	fmt.sbprintln(&b, "Priority: optional")
	fmt.sbprintln(&b, "Section: utils")
	fmt.sbprintfln(&b, "Depends: %s", depends)
	if p.homepage != "" {
		fmt.sbprintfln(&b, "Homepage: %s", p.homepage)
	}
	// Synopsis line + indented extended description.
	summary := p.summary if p.summary != "" else (p.display_name if p.display_name != "" else p.name)
	fmt.sbprintfln(&b, "Description: %s", summary)
	if p.description != "" {
		for line in strings.split_lines(p.description) {
			if strings.trim_space(line) == "" {
				fmt.sbprintln(&b, " .")
			} else {
				fmt.sbprintfln(&b, " %s", line)
			}
		}
	}

	debian_dir := fmt.tprintf("%s/DEBIAN", root)
	_ = run_capture({"mkdir", "-p", debian_dir})
	if os.write_entire_file(fmt.tprintf("%s/control", debian_dir), transmute([]u8)strings.to_string(b)) != nil {
		fmt.eprintln("heimdall bundle: failed to write DEBIAN/control")
		return false
	}

	out := fmt.tprintf("%s_%s_%s.deb", p.name, p.version, arch)
	r := run_capture({"dpkg-deb", "--root-owner-group", "--build", root, out})
	if !r.ok {
		fmt.eprintfln("heimdall bundle: dpkg-deb failed:\n%s%s", r.out, r.err)
		return false
	}
	// dpkg-deb re-reads DEBIAN as the control archive; remove it so it doesn't end
	// up in the rpm payload.
	_ = run_capture({"rm", "-rf", debian_dir})
	fmt.printfln("heimdall bundle: done -> ./%s", out)
	return true
}

@(private = "file")
build_rpm :: proc(p: Project, root, arch, app_id, summary, description, icon_rel: string) -> bool {
	if !has_exe("rpmbuild") {
		fmt.eprintln("heimdall bundle: rpmbuild not found, skipping .rpm (install `rpm-build`/`rpmdevtools`)")
		return false
	}
	topdir := fmt.tprintf("/tmp/heimdall-rpm-%s", p.name)
	_ = run_capture({"rm", "-rf", topdir})
	for d in ([?]string{"BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS"}) {
		_ = run_capture({"mkdir", "-p", fmt.tprintf("%s/%s", topdir, d)})
	}

	license := p.license if p.license != "" else "Unknown"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "%global debug_package %{nil}") // no -debuginfo subpackage
	fmt.sbprintfln(&b, "Name: %s", p.name)
	fmt.sbprintfln(&b, "Version: %s", p.version)
	fmt.sbprintln(&b, "Release: 1")
	fmt.sbprintfln(&b, "Summary: %s", summary)
	fmt.sbprintfln(&b, "License: %s", license)
	fmt.sbprintfln(&b, "BuildArch: %s", arch)
	if p.homepage != "" {
		fmt.sbprintfln(&b, "URL: %s", p.homepage)
	}
	if p.rpm_requires != "" {
		fmt.sbprintfln(&b, "Requires: %s", p.rpm_requires)
	}
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "%description")
	fmt.sbprintln(&b, description)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "%install")
	fmt.sbprintln(&b, "mkdir -p %{buildroot}")
	// Built with write_string (not sbprintf) because Odin's fmt treats both '%'
	// and '{' as format tokens — and this line needs the literal %{buildroot}.
	strings.write_string(&b, "cp -a ")
	strings.write_string(&b, root)
	strings.write_string(&b, "/usr %{buildroot}/\n\n")
	fmt.sbprintln(&b, "%files")
	fmt.sbprintfln(&b, "/usr/bin/%s", p.name)
	fmt.sbprintfln(&b, "/usr/share/applications/%s.desktop", app_id)
	if icon_rel != "" {
		fmt.sbprintln(&b, icon_rel)
	}

	spec := fmt.tprintf("%s/SPECS/%s.spec", topdir, p.name)
	if os.write_entire_file(spec, transmute([]u8)strings.to_string(b)) != nil {
		fmt.eprintln("heimdall bundle: failed to write rpm spec")
		return false
	}

	r := run_capture({"rpmbuild", "-bb", "--define", fmt.tprintf("_topdir %s", topdir), spec})
	if !r.ok {
		fmt.eprintfln("heimdall bundle: rpmbuild failed:\n%s%s", r.out, r.err)
		return false
	}

	built := fmt.tprintf("%s/RPMS/%s/%s-%s-1.%s.rpm", topdir, arch, p.name, p.version, arch)
	out := fmt.tprintf("%s-%s-1.%s.rpm", p.name, p.version, arch)
	if !run_capture({"cp", built, out}).ok {
		fmt.eprintfln("heimdall bundle: rpm built but not found at %s", built)
		return false
	}
	fmt.printfln("heimdall bundle: done -> ./%s", out)
	return true
}
