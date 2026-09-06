#!/bin/bash
# The guide in README.md, run in order. Run it as yourself, not as root: it
# asks for sudo where it needs it, and two things (makepkg, the WirePlumber
# drop-in in your home) must not run as root.
#
# It is safe to run again. Anything already in place is left alone.
#
#   ./install.sh              install; ends by asking for a reboot
#   ./install.sh --verify     after the reboot: the checks from step 9
#   ./install.sh --dry-run    print what would be done
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DRY=0; VERIFY=0
for a in "$@"; do case $a in
    --dry-run) DRY=1 ;;
    --verify)  VERIFY=1 ;;
    *) sed -n '2,10p' "$0"; exit 2 ;;
esac; done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mok\033[0m    %s\n' "$1"; }
skip() { printf '    --    %s\n' "$1"; }
warn() { printf '    \033[33mwarn\033[0m  %s\n' "$1"; }
die()  { printf '    \033[31mfail\033[0m  %s\n' "$1" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '    would: %s\n' "$*"; else "$@"; fi; }
root() { run sudo "$@"; }
done_(){ [ "$DRY" = 1 ] || ok "$1"; }   # "ok" for an action, silent in a dry run

# inst <repo path> <destination> [mode]  — as root, only if different
inst() {
    local src="$HERE/$1" dst="$2" mode="${3:-0644}"
    [ -f "$src" ] || die "missing from this checkout: $1"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then skip "$dst unchanged"; return 1; fi
    root install -D -m "$mode" "$src" "$dst" && done_ "$dst"
}
CHANGED=0
KREL=$(uname -r)
DKMS=$(dkms status 2>/dev/null || true)   # read once: grep -q on a pipe trips pipefail
sensor_bound() { media-ctl -d /dev/media0 -p 2>/dev/null | grep -q '^- entity.*ov08x40'; }

# ---------------------------------------------------------------- verify --
verify() {
    say "Verify"
    local fail=0 n
    n=$(media-ctl -d /dev/media0 -p 2>/dev/null | grep -cE '^- entity.*(ov08x40|hm1092)' || true)
    [ "$n" = 2 ] && ok "both sensors in the media graph" || { warn "sensors in media graph: $n of 2"; fail=1; }
    ls /sys/class/leds 2>/dev/null | grep -q ir_flood && ok "IR illuminator registered" || warn "no ir_flood LED"
    [ -e /dev/video33 ] && [ "$(cat /sys/devices/virtual/video4linux/video33/name 2>/dev/null)" = "IPU7 Webcam" ] \
        && ok "/dev/video33 is 'IPU7 Webcam'" || { warn "/dev/video33 missing or misnamed"; fail=1; }
    [ "$(stat -c %a /dev/video0 2>/dev/null)" = 600 ] && ok "raw nodes hidden (video0 is 0600)" || warn "raw nodes still readable"
    systemctl is-active --quiet v4l2-relayd@ipu7 && ok "relay running" || { warn "v4l2-relayd@ipu7 not active"; fail=1; }
    wpctl get-volume @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 && ok "default audio sink present" || { warn "no default audio sink — step 4"; fail=1; }
    local sd g
    sd=$(grep -l '^ov08x40' /sys/class/video4linux/v4l-subdev*/name 2>/dev/null | head -1)
    if [ -n "$sd" ]; then
        g=$(v4l2-ctl -d "/dev/$(basename "$(dirname "$sd")")" --get-ctrl=analogue_gain 2>/dev/null | awk '{print $2}')
        [ "$g" = 600 ] && ok "analogue gain pinned at 600" || warn "analogue gain is '$g', expected 600"
    fi
    if [ "$fail" = 0 ]; then
        if fuser /dev/video33 >/dev/null 2>&1; then
            skip "stream test skipped: something already has /dev/video33 open"
        else
            printf '    streaming 300 frames...'
            local t0 t1
            t0=$(date +%s.%N)
            if timeout 60 v4l2-ctl -d /dev/video33 --stream-mmap --stream-count=300 --stream-to=/dev/null >/dev/null 2>&1; then
                t1=$(date +%s.%N); printf '\r'
                ok "stream test: $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f fps over %.1f s (start-up included)", 300/(b-a), b-a}')"
            else printf '\r'; warn "stream test produced no frames"; fail=1; fi
        fi
    fi
    [ "$fail" = 0 ] && say "All good. Open 'IPU7 Webcam' in any application." || { say "Finished with problems — see 'When it does not work' in README.md"; exit 1; }
}
[ "$VERIFY" = 1 ] && { verify; exit; }

# ------------------------------------------------------------- preflight --
say "Preflight"
[ "$(id -u)" != 0 ] || die "run this as yourself, not as root or with sudo"
lsusb 2>/dev/null | grep -q '06cb:0701' || die "no Synaptics SVP7500 (USB 06cb:0701) — this is not that hardware"
[ -d /sys/bus/acpi/devices/OVTI08F4:00 ]  || die "no OVTI08F4 in ACPI — different sensor, this guide does not apply"
lspci -n 2>/dev/null | grep -q '8086:b05d'  || warn "IPU7 8086:b05d not found; only tested there"
ok "hardware matches"
[ -d "/lib/modules/$KREL/build" ] || die "no kernel headers for $KREL — install linux-cachyos-headers (or your kernel's) first"
ok "kernel headers for $KREL"
if grep -q '^CONFIG_CC_IS_CLANG=y' "/lib/modules/$KREL/build/.config" 2>/dev/null; then
    for t in clang lld llvm-ar; do command -v $t >/dev/null || die "kernel is clang-built but $t is missing — install clang lld llvm"; done
    ok "clang toolchain for a clang kernel"
fi
for k in /lib/modules/*/; do k=$(basename "$k"); [ "$k" = "$KREL" ] && continue
    [ -d "/lib/modules/$k/build" ] || warn "no headers for $k — DKMS will skip it; the camera will not work when booting that kernel"; done
[ "$DRY" = 1 ] || { sudo -v || die "need sudo"; }

# ------------------------------------------------------------ 1 packages --
say "1. Packages"
PKGS=(dkms libcamera libcamera-tools pipewire-libcamera gst-plugin-libcamera)
if pacman -Q "${PKGS[@]}" >/dev/null 2>&1; then skip "all present"
else root pacman -Syu --needed "${PKGS[@]}"; done_ "installed"; fi

# ------------------------------------------------------ 2 kernel drivers --
say "2. Kernel drivers (jibsta210/svp7500-camera-fix-pack)"
need=0
for m in hm1092 intel-cvs ipu-bridge-patched; do
    grep -q "^$m/.*, $KREL, .*installed" <<<"$DKMS" || need=1
done
if [ "$need" = 0 ]; then skip "hm1092, intel-cvs, ipu-bridge-patched already installed for $KREL"
elif [ "$DRY" = 1 ]; then
    printf '    would: git clone https://github.com/jibsta210/svp7500-camera-fix-pack /tmp/svp7500\n'
    printf '    would: sudo /tmp/svp7500/install.sh --kernel-only\n'
else
    FP=${FIXPACK:-/tmp/svp7500}
    if [ -x "$FP/install.sh" ]; then skip "using existing checkout $FP"
    else git clone https://github.com/jibsta210/svp7500-camera-fix-pack "$FP"; fi
    ok "fix pack at $(git -C "$FP" log --oneline -1)"
    "$FP/tools/check-hardware.sh" || die "the fix pack says this is not its hardware"
    # It exits non-zero when int3472-patched cannot build on some kernel. That
    # module is not needed on 7.1+ (see README, step 2); judge by what landed.
    sudo "$FP/install.sh" --kernel-only || true
    DKMS=$(dkms status 2>/dev/null || true)
    for m in hm1092 intel-cvs ipu-bridge-patched; do
        grep -q "^$m/.*, $KREL, .*installed" <<<"$DKMS" || die "$m did not install for $KREL — read the fix pack output above"
    done
    done_ "modules installed for $KREL"
fi
if grep -q '^int3472-patched/' <<<"$DKMS"; then
    root dkms remove int3472-patched/1.0 --all
    root rm -rf /usr/src/int3472-patched-1.0
    done_ "int3472-patched dropped (unneeded on this kernel, unbuildable on 6.18)"
else skip "int3472-patched not registered"; fi

# ----------------------------------------------------- 4 audio (early) ---
say "4. Keep WirePlumber's default sink (user drop-in, no sudo)"
DST="$HOME/.config/wireplumber/wireplumber.conf.d/99-video-capture-optional.conf"
SRC="$HERE/home/.config/wireplumber/wireplumber.conf.d/99-video-capture-optional.conf"
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then skip "$DST unchanged"
else run install -D -m 0644 "$SRC" "$DST"; done_ "$DST"; run systemctl --user restart wireplumber; fi

# ------------------------------------------------------- 5 loopback -------
say "5. Virtual webcam"
inst etc/modprobe.d/v4l2loopback.conf     /etc/modprobe.d/v4l2loopback.conf     && CHANGED=1 || true
inst etc/modules-load.d/v4l2loopback.conf /etc/modules-load.d/v4l2loopback.conf || true
if [ -e /dev/video33 ]; then skip "/dev/video33 present"
else
    [ -d /sys/module/v4l2loopback ] && root modprobe -r v4l2loopback
    root modprobe v4l2loopback; done_ "v4l2loopback loaded"
fi

# ------------------------------------------------------- 6 raw nodes ------
say "6. Hide the raw sensor nodes"
if inst etc/udev/rules.d/99-ipu7-hide-raw-nodes.rules /etc/udev/rules.d/99-ipu7-hide-raw-nodes.rules; then
    root udevadm control --reload-rules
    root udevadm trigger --subsystem-match=video4linux
fi

# ------------------------------------------------------- 7 tuning ---------
say "7. Exposure and colour"
inst etc/libcamera/ipa/simple/ov08x40.yaml /etc/libcamera/ipa/simple/ov08x40.yaml || true
inst bin/ipu7-set-gain /usr/local/bin/ipu7-set-gain 0755 || true

# ------------------------------------------------------- 8 relay ----------
say "8. The relay"
if pacman -Q v4l2-relayd >/dev/null 2>&1; then skip "v4l2-relayd $(pacman -Q v4l2-relayd | cut -d' ' -f2) installed"
elif [ "$DRY" = 1 ]; then printf '    would: build v4l2-relayd from the AUR and install it\n'
else
    command -v makepkg >/dev/null || die "makepkg missing — install base-devel"
    B=$(mktemp -d); git clone -q https://aur.archlinux.org/v4l2-relayd.git "$B"
    ( cd "$B" && makepkg -d --nocheck )
    sudo pacman -U --noconfirm --assume-installed v4l2loopback-dkms "$B"/v4l2-relayd-*.pkg.tar.zst
    rm -rf "$B"; done_ "v4l2-relayd built and installed"
fi
inst etc/v4l2-relayd.d/ipu7.conf /etc/v4l2-relayd.d/ipu7.conf && CHANGED=1 || true
inst etc/systemd/system/v4l2-relayd@.service.d/override.conf /etc/systemd/system/v4l2-relayd@.service.d/override.conf && CHANGED=1 || true
root systemctl daemon-reload
if sensor_bound; then
    if systemctl is-active --quiet v4l2-relayd@ipu7 && [ "$CHANGED" = 0 ]; then skip "relay already running"
    else root systemctl enable --now v4l2-relayd.service; root systemctl restart v4l2-relayd.service; done_ "relay enabled and (re)started"; fi
else
    # Not started now: ExecStartPost pins the sensor gain, and there is no
    # sensor until the drivers from step 2 have been through a boot.
    root systemctl enable v4l2-relayd.service; done_ "relay enabled for next boot"
fi

# ------------------------------------------------------------- finish -----
[ "$DRY" = 1 ] && { say "Dry run complete"; exit 0; }
if sensor_bound; then verify
else
    say "Reboot now"
    echo "    The kernel drivers only bind on a fresh boot. Afterwards:"
    echo "        $0 --verify"
fi
