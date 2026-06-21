#!/bin/sh
# Heimdall installer (macOS + Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/galaxoid-labs/heimdall/main/install.sh | sh
#
# Installs into ~/.heimdall:
#   ~/.heimdall/bin/heimdall   the CLI (prebuilt, downloaded from GitHub Releases)
#   ~/.heimdall/heimdall/      the framework source (so `heimdall new` finds it)
#   ~/.heimdall/env            sourced by your shell to set PATH + HEIMDALL_HOME
#
# Env knobs:
#   HEIMDALL_VERSION=v0.1.0     install a specific release (default: latest)
#   HEIMDALL_HOME=/custom/path  install location (default: $HOME/.heimdall)
#   HEIMDALL_NO_MODIFY_PATH=1   don't touch shell profiles
#   HEIMDALL_YES=1              non-interactive (assume yes); also auto when piped
#   HEIMDALL_SKIP_VERIFY=1      skip SHA256 verification of downloads (not recommended)
#   HEIMDALL_ALLOW_ROOT=1       allow running as root (containers/CI; normally refused)
set -eu

REPO="galaxoid-labs/heimdall"
: "${HEIMDALL_HOME:=$HOME/.heimdall}"
: "${HEIMDALL_VERSION:=latest}"

# --- pretty output ---------------------------------------------------------
if [ -t 1 ]; then BOLD=$(printf '\033[1m'); BLUE=$(printf '\033[34m'); GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m'); DIM=$(printf '\033[2m'); RST=$(printf '\033[0m'); else BOLD=; BLUE=; GREEN=; RED=; DIM=; RST=; fi
say()  { printf '%s\n' "${BLUE}heimdall${RST} $*"; }
ok()   { printf '%s\n' "  ${GREEN}✓${RST} $*"; }
warn() { printf '%s\n' "  ${RED}!${RST} $*" >&2; }
die()  { printf '%s\n' "${RED}heimdall: $*${RST}" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

# --- detect platform -------------------------------------------------------
os=$(uname -s)
case "$os" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS '$os' (this script covers macOS + Linux; use install.ps1 on Windows)" ;;
esac

arch=$(uname -m)
case "$arch" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) die "unsupported architecture '$arch'" ;;
esac

# --- refuse to run as root -------------------------------------------------
# Heimdall installs per-user into ~/.heimdall — root is neither needed nor
# wanted. Under sudo, files land root-owned and $HOME may point at root's home,
# which silently breaks the later write to your shell profile. Escape hatch for
# containers / CI where everything is root by design.
if [ "$(id -u)" = 0 ] && [ "${HEIMDALL_ALLOW_ROOT:-0}" != 1 ]; then
  warn "this is a per-user install — it doesn't need sudo or root."
  warn "running as root writes root-owned files into $HOME and may target the wrong home."
  die  "re-run without sudo (or set HEIMDALL_ALLOW_ROOT=1 to override)"
fi

# --- downloader ------------------------------------------------------------
if need curl; then DL="curl -fsSL -o"; DLO="curl -fsSL"; elif need wget; then DL="wget -qO"; DLO="wget -qO-"; else die "need curl or wget"; fi

fetch() { # fetch <url> <dest>
  if [ "${DL%% *}" = curl ]; then curl -fSL --progress-bar -o "$2" "$1" || die "download failed: $1"
  else wget -O "$2" "$1" || die "download failed: $1"; fi
}

# --- integrity -------------------------------------------------------------
sha256_of() { # sha256_of <file> -> hex
  if need sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif need shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else die "no sha256sum/shasum to verify downloads (set HEIMDALL_SKIP_VERIFY=1 to bypass — not recommended)"; fi
}

verify() { # verify <file> <asset_name> <sumsfile>
  _want=$(awk -v f="$2" '$2 == f {print $1}' "$3")
  [ -n "$_want" ] || die "no checksum listed for $2 in SHA256SUMS"
  _got=$(sha256_of "$1")
  [ "$_want" = "$_got" ] || die "checksum mismatch for $2 (expected $_want, got $_got)"
}

# HEIMDALL_BASE_URL overrides where assets are fetched from (mirrors / testing).
if [ -n "${HEIMDALL_BASE_URL:-}" ]; then
  BASE="$HEIMDALL_BASE_URL"
elif [ "$HEIMDALL_VERSION" = latest ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  BASE="https://github.com/$REPO/releases/download/$HEIMDALL_VERSION"
fi

CLI_ASSET="heimdall-${OS}-${ARCH}"
FRAMEWORK_ASSET="heimdall-framework.tar.gz"

# --- plan + confirm --------------------------------------------------------
say "${BOLD}installer${RST}"
printf '%s\n' "  platform   ${BOLD}${OS}/${ARCH}${RST}"
printf '%s\n' "  version    ${BOLD}${HEIMDALL_VERSION}${RST}"
printf '%s\n' "  into       ${BOLD}${HEIMDALL_HOME}${RST}"
printf '%s\n' "  source     ${DIM}github.com/${REPO}${RST}"
echo

interactive=0
[ -t 0 ] && [ "${HEIMDALL_YES:-0}" != 1 ] && interactive=1
if [ "$interactive" = 1 ]; then
  printf '%s' "Proceed? [Y/n] "
  read ans </dev/tty || ans=y
  case "$ans" in n*|N*) die "aborted" ;; esac
fi

# --- install ---------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Download checksums first and verify each asset against them (skip only if the
# user explicitly opts out — not recommended).
verify_downloads=1
[ "${HEIMDALL_SKIP_VERIFY:-0}" = 1 ] && verify_downloads=0
if [ "$verify_downloads" = 1 ]; then
  fetch "$BASE/SHA256SUMS" "$tmp/SHA256SUMS"
else
  warn "skipping download verification (HEIMDALL_SKIP_VERIFY=1)"
fi

say "downloading CLI ($CLI_ASSET)…"
fetch "$BASE/$CLI_ASSET" "$tmp/$CLI_ASSET"
if [ "$verify_downloads" = 1 ]; then
  verify "$tmp/$CLI_ASSET" "$CLI_ASSET" "$tmp/SHA256SUMS"
  ok "verified $CLI_ASSET"
fi
mkdir -p "$HEIMDALL_HOME/bin"
mv "$tmp/$CLI_ASSET" "$HEIMDALL_HOME/bin/heimdall"
chmod +x "$HEIMDALL_HOME/bin/heimdall"
ok "CLI -> $HEIMDALL_HOME/bin/heimdall"

say "downloading framework ($FRAMEWORK_ASSET)…"
fetch "$BASE/$FRAMEWORK_ASSET" "$tmp/$FRAMEWORK_ASSET"
if [ "$verify_downloads" = 1 ]; then
  verify "$tmp/$FRAMEWORK_ASSET" "$FRAMEWORK_ASSET" "$tmp/SHA256SUMS"
  ok "verified $FRAMEWORK_ASSET"
fi
rm -rf "$HEIMDALL_HOME/heimdall"
tar -xzf "$tmp/$FRAMEWORK_ASSET" -C "$HEIMDALL_HOME"
[ -d "$HEIMDALL_HOME/heimdall" ] || die "framework archive did not contain a 'heimdall/' directory"
ok "framework -> $HEIMDALL_HOME/heimdall"

# --- env file + PATH -------------------------------------------------------
cat > "$HEIMDALL_HOME/env" <<EOF
# heimdall environment. Added by install.sh.
export HEIMDALL_HOME="$HEIMDALL_HOME"
case ":\$PATH:" in
  *":$HEIMDALL_HOME/bin:"*) ;;
  *) export PATH="$HEIMDALL_HOME/bin:\$PATH" ;;
esac
EOF
ok "env -> $HEIMDALL_HOME/env"

added_to=""
manual_rc=""
if [ "${HEIMDALL_NO_MODIFY_PATH:-0}" != 1 ]; then
  line=". \"$HEIMDALL_HOME/env\""
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -e "$rc" ] || continue
    if grep -qF "$HEIMDALL_HOME/env" "$rc" 2>/dev/null; then continue; fi  # already wired up
    # Check writability up front: attempting the append on an unwritable profile
    # (e.g. one owned by root) makes the shell print a raw "Permission denied" for
    # the redirection itself — which `2>/dev/null` can't suppress — so test first.
    if [ -w "$rc" ] && printf '\n%s\n' "$line" >> "$rc" 2>/dev/null; then
      added_to="$added_to $rc"
    else
      manual_rc="$manual_rc $rc"
    fi
  done
  # If no rc existed at all, seed one.
  if [ -z "$added_to$manual_rc" ] && [ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.bashrc" ] && [ ! -e "$HOME/.profile" ]; then
    if printf '%s\n' "$line" >> "$HOME/.profile" 2>/dev/null; then added_to=" $HOME/.profile"; else manual_rc=" $HOME/.profile"; fi
  fi
  [ -n "$added_to" ] && ok "PATH set via:$added_to"
  if [ -n "$manual_rc" ]; then
    warn "couldn't write to:$manual_rc — likely owned by another user (check: ls -la$manual_rc)."
    warn "add this line to your shell profile by hand, then restart your shell:"
    printf '%s\n' "      $line" >&2
  fi
fi

# --- done ------------------------------------------------------------------
echo
say "${GREEN}installed.${RST} $("$HEIMDALL_HOME/bin/heimdall" version 2>/dev/null || echo 'heimdall ?')"
echo
if [ -n "$added_to" ]; then
  printf '%s\n' "Open a new terminal (or run ${BOLD}. \"$HEIMDALL_HOME/env\"${RST}), then:"
else
  printf '%s\n' "Add ${BOLD}$HEIMDALL_HOME/bin${RST} to your PATH and set ${BOLD}HEIMDALL_HOME=$HEIMDALL_HOME${RST}, then:"
fi
printf '%s\n' "  ${BOLD}heimdall doctor${RST}     check your toolchain (Odin + bun + platform webview)"
printf '%s\n' "  ${BOLD}heimdall new myapp${RST}  scaffold an app"
echo
printf '%s\n' "${DIM}heimdall builds apps with Odin and bun — install those too if 'doctor' flags them.${RST}"
