#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MatuPBX rootfs setup — runs INSIDE the image chroot during the ISO build,
# invoked by build-iso.sh's mkiso_build_iso_cleanups hook (see that file for
# why the hook exists). Idempotent: the marker makes the second and third
# image (desktopfs/livefs) a no-op when they inherit this rootfs.
#
# What it does, in order:
#   1. installs the runtime stack (apache/php/mariadb) if missing
#   2. deploys the MatuPBX application from GitHub
#   3. builds mariadb-connector-odbc (not packaged for Arch)
#   4. builds Asterisk 20 LTS with ODBC voicemail storage
#   5. installs the SNEP/MatuPBX Asterisk configuration and sounds
#   6. bakes the database (schema + seed) so first boot needs no import
#   7. wires httpd, permissions and shared groups
set -euo pipefail

MARKER=/var/lib/matupbx-chroot-done
if [[ -f "$MARKER" ]]; then
    exit 0
fi

log() { echo "[MATUPBX] $*"; }
die() { echo "[MATUPBX] FATAL: $*" >&2; exit 1; }

# Robust download inside the build chroot: DNS/TLS can be flaky right after
# pacman, and a silent `wget -q` failure is impossible to diagnose. Prefer
# curl (follows GitHub 302 to codeload), fall back to wget, retry a few times.
fetch() {
    local url="$1" out="$2" i
    for i in 1 2 3 4 5; do
        log "download attempt $i: $url"
        if curl -fsSL --connect-timeout 20 --max-time 600 --retry 2 -o "$out" "$url"; then
            [[ -s "$out" ]] || { log "curl wrote empty file"; continue; }
            log "downloaded $(wc -c <"$out") bytes -> $out"
            return 0
        fi
        log "curl failed (exit $?)"
        if command -v wget >/dev/null 2>&1; then
            if wget -O "$out" "$url"; then
                [[ -s "$out" ]] || { log "wget wrote empty file"; continue; }
                log "downloaded via wget $(wc -c <"$out") bytes -> $out"
                return 0
            fi
            log "wget failed (exit $?)"
        fi
        # Show why: DNS? TLS? empty resolv.conf?
        log "diag: resolv.conf=$(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
        log "diag: getent github.com -> $(getent hosts github.com 2>/dev/null | head -1)"
        sleep $((i * 2))
    done
    return 1
}

APP_URL="${MATUPBX_TARBALL_URL:-https://github.com/rafaelmaturino/matupbx/archive/refs/heads/main.tar.gz}"
AST_VERSION="${MATUPBX_ASTERISK_VER:-20.22.0}"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${AST_VERSION}.tar.gz"
ODBC_ODBC_VERSION="${MATUPBX_ODBC_ODBC_VER:-3.2.10}"
ODBC_ODBC_URL="https://github.com/mariadb-corporation/mariadb-connector-odbc/archive/refs/tags/${ODBC_ODBC_VERSION}.tar.gz"

APP=/var/www/html/matupbx
DBDIR=$APP/install/database

# --- 0. network sanity for the chroot ---------------------------------------
# manjaro-tools usually bind-mounts resolv.conf; if it's missing/broken every
# HTTPS fetch dies instantly while pacman (mirrorlist) may still have worked.
if [[ ! -s /etc/resolv.conf ]] || ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    log "fixing /etc/resolv.conf for chroot DNS"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi

# pacman needs /etc/mtab to resolve mount points for free-space checks before
# committing a transaction. A symlink to /proc is wrong here: after chroot the
# host mount table still uses host paths, so /var/cache/pacman/pkg never
# matches ("could not determine cachedir mount point"). An empty file fails
# with "could not determine filesystem mount points". Write a synthetic
# single-entry mtab that treats the chroot root as one filesystem.
if [[ -L /etc/mtab || ! -e /etc/mtab ]] || ! grep -q ' / ' /etc/mtab 2>/dev/null; then
    log "writing synthetic /etc/mtab for pacman"
    rm -f /etc/mtab
    root_src=$(df -P / 2>/dev/null | awk 'NR==2{print $1}')
    root_fstype=$(stat -f -c %T / 2>/dev/null || echo rootfs)
    printf '%s / %s rw,relatime 0 0\n' "${root_src:-/dev/root}" "${root_fstype:-rootfs}" > /etc/mtab
fi

# --- 1. runtime packages ----------------------------------------------------
log "installing runtime packages"
pacman -S --noconfirm --needed \
    apache php-apache php-gd php-odbc unixodbc mariadb sox wget curl ca-certificates

# --- 2. deploy the application ---------------------------------------------
log "deploying MatuPBX application from $APP_URL"
mkdir -p /var/www/html
rm -rf /tmp/matupbx-app "$APP"
mkdir -p /tmp/matupbx-app
fetch "$APP_URL" /tmp/matupbx.tar.gz || die "cannot download MatuPBX tarball"
tar -xzf /tmp/matupbx.tar.gz -C /tmp/matupbx-app --strip-components=1 \
    || die "cannot extract MatuPBX tarball"
mv /tmp/matupbx-app "$APP"
rm -f /tmp/matupbx.tar.gz

mkdir -p /var/log/matupbx
touch /var/log/matupbx/ui.log /var/log/matupbx/agi.log
ln -sfn /var/log/matupbx "$APP/logs"
chmod +x "$APP"/agi/* 2>/dev/null || true

# --- 3. build tools (removed again at the end) ------------------------------
log "installing build dependencies"
pacman -S --noconfirm --needed \
    base-devel cmake \
    mariadb-connector-c libltdl \
    jansson libedit ncurses sqlite libxslt openssl \
    libogg libvorbis speex opus libsrtp

# --- 4. mariadb-connector-odbc ---------------------------------------------
# No mariadb/mysql ODBC driver ships in the Arch/Manjaro/BigLinux repos, and
# voicemail ODBC_STORAGE needs one. Build the official connector from source.
if [[ ! -e /usr/lib/libmariadbodbc.so ]]; then
    log "building mariadb-connector-odbc $ODBC_ODBC_VERSION"
    rm -rf /tmp/odbc-odbc
    # GitHub's source tarball omits git submodules (libmariadb, driver/cppmini);
    # cmake then dies with "No MariaDB Connector/C++ mini branch". Clone
    # recursively instead of downloading the archive.
    git clone --depth 1 --branch "$ODBC_ODBC_VERSION" --recurse-submodules \
        --shallow-submodules \
        https://github.com/mariadb-corporation/mariadb-connector-odbc.git \
        /tmp/odbc-odbc \
        || die "cannot clone mariadb-connector-odbc"
    cmake -S /tmp/odbc-odbc -B /tmp/odbc-odbc/build \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
        >/tmp/odbc-cmake.log 2>&1 \
        || { tail -60 /tmp/odbc-cmake.log; die "odbc cmake configure failed"; }
    cmake --build /tmp/odbc-odbc/build -j"$(nproc)" \
        >/tmp/odbc-make.log 2>&1 \
        || { tail -60 /tmp/odbc-make.log; die "odbc cmake build failed"; }
    cmake --install /tmp/odbc-odbc/build \
        >/tmp/odbc-install.log 2>&1 \
        || { tail -60 /tmp/odbc-install.log; die "odbc cmake install failed"; }
    tail -30 /tmp/odbc-install.log
    ldconfig
    # Upstream installs the driver as libmaodbc.so (often under lib/mariadb/);
    # odbcinst.ini/odbc.ini expect /usr/lib/libmariadbodbc.so — link it there.
    so=$(find /usr/lib /usr/local/lib \( -name 'libmaodbc.so*' -o -name 'libmariadbodbc.so*' \) 2>/dev/null | head -1)
    if [[ -z "$so" ]]; then
        echo "--- odbc install log ---" >&2
        cat /tmp/odbc-install.log >&2 || true
        find /usr -name '*maodbc*' 2>/dev/null | head -30 >&2 || true
        die "maodbc/libmariadbodbc.so not found anywhere after install"
    fi
    log "linking $so -> /usr/lib/libmariadbodbc.so"
    ln -sfn "$so" /usr/lib/libmariadbodbc.so
    base=$(basename "$so")
    if [[ "$base" != libmariadbodbc.so && ! -e /usr/lib/libmaodbc.so ]]; then
        ln -sfn "$so" /usr/lib/libmaodbc.so
    fi
    ldconfig
    rm -rf /tmp/odbc-odbc
fi
[[ -e /usr/lib/libmariadbodbc.so ]] || die "libmariadbodbc.so missing after build"

# Strip autoconf config.status corruption seen only in this build chroot:
# stray `0a1,N` sed-append fragments and `> ` prefixed comment lines
# (including bare `>`). Host build of the same tarball is clean.
repair_config_status() {
    local f
    while IFS= read -r -d '' f; do
        if ! bash -n "$f" 2>/dev/null; then
            log "repairing $f"
            sed -i -E \
                -e '/^0a[0-9]+(,[0-9]+)?$/d' \
                -e '/^[[:space:]]*>[[:space:]]*$/d' \
                -e 's/^> (#)/\1/' \
                "$f"
            bash -n "$f" || { sed -n '520,580p' "$f" >&2; die "still corrupt: $f"; }
        fi
    done < <(find /tmp/asterisk -name config.status -type f -print0 2>/dev/null)
}

# --- 5. Asterisk ------------------------------------------------------------
if [[ ! -x /usr/sbin/asterisk ]]; then
    log "building Asterisk $AST_VERSION"
    rm -rf /tmp/asterisk
    mkdir -p /tmp/asterisk
    fetch "$AST_URL" /tmp/asterisk.tar.gz || die "cannot download Asterisk tarball"
    tar -xzf /tmp/asterisk.tar.gz -C /tmp/asterisk --strip-components=1
    cd /tmp/asterisk
    # chan_sip only (SNEP); bundled pjproject is for res_pjsip.
    # Shipped configure writes a corrupt config.status in this chroot
    # (`0a1,540`, literal `_ASBOX`). Host build of the same tarball is fine —
    # the chroot env (locale/shell opts/PATH) poisons generation. Run under
    # env -i with a minimal, explicit environment.
    export LANG=C LC_ALL=C
    export CONFIG_SHELL=/bin/bash SHELL=/bin/bash
    set +e
    set +u
    set +o pipefail

    # Keep a pristine copy of the shipped configure before any autoreconf.
    cp -a configure configure.shipped 2>/dev/null || true

    if [[ -f configure.ac ]]; then
        log "trying system autoconf on configure.ac"
        if autoconf >/tmp/asterisk-autoconf.log 2>&1; then
            log "autoconf regenerated configure"
        else
            log "autoconf failed; restoring shipped configure"
            tail -30 /tmp/asterisk-autoconf.log || true
            if [[ -f configure.shipped ]]; then
                mv -f configure.shipped configure
            fi
        fi
    fi

    log "running configure under env -i"
    set +e
    env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/tmp \
        TERM=dumb \
        LANG=C LC_ALL=C \
        CONFIG_SHELL=/bin/bash \
        SHELL=/bin/bash \
        /bin/bash ./configure --with-odbc --with-pjproject=no \
        >/tmp/asterisk-configure.log 2>&1
    conf_rc=$?
    set -euo pipefail

    if [[ -f config.status ]]; then
        if ! bash -n config.status 2>/dev/null; then
            log "repairing corrupt config.status (conf_rc=$conf_rc)"
            repair_config_status
            bash -n config.status \
                || { sed -n '520,580p' config.status >&2; die "config.status still corrupt after repair"; }
            log "config.status repaired"
        fi
        /bin/bash config.status >/tmp/asterisk-config-status.log 2>&1 \
            || { tail -40 /tmp/asterisk-config-status.log; die "config.status execution failed"; }
    else
        tail -60 /tmp/asterisk-configure.log
        die "asterisk configure failed (no config.status, rc=$conf_rc)"
    fi
    if [[ ! -f makeopts ]]; then
        tail -60 /tmp/asterisk-configure.log
        die "asterisk configure did not produce makeopts (rc=$conf_rc)"
    fi

    # menuselect ships its own configure; it also writes a corrupt
    # config.status in this chroot. Pre-run it with repair so the
    # menuselect/makeopts rule finds a fresh file and skips re-configure.
    if [[ -x menuselect/configure ]]; then
        log "pre-configuring menuselect"
        (
            cd menuselect
            set +e
            env -i \
                PATH=/usr/sbin:/usr/bin:/sbin:/bin \
                HOME=/tmp TERM=dumb LANG=C LC_ALL=C \
                CONFIG_SHELL=/bin/bash SHELL=/bin/bash \
                /bin/bash ./configure >/tmp/asterisk-menuselect-conf.log 2>&1
            true
        )
        repair_config_status
        if [[ -f menuselect/config.status ]]; then
            /bin/bash menuselect/config.status >/tmp/asterisk-menuselect-cs.log 2>&1 \
                || { tail -40 /tmp/asterisk-menuselect-cs.log; die "menuselect config.status failed"; }
        fi
        [[ -f menuselect/makeopts ]] || die "menuselect/makeopts missing after pre-configure"
        log "menuselect pre-configured"
    fi

    # Build the menuselect tool first (uses menuselect/makeopts).
    make menuselect/menuselect >/tmp/asterisk-menuselect-bin.log 2>&1 \
        || { tail -40 /tmp/asterisk-menuselect-bin.log; die "building menuselect failed"; }

    # SNEP stores voicemail in MySQL through ODBC (see voicemail.conf).
    # Category MENUSELECT_OPTS_app_voicemail is positive_output: listing
    # ODBC_STORAGE there means "build with ODBC voicemail storage".
    if [[ -x menuselect/menuselect ]]; then
        menuselect/menuselect --enable ODBC_STORAGE menuselect.makeopts \
            || die "menuselect --enable ODBC_STORAGE failed"
    elif [[ -f menuselect.makeopts ]]; then
        if grep -q '^MENUSELECT_OPTS_app_voicemail=' menuselect.makeopts; then
            sed -i 's/^MENUSELECT_OPTS_app_voicemail=.*/MENUSELECT_OPTS_app_voicemail=ODBC_STORAGE/' menuselect.makeopts
        else
            echo 'MENUSELECT_OPTS_app_voicemail=ODBC_STORAGE' >> menuselect.makeopts
        fi
    fi
    make -j"$(nproc)" >/tmp/asterisk-make.log 2>&1 \
        || { tail -60 /tmp/asterisk-make.log; die "asterisk make failed"; }
    make install >/tmp/asterisk-install.log 2>&1 \
        || { tail -40 /tmp/asterisk-install.log; die "asterisk make install failed"; }
    # systemd unit from the source tree (no `make config`: sysv-only).
    if [[ -f contrib/systemd/asterisk.service ]]; then
        install -Dm644 contrib/systemd/asterisk.service /etc/systemd/system/asterisk.service
    fi
    rm -rf /tmp/asterisk /tmp/asterisk.tar.gz
fi
[[ -x /usr/sbin/asterisk ]] || die "asterisk binary missing after build"

# Runtime user for the systemd unit.
id -u asterisk >/dev/null 2>&1 || \
    useradd -r -M -s /usr/bin/nologin -d /var/lib/asterisk -g asterisk asterisk 2>/dev/null || \
    useradd -r -M -s /usr/bin/nologin -d /var/lib/asterisk asterisk
getent group asterisk >/dev/null || groupadd -r asterisk

# --- 6. SNEP/MatuPBX Asterisk configuration + sounds ------------------------
log "installing MatuPBX Asterisk configuration"
rm -rf /etc/asterisk
cp -a "$APP/install/etc/asterisk" /etc/asterisk
cp "$APP/install/etc/odbc.ini" /etc/odbc.ini
# odbcinst.ini comes from the overlay (Arch driver path, not Debian's).

log "installing sounds"
for lang in en es pt_BR; do
    mkdir -p "/var/lib/asterisk/sounds/$lang"
done
tar -xzf "$APP/install/sounds/asterisk-core-sounds-en-wav-current.tar.gz" -C /var/lib/asterisk/sounds/en
tar -xzf "$APP/install/sounds/asterisk-extra-sounds-en-wav-current.tar.gz" -C /var/lib/asterisk/sounds/en
tar -xzf "$APP/install/sounds/asterisk-core-sounds-es-wav-current.tar.gz" -C /var/lib/asterisk/sounds/es
tar -xzf "$APP/install/sounds/asterisk-core-sounds-pt_BR-wav.tgz" -C /var/lib/asterisk/sounds/pt_BR
mkdir -p /var/lib/asterisk/moh/tmp /var/lib/asterisk/moh/backup

# Symlinks the SNEP install guide defines.
mkdir -p "$APP/sounds"
ln -sfn /var/lib/asterisk/moh "$APP/sounds/moh"
ln -sfn /var/lib/asterisk/sounds/pt_BR "$APP/sounds/pt_BR"
ln -sfn /var/www/html/matupbx/agi /var/lib/asterisk/agi-bin/snep
mkdir -p /var/spool/asterisk
ln -sfn /var/www/html/matupbx/arquivos /var/spool/asterisk/monitor

# --- 7. users and permissions ------------------------------------------------
# http (the web app) and asterisk share the recordings/sounds/config trees:
# the web UI writes Asterisk configs and sounds, Asterisk writes recordings.
id -u http >/dev/null 2>&1 || useradd -r -M -s /usr/bin/nologin http
usermod -aG asterisk http

chown -R http:http "$APP" /var/log/matupbx
chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
chmod -R g+rwX /var/lib/asterisk /var/spool/asterisk /etc/asterisk
# Recordings: setgid so files born here inherit the asterisk group.
mkdir -p "$APP/arquivos"
chown http:asterisk "$APP/arquivos"
chmod 2775 "$APP/arquivos"

# --- 8. bake the database ---------------------------------------------------
log "initializing MariaDB and importing schema"
if [[ ! -d /var/lib/mysql/mysql ]]; then
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql \
        --auth-root-authentication-method=normal >/var/log/matupbx/mysql-install.log 2>&1 \
        || die "mariadb-install-db failed"
fi
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
mariadbd --user=mysql --datadir=/var/lib/mysql --skip-networking \
    --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid \
    >/var/log/matupbx/mariadb-build.log 2>&1 &
MYSQL_PID=$!
for _ in $(seq 1 60); do
    mysqladmin --socket=/run/mysqld/mysqld.sock ping >/dev/null 2>&1 && break
    sleep 1
done
mysqladmin --socket=/run/mysqld/mysqld.sock ping >/dev/null 2>&1 \
    || die "mariadbd did not come up (see /var/log/matupbx/mariadb-build.log)"

mysql --socket=/run/mysqld/mysqld.sock < "$DBDIR/database.sql"
mysql --socket=/run/mysqld/mysqld.sock snep < "$DBDIR/schema.sql"
mysql --socket=/run/mysqld/mysqld.sock snep < "$DBDIR/system_data.sql"
mysql --socket=/run/mysqld/mysqld.sock snep < "$DBDIR/core-cnl.sql"
if [[ -f $APP/modules/billing/install/schema.sql ]]; then
    mysql --socket=/run/mysqld/mysqld.sock snep < "$APP/modules/billing/install/schema.sql"
fi
if [[ -f $APP/modules/loguser/install/schema.sql ]]; then
    mysql --socket=/run/mysqld/mysqld.sock snep < "$APP/modules/loguser/install/schema.sql"
fi
mysqladmin --socket=/run/mysqld/mysqld.sock shutdown
wait "$MYSQL_PID" 2>/dev/null || true

# --- 9. httpd ----------------------------------------------------------------
log "configuring Apache"
if ! grep -q 'Include conf/matupbx.conf' /etc/httpd/conf/httpd.conf; then
    echo 'Include conf/matupbx.conf' >> /etc/httpd/conf/httpd.conf
fi
if ! grep -q 'php_module\|php7_module' /etc/httpd/conf/httpd.conf; then
    if [[ -f /etc/httpd/conf/extra/php_module.conf ]]; then
        grep -q 'Include conf/extra/php_module.conf' /etc/httpd/conf/httpd.conf || \
            echo 'Include conf/extra/php_module.conf' >> /etc/httpd/conf/httpd.conf
    else
        {
            echo 'LoadModule php_module modules/libphp.so'
            echo '<FilesMatch "\.php$">'
            echo '    SetHandler application/x-httpd-php'
            echo '</FilesMatch>'
        } >> /etc/httpd/conf/httpd.conf
    fi
fi

# Identity for the installed system (calamares may still override it).
echo matupbx > /etc/hostname

# --- 10. drop build-only tools ---------------------------------------------
# Nothing runtime links against gcc/cmake; -Rdd skips dependency checks so a
# shared library some runtime package happens to need is never pulled out.
log "removing build-only tools"
pacman -Rdd --noconfirm gcc make cmake autoconf automake m4 patch pkgconf \
    >/dev/null 2>&1 || true

touch "$MARKER"
log "done"
