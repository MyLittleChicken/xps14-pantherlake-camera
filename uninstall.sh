#!/bin/bash
# Put everything back. Run as yourself; sudo is asked for where needed.
#
#   ./uninstall.sh                remove this guide's files and the kernel drivers
#   ./uninstall.sh --keep-kernel  leave the fix pack's DKMS modules and files alone
#   ./uninstall.sh --purge        also remove the packages step 1 and 8 installed
#   ./uninstall.sh --dry-run      print what would be done
set -Eeuo pipefail
DRY=0; KEEP_KERNEL=0; PURGE=0
for a in "$@"; do case $a in
    --dry-run) DRY=1 ;; --keep-kernel) KEEP_KERNEL=1 ;; --purge) PURGE=1 ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
esac; done
say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mok\033[0m    %s\n' "$1"; }
skip() { printf '    --    %s\n' "$1"; }
warn() { printf '    \033[33mwarn\033[0m  %s\n' "$1"; }
run()  { if [ "$DRY" = 1 ]; then printf '    would: %s\n' "$*"; else "$@"; fi; }
root() { run sudo "$@"; }
done_(){ [ "$DRY" = 1 ] || ok "$1"; }
del()  { # del <path> [--user]
    [ -e "$1" ] || { skip "$1 not present"; return 0; }
    if [ "$DRY" = 1 ]; then printf '    would: rm %s\n' "$1"
    elif [ "${2:-}" = --user ]; then rm -f "$1"; ok "removed $1"
    else sudo rm -f "$1"; ok "removed $1"; fi
}
[ "$(id -u)" != 0 ] || { echo "run this as yourself, not as root" >&2; exit 1; }
[ "$DRY" = 1 ] || sudo -v
DKMS=$(dkms status 2>/dev/null || true)

say "Relay"
if systemctl is-enabled --quiet v4l2-relayd.service 2>/dev/null || systemctl is-active --quiet v4l2-relayd.service; then
    root systemctl disable --now v4l2-relayd.service; done_ "relay stopped and disabled"
else skip "relay not enabled"; fi
del /etc/v4l2-relayd.d/ipu7.conf
del /etc/systemd/system/v4l2-relayd@.service.d/override.conf
[ "$DRY" = 1 ] || sudo rmdir --ignore-fail-on-non-empty /etc/systemd/system/v4l2-relayd@.service.d /etc/v4l2-relayd.d 2>/dev/null || true
root systemctl daemon-reload

say "Tuning, gain, raw nodes, loopback"
del /etc/libcamera/ipa/simple/ov08x40.yaml
del /usr/local/bin/ipu7-set-gain
del /etc/udev/rules.d/99-ipu7-hide-raw-nodes.rules
root udevadm control --reload-rules
# logind grants the uaccess ACL on "add", not "change"; a change event would
# leave the raw nodes root-only even with the rule gone.
root udevadm trigger --action=add --subsystem-match=video4linux
del /etc/modprobe.d/v4l2loopback.conf
del /etc/modules-load.d/v4l2loopback.conf
if [ -d /sys/module/v4l2loopback ]; then root modprobe -r v4l2loopback || warn "v4l2loopback busy; gone after reboot"; fi

say "WirePlumber"
del "$HOME/.config/wireplumber/wireplumber.conf.d/99-video-capture-optional.conf" --user
if [ "$KEEP_KERNEL" = 1 ]; then
    warn "the fix pack's 50-disable-v4l2-ipu7.conf stays; expect the step-4 audio loss on next boot"
else
    for f in 50-disable-v4l2-ipu7.conf 51-libcamera-pause-on-idle.conf 52-libcamera-longer-timeout.conf; do
        del /usr/share/wireplumber/wireplumber.conf.d/$f; done
fi
run systemctl --user restart wireplumber

if [ "$KEEP_KERNEL" = 0 ]; then
    say "Kernel drivers (fix pack)"
    for m in hm1092 intel-cvs ipu-bridge-patched ov05c10 int3472-patched; do
        if grep -q "^$m/" <<<"$DKMS"; then root dkms remove "$m/1.0" --all; root rm -rf "/usr/src/$m-1.0"; done_ "dkms $m removed"
        else skip "dkms $m not registered"; fi
    done
    del /etc/modprobe.d/99-ipu7-usbio-order.conf
    del /etc/udev/rules.d/99-svp7500-no-autosuspend.rules
    del /etc/udev/rules.d/99-hm1092-ir-led.rules
    say "Initramfs"
    # Not redirected: on CachyOS with Limine, mkinitcpio asks a question.
    if   command -v limine-mkinitcpio >/dev/null; then root limine-mkinitcpio
    elif command -v mkinitcpio        >/dev/null; then root mkinitcpio -P
    elif command -v dracut            >/dev/null; then root dracut --regenerate-all --force
    else warn "no initramfs tool found — regenerate it yourself before rebooting"; fi
fi

if [ "$PURGE" = 1 ]; then
    say "Packages"
    root pacman -Rns --noconfirm v4l2-relayd || true
    root pacman -Rns gst-plugin-libcamera pipewire-libcamera libcamera-tools libcamera dkms \
        || warn "some packages are needed by others and were left; fine"
fi

[ "$DRY" = 1 ] && { say "Dry run complete"; exit 0; }
say "Done — reboot to finish"
[ "$KEEP_KERNEL" = 1 ] && echo "    (kernel drivers kept; the sensor still binds, applications just cannot reach it)"
echo "    Restarting WirePlumber just now may have paused audio and video in a"
echo "    running browser for a moment; it reconnects on its own or on reload."
echo "    Check sound after the reboot:  wpctl get-volume @DEFAULT_AUDIO_SINK@"
