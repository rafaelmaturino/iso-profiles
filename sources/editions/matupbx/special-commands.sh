#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs from the repository root. The workflow invokes this with bash, so it
# does not inherit the step's -e: without this line a failed sed is invisible
# and a half-built profile gets committed.
set -euo pipefail

# --- Desktop: same graft as the kde edition ---------------------------------
# Packages-Desktop is the one list with no Manjaro base: Desktop-add IS the
# list. These four sections come verbatim from upstream -- this is where
# xorg-server and the printing stack arrive, so look here before concluding a
# package is missing from Desktop-add.
upstreamDesktop=manjaro-iso-profiles/manjaro/kde/Packages-Desktop
generatedDesktop=biglinux/matupbx/Packages-Desktop

sections=(
    "## Printing"
    "## Xorg Server and Graphics"
    "## Xorg Input Drivers"
    "## Misc"
)
sectionContents=()
for section in "${sections[@]}"; do
    content=$(sed -n "/^${section}[[:space:]]*$/,/^[[:space:]]*$/p" "$upstreamDesktop")
    if [[ -z "$content" ]]; then
        printf 'ERROR: missing section "%s" in %s\n' "$section" "$upstreamDesktop" >&2
        exit 1
    fi
    if [[ "$section" != "## Misc" ]] && ! grep -q '^[[:space:]]*[^#[:space:]]' <<< "$content"; then
        printf 'ERROR: no packages in section "%s" in %s\n' "$section" "$upstreamDesktop" >&2
        exit 1
    fi
    sectionContents+=("$content")
done
printf '%s\n\n' "${sectionContents[@]}" >> "$generatedDesktop"

# The void driver claims input devices and nothing uses it.
sed -i '/^xf86-input-void$/d' "$generatedDesktop"

# Same mhwd trims as kde: BigLinux KDE installs drivers with
# big-driver-manager-cli, not mhwd, and the offline repository drops what only
# mhwd's old configurations used.
sed -i "s/^disable_systemd_live=('/disable_systemd_live=('mhwd-live' /" biglinux/matupbx/profile.conf
grep -q "^disable_systemd_live=('mhwd-live'" biglinux/matupbx/profile.conf
grep -vE '(^|[[:space:]])(KERNEL-bbswitch|bumblebee|primus|lib32-primus|xf86-video-(intel|sisusb|voodoo|dummy))$' \
    biglinux/matupbx/Packages-Mhwd > biglinux/matupbx/Packages-Mhwd.new
mv biglinux/matupbx/Packages-Mhwd.new biglinux/matupbx/Packages-Mhwd

# --- MatuPBX runtime packages ----------------------------------------------
# The telephony stack is not in Manjaro/BigLinux repos (there is no asterisk
# package); apache/mariadb/php arrive here and /opt/matupbx/chroot-setup.sh
# compiles Asterisk 20 LTS inside the rootfs chroot during the image build.
cat >> biglinux/matupbx/Packages-Root <<'PACKAGES'
apache
php-apache
php-gd
php-odbc
unixodbc
mariadb
sox
PACKAGES

# --- Edition overlays -------------------------------------------------------
# make-profiles copies only sources/common/overlays; per-edition files are
# grafted onto the generated profile here. This has to happen BEFORE the
# branding seds below: they edit files this copy brings in (grub, theme art).
cp -a sources/editions/matupbx/overlays/root/. biglinux/matupbx/root-overlay/
if [[ -d sources/editions/matupbx/overlays/live ]]; then
    cp -a sources/editions/matupbx/overlays/live/. biglinux/matupbx/live-overlay/
fi
test -f biglinux/matupbx/root-overlay/opt/matupbx/chroot-setup.sh

# --- Branding ---------------------------------------------------------------
# GRUB distributor string.
if [[ -f biglinux/matupbx/root-overlay/etc/default/grub ]]; then
    sed -i '/GRUB_DISTRIBUTOR=/s/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="MatuPBX"/' \
        biglinux/matupbx/root-overlay/etc/default/grub
fi

# Live session identity (same pattern as xivastudio).
if [[ -f biglinux/matupbx/live-overlay/etc/sddm.conf ]]; then
    # Anchored: an unanchored /User=/ also matches RememberLastUser=.
    sed -i '/^User=/s/.*/User=matupbx/' biglinux/matupbx/live-overlay/etc/sddm.conf
fi
if [[ -f biglinux/matupbx/live-overlay/etc/lxdm/lxdm.conf ]]; then
    sed -i '/autologin=/s/autologin=.*/autologin=matupbx/' biglinux/matupbx/live-overlay/etc/lxdm/lxdm.conf
fi
sed -i '/hostname=/s/hostname=.*/hostname="matupbx"/' biglinux/matupbx/profile.conf
sed -i '/username=/s/username=.*/username="matupbx"/' biglinux/matupbx/profile.conf
sed -i '/password=/s/password=.*/password="matupbx"/' biglinux/matupbx/profile.conf
sed -i '/ExecStart=/s/biglinux/matupbx/' biglinux/matupbx/live-overlay/usr/lib/systemd/system/getty@.service 2>/dev/null || true

# Boot menu artwork: build-iso.sh repoints variable.cfg at <distro>-live/theme.txt,
# so the live menu loads biglinux-live even for this edition. The image has to
# be there before the theme references it.
theme_root=biglinux/matupbx/live-overlay/usr/share/grub/themes
if [[ -f "$theme_root/manjaro-live/theme.txt" ]]; then
    sed -i 's/file = "biglinux-grub.png"/file = "matupbx.png"/' "$theme_root/manjaro-live/theme.txt"
fi
if [[ -d "$theme_root/biglinux-live" ]]; then
    cp "$theme_root/manjaro-live/matupbx.png" "$theme_root/biglinux-live/matupbx.png"
    if [[ -f "$theme_root/biglinux-live/theme.txt" ]]; then
        sed -i 's/file = "biglinux-grub.png"/file = "matupbx.png"/' "$theme_root/biglinux-live/theme.txt"
    fi
fi

# --- Services: httpd, mariadb, asterisk, first-boot DB fallback -------------
sed -i "s/^enable_systemd=(/enable_systemd=('httpd' 'mariadb' 'asterisk' 'matupbx-init' /" \
    biglinux/matupbx/profile.conf
grep -q "^enable_systemd=(" biglinux/matupbx/profile.conf
if ! grep -q '^enable_systemd_live=' biglinux/matupbx/profile.conf; then
    echo "enable_systemd_live=('httpd' 'mariadb' 'asterisk' 'matupbx-init')" \
        >> biglinux/matupbx/profile.conf
fi
