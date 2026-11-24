#!/usr/bin/env bash
# setup-venus-apps.sh
#
# Installs Steam in the Android desktop Linux Terminal VM (Debian 13 "trixie"), using Venus
# (virtio-gpu Vulkan) graphics.
#
#   Intel devices (x86_64 VM):     Steam runs natively. It uses Debian's steam-installer from
#                                  contrib (https://wiki.debian.org/Steam).
#   Qualcomm devices (aarch64 VM): Steam runs under the FEX-Emu x86 emulator
#                                  (https://wiki.fex-emu.com/index.php/Steam).
#
# Before running this:
#   - Android build number CL3B.260622.301 or newer (Settings > About device > Build number).
#   - Terminal app: ⋮ > Settings > Advanced > Graphics Acceleration > "GPU-accelerated renderer"
#     > Restart Now.
#
# Usage (inside the Terminal, as the default user "droid"):
#   bash setup-venus-apps.sh
# Safe to re-run.

set -euo pipefail

# Everything runs inside main(), which is only called on the last line. That way bash reads the whole
# script before running any of it. This matters for "curl ... | bash": a command that reads stdin
# can't swallow the rest of the script, and a partial download doesn't run partway.
main() {

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    -h|--help)
      echo "Installs Steam with Venus GPU graphics in the Android desktop Linux Terminal."
      echo "Usage: bash setup-venus-apps.sh   (no options; safe to re-run)"
      exit 0 ;;
    *) die "Unknown option: $a" ;;
  esac
done

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user (droid), not root. It uses sudo where needed."
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || warn "Expected Debian 13 (trixie), found ${PRETTY_NAME:-unknown}."
ARCH="$(uname -m)"
case "$ARCH" in x86_64|aarch64) ;; *) die "Unsupported architecture: $ARCH" ;; esac
APT_GET=(sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold)

# --- 1. APT sources: contrib/non-free (for steam-installer) and trixie-backports (for Mesa) -------
say "Checking APT sources (contrib, non-free, trixie-backports)"
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
  sudo sed -i -E '/^Components:/{
    /[[:space:]]contrib([[:space:]]|$)/! s/$/ contrib/
    /[[:space:]]non-free([[:space:]]|$)/! s/$/ non-free/
    /non-free-firmware/! s/$/ non-free-firmware/
  }' /etc/apt/sources.list.d/debian.sources
fi
if ! grep -rqs 'trixie-backports' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  sudo tee /etc/apt/sources.list.d/trixie-backports.sources >/dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi
# Only Debian's Steam packages are used. Drop Valve's repo if an older steam.deb added it.
sudo rm -f /etc/apt/sources.list.d/steam-stable.list /etc/apt/sources.list.d/steam-beta.list

# --- 2. Graphics: Mesa with the Venus Vulkan driver ------------------------------------------------
say "Installing Mesa (Venus Vulkan driver) and the graphics test tools"
sudo apt-get update
"${APT_GET[@]}" install -t trixie-backports \
  mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 libegl-mesa0 vulkan-tools mesa-utils

venus_check() {  # $1: command prefix, $2: label
  local out drv dev
  out="$($1 "vulkaninfo --summary" 2>/dev/null || true)"
  drv="$(awk '/driverID/ {print $3; exit}' <<<"$out")"
  dev="$(awk -F'= ' '/deviceName/ {print $2; exit}' <<<"$out")"
  if [ "$drv" = DRIVER_ID_MESA_VENUS ]; then
    say "$2 Vulkan: Venus is active ($dev)"
  else
    warn "$2 Vulkan driver is '${drv:-none}', not Venus. In the Terminal app, set ⋮ > Settings >" \
         "Advanced > Graphics Acceleration to \"GPU-accelerated renderer\" and restart the Terminal."
  fi
}
venus_check "bash -c" "Native"

# --- 3. Steam ------------------------------------------------------------------------------------
install_steam_x86_64() {
  say "Enabling 32-bit (i386) packages"
  sudo dpkg --add-architecture i386
  sudo apt-get update
  say "Installing Steam (Debian contrib) and the 32-bit Mesa drivers"
  # -t trixie-backports keeps the 32-bit Mesa at the same version as the 64-bit backports Mesa.
  "${APT_GET[@]}" install -t trixie-backports \
    steam-installer mesa-vulkan-drivers libglx-mesa0:i386 mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386

  # Terminal shells have no D-Bus session bus, which Steam's runtime launcher needs.
  # /usr/local/bin comes before /usr/games in PATH, so "steam" picks up this wrapper.
  sudo tee /usr/local/bin/steam >/dev/null <<'EOF'
#!/bin/sh
# Start Steam (Debian's /usr/games/steam) with a D-Bus session bus.
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  exec dbus-run-session -- /usr/games/steam "$@"
fi
exec /usr/games/steam "$@"
EOF
  sudo chmod 0755 /usr/local/bin/steam
}

install_steam_aarch64() {
  # FEX-Emu runs x86/x86-64 Linux programs on arm64. Debian has no FEX package, so use the
  # FEX-Emu Ubuntu 24.04 (noble) PPA, which installs cleanly on trixie. Pick the build for this CPU.
  local feat FEXPKG
  feat=" $(grep -m1 '^Features' /proc/cpuinfo | cut -d: -f2) "
  has() { local f; for f in "$@"; do [[ "$feat" == *" $f "* ]] || return 1; done; }
  if has atomics asimdrdm crc32 dcpop fcma jscvt lrcpc paca pacg asimddp flagm ilrcpc uscat; then
    FEXPKG=fex-emu-armv8.4
  elif has atomics asimdrdm crc32 dcpop; then
    FEXPKG=fex-emu-armv8.2
  else
    FEXPKG=fex-emu-armv8.0
  fi

  say "Installing FEX-Emu ($FEXPKG) from the FEX-Emu PPA"
  sudo install -d -m 0755 /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/fex-emu.asc ]; then
    curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xEDB98BFE8A2310DC9C4A376E76DBFEBEA206F5AC' \
      | sudo tee /etc/apt/keyrings/fex-emu.asc >/dev/null
  fi
  echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/fex-emu.asc] https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu noble main' \
    | sudo tee /etc/apt/sources.list.d/fex-emu.list >/dev/null
  if dpkg -s steam-launcher >/dev/null 2>&1; then
    say "Removing Valve's steam-launcher (replaced by Debian's launcher under FEX; Steam data is kept)"
    "${APT_GET[@]}" remove steam-launcher
  fi
  sudo apt-get update
  "${APT_GET[@]}" install "$FEXPKG" erofs-utils erofsfuse

  local ROOTFS_NAME=Ubuntu_24_04
  local ROOTFS="$HOME/.local/share/fex-emu/RootFS/$ROOTFS_NAME"
  local FEXCFG="$HOME/.config/fex-emu/Config.json"
  # FEXRootFSFetcher says "set as default RootFS" but saves nothing if ~/.config/fex-emu
  # doesn't exist yet (the case on a fresh VM), so create it first.
  mkdir -p "$HOME/.config/fex-emu"
  if [ ! -d "$ROOTFS/usr" ]; then
    say "Downloading the FEX x86-64 RootFS (Ubuntu 24.04, about 850 MB)"
    FEXRootFSFetcher -y -x --distro-name=ubuntu --distro-version=24.04 --force-ui=tty </dev/null
  fi
  [ -d "$ROOTFS/usr" ] || die "FEX RootFS not found at $ROOTFS"
  rm -f "$ROOTFS.ero" "$ROOTFS.sqsh"   # the compressed image isn't needed once it's extracted
  if ! grep -qs '"RootFS"' "$FEXCFG"; then
    echo "{\"Config\":{\"RootFS\":\"$ROOTFS_NAME\"},\"ThunksDB\":{}}" > "$FEXCFG"
  fi
  [ "$(FEXBash -c 'uname -m' 2>/dev/null)" = x86_64 ] \
    || die "FEX can't run x86-64 programs (check $FEXCFG and $ROOTFS)"

  # FEX looks up paths in its RootFS before the real filesystem. Steam and Proton sometimes create
  # a mostly empty $ROOTFS/home/droid/.steam tree, which then hides the real ~/.steam. Steam then
  # fails with "pv-adverb: ... steamrt64/steam (No such file or directory)", and Proton games fail
  # with an lsteamclient assertion. Keep the real /home bind-mounted there, now and at every boot.
  say "Bind-mounting /home into the FEX RootFS"
  local FSTAB_LINE="/home $ROOTFS/home none bind,nofail 0 0"
  grep -qsF "$ROOTFS/home" /etc/fstab || echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload || true
  if ! mountpoint -q "$ROOTFS/home"; then
    if [ -e "$ROOTFS/home" ] && [ -n "$(ls -A "$ROOTFS/home" 2>/dev/null)" ]; then
      mv "$ROOTFS/home" "$HOME/fex-rootfs-stray-home.bak.$(date +%s)"
    fi
    mkdir -p "$ROOTFS/home"
    sudo mount --bind /home "$ROOTFS/home"
  fi

  say "Unpacking Debian's steam-installer (amd64, contrib) into the FEX RootFS"
  # Use a private APT state, so the system doesn't need amd64 added as a foreign architecture.
  local T; T="$(mktemp -d)"
  mkdir -p "$T/sources" "$T/lists/partial" "$T/cache/archives/partial"
  : > "$T/status"
  cat > "$T/sources/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  local APTO=(-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$T/sources"
        -o Dir::State::Lists="$T/lists" -o Dir::State::status="$T/status" -o Dir::Cache="$T/cache"
        -o APT::Architecture=amd64 -o APT::Architectures::=amd64 -o Debug::NoLocking=1)
  apt-get "${APTO[@]}" -qq update
  (cd "$T" && apt-get "${APTO[@]}" -qq download steam-installer)
  # The RootFS home is now the real /home; extract only the launcher (it lives under /usr).
  dpkg-deb -x "$T"/steam-installer_*_amd64.deb "$T/x"
  cp -a "$T/x/usr/." "$ROOTFS/usr/"
  rm -rf "$T"

  sudo tee /usr/local/bin/steam-fex >/dev/null <<'EOF'
#!/bin/sh
# Start Steam under FEX-Emu. The Steam window opens in the Terminal's display view.
# STEAMOS/STEAM_RUNTIME skip Steam's glibc check (https://wiki.fex-emu.com/index.php/Steam).
ROOTFS="$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04"
# Keep the real /home visible inside the FEX RootFS (see setup-venus-apps.sh / /etc/fstab).
if [ -d "$ROOTFS/usr" ] && ! mountpoint -q "$ROOTFS/home"; then
  if [ -e "$ROOTFS/home" ] || [ -L "$ROOTFS/home" ]; then
    mv "$ROOTFS/home" "$HOME/fex-rootfs-stray-home.bak.$(date +%s)"
  fi
  mkdir -p "$ROOTFS/home" && sudo mount --bind /home "$ROOTFS/home"
fi
export STEAMOS=1 STEAM_RUNTIME=1
# Steam's runtime launcher needs a D-Bus session bus, which Terminal shells don't have.
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  exec dbus-run-session -- FEXBash -c '/usr/games/steam "$@"' steam "$@"
fi
exec FEXBash -c '/usr/games/steam "$@"' steam "$@"
EOF
  sudo chmod 0755 /usr/local/bin/steam-fex
  # Same command on both architectures.
  sudo ln -sf steam-fex /usr/local/bin/steam

  venus_check "FEXBash -c" "x86-64 (FEX)"
}

"install_steam_$ARCH"

# --- 4. Done -------------------------------------------------------------------------------------
say "Done"
echo
echo "Start Steam with:   steam"
echo
echo "The Steam window opens in the Terminal's display view: tap the monitor icon next to ⋮ in the"
echo "toolbar. On the first run, click \"Install\" in the \"Steam installer\" dialog. Steam then"
echo "downloads its client (about 1 GB) and shows the sign-in window."
if [ "$ARCH" = aarch64 ]; then
  echo "On Qualcomm devices Steam runs under FEX, so the first start takes several minutes."
fi
}

main "$@"
