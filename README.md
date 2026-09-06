# Enabling the camera on a Dell XPS 14 (Panther Lake) running Linux

The built-in camera on this laptop gives you nothing on a stock system: the
device nodes exist, the sensor does not. This guide takes it from there to a
working webcam that browsers, Discord and Slack treat like any other.

It was written by doing it — wiping the machine back to stock and rebuilding,
recording each step as it actually ran rather than from memory.

## Where you are starting from

```
Laptop        Dell XPS 14 DA14260, BIOS 1.8.2
Kernel        7.2.2-1-cachyos
IPU           Intel IPU7, PCI 8086:b05d
Bridge        Synaptics SVP7500 CVS, USB 06cb:0701, ACPI INTC10E1
RGB sensor    OV08X40, ACPI OVTI08F4
IR sensor     HM1092, ACPI HIMX1092
```

Confirm you are on the same hardware before going further:

```bash
lsusb -d 06cb:0701                    # Synaptics SVP7500
ls -d /sys/bus/acpi/devices/OVTI08F4:00 /sys/bus/acpi/devices/INTC10E1:00
lspci -nn -s 00:05.0                  # [8086:b05d]
```

**How much of that has to match.** Two things are load-bearing: the Synaptics
bridge, because the drivers exist to reach through it, and the OV08X40 sensor,
because the tuning file, the gain script and the relay's input size are all
written for it. A different sensor means rewriting those three. Everything
else is softer: another IPU7 stepping will probably work, and the fix pack's
`ipu-bridge.c` carries the same sensor quirk for the XPS 16 (DA16260), so that
machine is likely to follow this guide unchanged — untested. The install script
enforces exactly the two hard conditions and warns about the rest. It is
Arch-only; the guide's reasoning is not.

The symptom, before anything is installed:

```
$ journalctl -k -b | grep -E 'Connected|sensor'
intel-ipu7 0000:00:05.0: Found supported sensor OVTI08F4:00
intel-ipu7 0000:00:05.0: Connected 1 cameras

$ media-ctl -d /dev/media0 -p | grep -cE '^- entity.*(ov08x40|hm1092)'
0

$ v4l2-ctl -d /dev/video1 --stream-mmap --stream-count=1
VIDIOC_STREAMON returned -1 (Link has been severed)
```

Thirty-two `/dev/video*` nodes, four CSI-2 receivers, and no sensor attached to
any of them. The firmware announces the sensor; nothing binds to it.

Why: the sensors are not on a native I2C controller. They sit behind the
Synaptics bridge, which tunnels I2C over a USB bulk interface. Until a driver
claims that bridge, the ACPI dependency chain is unsatisfied, no I2C client is
created, and the IPU has nothing to talk to.

## The short way

The steps below, in order, as a script:

```bash
git clone https://github.com/MyLittleChicken/xps14-pantherlake-camera
cd xps14-pantherlake-camera
./install.sh              # asks for sudo where it needs it; ends by asking for a reboot
./install.sh --verify     # after the reboot
```

`./uninstall.sh` puts everything back, kernel drivers included;
`--keep-kernel` leaves the drivers, `--purge` also removes the packages step 1
and step 8 installed. Both scripts take `--dry-run` and are safe to run
twice. They explain nothing; the rest of this page does.

Tested as a round trip on this machine: uninstall, reboot, install (52 s),
reboot, verify. Audio stayed up throughout, since the WirePlumber drop-in goes
in before the reboot that would otherwise take it down.

---

## Contents

| # | step | status |
|---|---|---|
| 1 | [Packages](#1-packages) | done |
| 2 | [Kernel drivers](#2-kernel-drivers) | done |
| 3 | [Reboot and check the kernel half](#3-reboot-and-check-the-kernel-half) | done |
| 4 | [Your sound just stopped — fix that first](#4-your-sound-just-stopped--fix-that-first) | done |
| 5 | [A virtual webcam applications can open](#5-a-virtual-webcam-applications-can-open) | done |
| 6 | [Keeping applications off the raw nodes](#6-keeping-applications-off-the-raw-nodes) | done |
| 7 | [Exposure and colour](#7-exposure-and-colour) | done |
| 8 | [The relay](#8-the-relay) | done |
| 9 | [Checking it works](#9-checking-it-works) | done |
| — | [Adjusting it afterwards](#adjusting-it-afterwards) | done |
| — | [When it does not work](#when-it-does-not-work) | done |
| — | [What this does not fix](#what-this-does-not-fix) | done |

---

## 1. Packages

```bash
sudo pacman -Syu --needed dkms libcamera libcamera-tools pipewire-libcamera gst-plugin-libcamera
```

`-Syu`, not `-S`: with a package database more than a few days old every
mirror answers 404 for these. `libcamera-ipa` comes in as a dependency; six
packages in total, about 6 MiB.

| package | why |
|---|---|
| `dkms` | the bridge and sensor drivers in step 2 are DKMS modules and will not build without it |
| `libcamera` | the only thing that can drive a MIPI sensor here. `libcamera-ipa` holds the signed image-processing modules |
| `libcamera-tools` | `cam`, used throughout this guide to check whether the sensor is alive |
| `pipewire-libcamera` | the SPA plugin PipeWire needs to reach libcamera. Not pulled in by `pipewire` itself |
| `gst-plugin-libcamera` | provides `libcamerasrc`, which step 7 builds its pipeline around |

### Two prerequisites that are easy to miss

**Kernel headers, for every kernel you boot.** DKMS builds against them, and
`dkms` only lists them as *optional* dependencies, so pacman will not stop you:

```bash
$ for k in $(ls /lib/modules/); do
    [ -d /lib/modules/$k/build ] && echo "$k ok" || echo "$k MISSING HEADERS"
  done
6.18.48-1-cachyos-lts ok
7.2.2-1-cachyos ok
```

Missing headers mean the modules silently do not get built for that kernel, and
the camera is dead the next time you boot it. On CachyOS install
`linux-cachyos-headers` (and `linux-cachyos-lts-headers` if you keep the LTS
kernel around).

**A compiler matching the kernel.** CachyOS builds its kernels with clang, and
clang refuses gcc's flags, so a mismatch is a build failure with the reason
buried in a DKMS log:

```bash
$ grep -q '^CONFIG_CC_IS_CLANG=y' /lib/modules/$(uname -r)/build/.config && echo clang
clang
$ command -v clang lld llvm-ar
```

Check afterwards that the tools are actually there:

```bash
$ command -v dkms cam v4l2-ctl && gst-inspect-1.0 libcamerasrc >/dev/null && echo "libcamerasrc ok"
/usr/bin/dkms
/usr/bin/cam
/usr/bin/v4l2-ctl
libcamerasrc ok
```

## 2. Kernel drivers

Nothing binds the sensors because nothing claims the Synaptics bridge. The
driver for it, `intel_cvs`, is not built by this distribution — so it has to
come from somewhere.

That somewhere is [jibsta210/svp7500-camera-fix-pack](https://github.com/jibsta210/svp7500-camera-fix-pack),
which packages the bridge driver, the IR sensor driver and a patched
`ipu-bridge` as DKMS modules. **This part is not my work.** There is no package
for it in any repository, so clone it:

```bash
git clone https://github.com/jibsta210/svp7500-camera-fix-pack /tmp/svp7500
cd /tmp/svp7500
git log --oneline -1        # note this; you will want it if you report a bug
```

`/tmp` because DKMS copies the sources into `/usr/src` during install, so the
checkout is disposable afterwards — the modules keep building on kernel upgrades
without it.

This guide was walked through against `5d40327`.

### Check it applies to your machine first

```bash
$ ./tools/check-hardware.sh
=== hardware check — 7.2.2-1-cachyos ===

  CVS bridge on USB            06cb:0701
  bridge ACPI id               INTC10E1
  sensors in firmware          HIMX1092 INT3472 OVTI08F4
  Intel imaging unit           0000:00:05.0 0xb05d
  IPU6 machine                 no
  USB (uvcvideo) webcam        none bound

APPLIES TO THIS MACHINE: yes — found a CVS bridge or its ACPI id, plus a sensor
the firmware declares
```

Read-only, no root, exits 0 when it applies and non-zero when it does not. If it
says no, stop — nothing in this guide will help, and the installer refuses to
run anyway.

### Install the modules

```bash
sudo ./install.sh --kernel-only --dry-run     # rehearsal, changes nothing
sudo ./install.sh --kernel-only
```

`--kernel-only` skips the pack's Howdy integration. IR face unlock is outside
the scope of this guide; the sensor still binds, so it can be added later.

### It will say FAILED. Read the summary, not the exit code.

On this kernel the run ends like this:

```
    modules installed : 4 / 5   (on every kernel that needs it)
    per kernel        :
        6.18.48-1-cachyos-lts  4 of 5 module(s)
        7.2.2-1-cachyos        4 of 4 module(s)   (+1 not needed on this kernel)   <- the kernel you are running now
    ✗ 1 required module(s) did not install: int3472-patched.

==> FAILED
```

The kernel you are about to boot got everything it needs. `int3472-patched` is
the exception, and it is an exception in both directions:

- **On 7.2.2 it is skipped on purpose.** The installer does not check the
  kernel version; `tools/int3472-needed.sh` looks inside the in-tree
  `intel_skl_int3472_discrete` module for the `ir_flood` string, finds it, and
  declares the patch unnecessary. The in-tree driver has registered that LED
  since kernel v7.1
  ([`0ec7f158dc01`](https://github.com/torvalds/linux/commit/0ec7f158dc01)).
  A skip on its own is harmless and does not affect the exit status.
- **On the 6.18 LTS kernel it fails to build**, because that kernel's
  `<linux/platform_data/x86/int3472.h>` predates the IR-LED support the module's
  sources expect. **This is where the `FAILED` comes from**: 6.18 needs the
  module and cannot build it. On this machine it builds nowhere.

The installer treats "a module missing on a kernel that needs it" as failure,
which is the right contract, but the practical result here is that **the LTS
kernel has no working camera and the one you are running does.**

Since `dkms.conf` sets `AUTOINSTALL="yes"`, leaving it registered means every
future kernel upgrade retries the build and fails, putting errors into every
`pacman -Syu`. Drop it:

```bash
sudo dkms remove int3472-patched/1.0 --all
sudo rm -rf /usr/src/int3472-patched-1.0
dkms status
```

That should leave four modules, each on both kernels:

```
hm1092/1.0, 6.18.48-1-cachyos-lts, x86_64: installed
hm1092/1.0, 7.2.2-1-cachyos, x86_64: installed
intel-cvs/1.0, ...
ipu-bridge-patched/1.0, ...   (Original modules exist)
ov05c10/1.0, ...
```

`ov05c10` is for a different board's sensor and is inert here; it is installed
because the pack ships it, not because this laptop needs it.

### What else the pack put in place

Not just modules. Six files, three of which matter later in this guide:

| file | why |
|---|---|
| `/etc/modprobe.d/99-ipu7-usbio-order.conf` | a `softdep` loading `usbio → gpio_usbio → i2c_usbio → intel_cvs → int3472` **before** `intel_ipu7`. Without it the IPU probes first, the USB bridge re-enumerates in a loop, and the sensors never settle |
| `/etc/udev/rules.d/99-svp7500-no-autosuspend.rules` | keeps USB autosuspend off the bridge |
| `/usr/share/wireplumber/wireplumber.conf.d/50-disable-v4l2-ipu7.conf` | hides the raw IPU7 nodes from PipeWire's V4L2 monitor. Remember this one — it is half of [step 4](#4-your-sound-just-stopped--fix-that-first) |
| `/usr/share/wireplumber/wireplumber.conf.d/51-libcamera-pause-on-idle.conf` | `node.pause-on-idle = true` for libcamera nodes |
| `/usr/share/wireplumber/wireplumber.conf.d/52-libcamera-longer-timeout.conf` | raises `monitor.camera-discovery-timeout` to 15 s. Also in the neighbourhood of step 4; not investigated |
| `/etc/udev/rules.d/99-hm1092-ir-led.rules` | makes the IR illuminator's `brightness` writable by the `video` group. Only matters for Howdy |

## 3. Reboot and check the kernel half

```bash
sudo systemctl reboot
```

Then:

```bash
$ journalctl -k -b | grep -oE 'Connected [0-9]+ cameras'
Connected 2 cameras

$ media-ctl -d /dev/media0 -p | grep -E '^- entity.*(ov08x40|hm1092)'
- entity 233: ov08x40 17-0036 (1 pad, 1 link, 0 routes)
- entity 247: hm1092 17-0024 (1 pad, 1 link, 0 routes)

$ ls /sys/class/leds/ | grep ir
HIMX1092_00::ir_flood_led
```

One camera became two, both sensors are in the media graph, and the IR
illuminator registered. The kernel half is done — everything after this is
userspace.

`cam -c 1 -C5` will now capture real frames. **Applications still see
nothing**, and that is expected: libcamera can drive the sensor, but browsers
and Electron apps only look for plain V4L2 devices.

## 4. Your sound just stopped — fix that first

If your default audio output has gone silent since the reboot, that is this
guide's doing, and it will not fix itself.

```bash
$ wpctl get-volume @DEFAULT_AUDIO_SINK@
Translate ID error: '-1' is not a valid ID (returned by default-nodes-api)
```

Every sink is still present and healthy. What is missing is the *default*.

**Trigger.** WirePlumber's stock `main` profile marks `hardware.video-capture`
as **required**, and both of its monitors now have zero devices: the pack's
`50-disable-v4l2-ipu7.conf` hides the raw IPU7 nodes from the V4L2 monitor, and
the libcamera monitor has nothing to offer until the relay in step 8 exists.

I can reproduce and repair this at will by flipping that one flag, so the
trigger is certain. **The mechanism is not.** `policy.standard`, which pulls in
`policy.default-nodes`, does not list `hardware.video-capture` among its
`requires` — the two are independent siblings in the profile — and the
WirePlumber log records no failure of any kind. Why an unsatisfiable `required`
feature should take default-node assignment with it, I have not established.

**Fix.** A user drop-in — *not* under `/etc`, and *not* with sudo:

```
wireplumber.profiles = {
  main = {
    hardware.video-capture = optional
  }
}
```

```bash
install -Dm644 home/.config/wireplumber/wireplumber.conf.d/99-video-capture-optional.conf \
    ~/.config/wireplumber/wireplumber.conf.d/99-video-capture-optional.conf
systemctl --user restart wireplumber
```

```bash
$ wpctl get-volume @DEFAULT_AUDIO_SINK@
Volume: 0.40
```

**Restart your browser afterwards.** Restarting WirePlumber orphans the audio
stream of anything already running; the stack is fine but Chrome will not
reconnect on its own, and video playback appears to hang.

This step is here, immediately after the reboot, because that is when it
happens — not at the end where it would have been tidier to write.

## 5. A virtual webcam applications can open

The sensor works. Nothing can use it:

```bash
$ cam -l
Available cameras:
1: Internal front camera (\_SB_.LNK1)
2: 'hm1092' (\_SB_.LNK0)

$ v4l2-ctl --list-devices
ipu7 (PCI:0000:00:05.0):
	/dev/video0
	/dev/video1
	...31 more
```

libcamera sees two cameras. V4L2 sees thirty-two nodes that carry raw Bayer and
cannot be decoded by anything. Browsers and Electron apps only speak V4L2, so
they find those thirty-two and none of them work.

The bridge is `v4l2loopback`: a kernel module that creates a fake webcam. One
end accepts frames, the other looks like an ordinary camera to any application.
Something has to push libcamera's output into it — that is [step 8](#8-the-relay).

On CachyOS the module is already in the kernel, so there is nothing to install:

```bash
$ modinfo -F filename v4l2loopback
/lib/modules/7.2.2-1-cachyos/kernel/drivers/media/v4l2-core/v4l2loopback.ko.zst
```

Elsewhere, install `v4l2loopback-dkms`.

### Configure it

`/etc/modprobe.d/v4l2loopback.conf`:

```
options v4l2loopback devices=1 video_nr=33 card_label="IPU7 Webcam" exclusive_caps=1 max_buffers=6
```

and `/etc/modules-load.d/v4l2loopback.conf` containing one line, `v4l2loopback`,
so it comes up at boot. That second file only acts at boot, so load it by hand
this once:

```bash
sudo install -Dm644 etc/modprobe.d/v4l2loopback.conf /etc/modprobe.d/v4l2loopback.conf
sudo install -Dm644 etc/modules-load.d/v4l2loopback.conf /etc/modules-load.d/v4l2loopback.conf
sudo modprobe v4l2loopback
cat /sys/devices/virtual/video4linux/video33/name
```

```
IPU7 Webcam
```

Every option here is load-bearing:

| option | why |
|---|---|
| `video_nr=33` | without it the module takes the first free number — `/dev/video0`, ahead of the IPU nodes. Pinning it high keeps the numbering stable and out of the way |
| `exclusive_caps=1` | without it the device advertises capture *and* output at once; with it, output-only until a producer starts streaming, then capture-only. The reason v4l2loopback's README gives is that browsers reject a device claiming both; I have not tested that, only that this setting works |
| `max_buffers=6` | the default of 2 lets a consumer read a buffer the producer is still writing — a tear across the middle of the picture |

One device, one resolution: a v4l2-relayd instance pins a single format, so a
second resolution means a second device and a second instance. If you want that,
`devices=2 video_nr=33,34 card_label="IPU7 Webcam 1080p,IPU7 Webcam 720p"` and a
second config in step 8 will do it — quote the whole label list **once**, because
`card_label="A","B"` leaves the quote marks inside the names and nothing that
looks them up later will match.

## 6. Keeping applications off the raw nodes

There are now 33 V4L2 nodes and exactly one of them is usable:

```bash
$ v4l2-ctl --list-devices | grep -c '/dev/video'
33
```

The other 32 are the IPU7 ISYS capture nodes. They carry raw Bayer that no
application can decode, but they advertise `V4L2_CAP_VIDEO_CAPTURE`, so
Chromium-based applications enumerate them as webcams — and open one:

```bash
$ ls -l /dev/video0
crw-rw----+ 1 root video 81, 0 /dev/video0     # readable by you
```

This is worse than a cluttered camera menu. `/dev/video0` is the node libcamera
itself needs to read the sensor. Whichever application grabs it first locks
libcamera out, and the working device goes black:

```
ERROR V4L2 v4l2_videodevice.cpp:1322 /dev/video0[19:cap]: Unable to request 4 buffers: Device or resource busy
$ fuser -v /dev/video0
/dev/video0:  you  46314  Discord
```

A browser may work anyway, purely by enumeration order picking a different node
first. That is luck, not design.

**Fix.** Hide them. `/etc/udev/rules.d/99-ipu7-hide-raw-nodes.rules`:

```udev
SUBSYSTEM=="video4linux", ATTR{name}=="Intel IPU7 ISYS Capture*", \
    TAG-="uaccess", GROUP="root", MODE="0600"
```

Matching on the entity name, not the number: `/dev/videoN` numbering shuffles
between boots, and `/dev/video33` is a v4l2loopback device whose name does not
match, so it is untouched.

Both halves are needed. `MODE="0600"` alone leaves logind's `uaccess` ACL
granting you access anyway; `TAG-="uaccess"` drops that grant. Afterwards
`getfacl` still lists your entry, but with `#effective:---` under `mask::---`:

```bash
$ sudo install -Dm644 etc/udev/rules.d/99-ipu7-hide-raw-nodes.rules \
      /etc/udev/rules.d/99-ipu7-hide-raw-nodes.rules
$ sudo udevadm control --reload-rules
$ sudo udevadm trigger --subsystem-match=video4linux
$ ls -l /dev/video0
crw-------+ 1 root root 81, 0 /dev/video0
```

Two consequences worth knowing:

- **An application already holding the node keeps it.** Permissions are checked
  at `open(2)`, so a descriptor opened before the rule survives. If a browser
  had one, restart it.
- **`cam`, `qcam` and other user-run libcamera tools now need `sudo`.** The
  relay reaches the sensor because it runs as root; you no longer do.

## 7. Exposure and colour

libcamera has no tuning file for this sensor, so it falls back to a generic one:

```
IPAProxy ipa_proxy.cpp:196 Configuration file 'ov08x40.yaml' not found for IPA module 'simple',
                           falling back to '/usr/share/libcamera/ipa/simple/uncalibrated.yaml'
```

```bash
$ ls /usr/share/libcamera/ipa/simple/
uncalibrated.yaml

$ grep -A6 algorithms /usr/share/libcamera/ipa/simple/uncalibrated.yaml
algorithms:
  - BlackLevel:
  - Awb:
  - Adjust:
  - Agc:
```

Two things follow from that list, and both are visible on screen.

**No `Ccm`.** The software ISP ships one — `nm -DC` on `ipa_soft_simple.so`
lists `algorithms::Ccm` — but `uncalibrated.yaml` leaves it out, which means an
identity matrix. The sensor's raw colour filter response is passed through as if
it were already sRGB. The picture looks washed out because no correction is
applied at all.

**`Agc` is present, and on a backlit desk it does the wrong thing.** It meters
on a mean sample value with no highlight protection, so a bright window behind
you reads as "too dark". It raises exposure to its ceiling, then drives analogue
gain to maximum — blowing out the background further, and taking per-pixel noise
from 1.78 to 3.26 (of 255) on the way. It would behave correctly under even lighting.

Nor can you steer it: there is no `ExposureValue`, `ExposureTimeMode` or
`AnalogueGainMode` handling in the software AGC. Setting `exposure-value`,
`ae-enable`, `exposure-time` or `analogue-gain` on `libcamerasrc` leaves the
sensor controls untouched, and writing them with `v4l2-ctl` while streaming gets
overwritten within seconds.

**Fix.** A per-sensor tuning file that drops `Agc` and enables `Ccm`. libcamera
searches `/etc/libcamera/ipa` before `/usr/share/libcamera/ipa`, so this needs
no environment variable and leaves the distribution's files alone:

```bash
sudo install -Dm644 etc/libcamera/ipa/simple/ov08x40.yaml \
    /etc/libcamera/ipa/simple/ov08x40.yaml
```

With `Agc` gone, nothing writes exposure or gain — so a value set before the
stream starts stays put. That is what `bin/ipu7-set-gain` is for:

```bash
sudo install -Dm755 bin/ipu7-set-gain /usr/local/bin/ipu7-set-gain
```

It resolves the sensor subdev by entity name, because `/dev/v4l-subdevN`
numbering shuffles between boots. Step 8 wires it into the relay unit so it is
applied on every start.

Gain is the only lever that does anything. Exposure can be shortened but not
lengthened past its default, and I do not know why — see [What this does not
fix](#what-this-does-not-fix).

The CCM is a generic daylight matrix, not a measurement for this sensor. Rows
sum to 1.0 so white stays white. It is visibly better than identity; hues are
approximate. A real matrix needs a colour chart.

## 8. The relay

Everything so far is scaffolding. Nothing has actually moved a frame from the
sensor to `/dev/video33` yet — this is the piece that does, and it is where the
choices made earlier come due.

### v4l2-relayd

[`v4l2-relayd`](https://gitlab.com/vicamo/v4l2-relayd) watches a v4l2loopback
device for the kernel's `CLIENT_USAGE` event and runs a GStreamer pipeline only
while something is reading it. That on-demand behaviour is the whole reason to
use it rather than leaving a pipeline running: idle costs nothing.

It is not in the official repositories:

```bash
git clone https://aur.archlinux.org/v4l2-relayd.git /tmp/v4l2-relayd
cd /tmp/v4l2-relayd
makepkg -d --nocheck
sudo pacman -U --assume-installed v4l2loopback-dkms v4l2-relayd-*.pkg.tar.zst
```

`-d` skips the dependency check and `--assume-installed v4l2loopback-dkms`
satisfies the one dependency that would otherwise drag in a DKMS build of
v4l2loopback — the CachyOS kernel already has it, and installing both would
leave two copies of the same module.

### The pipeline

One `*.conf` per loopback device in `/etc/v4l2-relayd.d/`. A systemd generator
turns each into a `v4l2-relayd@<name>.service`, and `CARD_LABEL` is how the unit
works out which `/dev/videoN` to write to.

`etc/v4l2-relayd.d/ipu7.conf`:

```
VIDEOSRC="libcamerasrc ! video/x-raw,width=3848,height=2176 ! queue max-size-buffers=3 ! videoconvert ! videobalance saturation=1.4 contrast=1.05 ! videoscale method=lanczos"
FORMAT=YUY2
WIDTH=1920
HEIGHT=1080
FRAMERATE=30/1
CARD_LABEL="IPU7 Webcam"
```

Two things about that `VIDEOSRC` are not stylistic.

**It must not end with a capsfilter.** Ending it
`... ! videoscale ! video/x-raw,format=YUY2,width=1920,height=1080` looks
reasonable and fails like this:

```
GST_PIPELINE grammar.y:665: gst_parse_element_make: no element "video"
GST_PIPELINE grammar.y:1385: link has no sink
GST_PIPELINE grammar.y:1458: no source element for URI "/x-raw,format=YUY2,width=1920,height=1080"
V4L2_RELAYD  v4l2-relayd.c:199: backend_pipeline_create: no element "video"
v4l2-relayd: gst_element_set_state: assertion 'GST_IS_ELEMENT (element)' failed
```

`gst_parse_launch` reads `A ! caps` as *link A through caps to the next
element*. With nothing after it the link has no sink, so the parser retries the
token as an element name and then as a URI. Both fail, the parse returns NULL,
and all that reaches the journal is the assertion. End the string with a real
element. The caps are redundant anyway — v4l2-relayd copies `FORMAT`, `WIDTH`
and `HEIGHT` onto its appsink from the output appsrc.

**The 3848x2176 input is forced, not chosen.** libcamera's software ISP crops to
produce a smaller output; it does not scale. Asking it for 1920x1080 from a
3856x2176 sensor returns a centred crop — a fraction of the field of view — so
the pipeline handler instead selects the smallest sensor mode at or above the
request, which is a binned mode, and that aborts:

```
$ cam -c 1 --stream width=1280,height=720 -C3
std::array<unsigned int, 64>::operator[]: Assertion '__n < this->size()' failed.
```

So the native frame comes out of libcamera and the scaling happens in GStreamer.
`lanczos` is chosen for sharpness. It was not compared against the default
bilinear filter for noise, and the comparison would probably favour bilinear —
averaging neighbours suppresses noise where lanczos preserves it along with the
detail.

### Two fixes to the packaged service

`etc/systemd/system/v4l2-relayd@.service.d/override.conf`:

```ini
[Service]
DeviceAllow=/dev/dma_heap/system rw
DeviceAllow=/dev/udmabuf rw

ExecStart=
ExecStart=/bin/sh -c 'DEVICE=$(grep -l -m1 -E "^${CARD_LABEL}$" /sys/devices/virtual/video4linux/*/name | cut -d/ -f6); exec /usr/bin/v4l2-relayd -i "${VIDEOSRC}" $${SPLASHSRC:+-s "${SPLASHSRC}"} -o "appsrc name=appsrc caps=video/x-raw,format=${FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE} ! videoconvert ! v4l2sink name=v4l2sink sync=false device=/dev/$${DEVICE}" $EXTRA_OPTS'

ExecStartPost=/usr/local/bin/ipu7-set-gain 600
```

**dma-buf.** The stock unit ships `DevicePolicy=closed` with a `DeviceAllow`
list of `char-drm`, `char-media`, `char-video4linux` and the IPU psys nodes.
libcamera's `DmaBufAllocator` wants `/dev/dma_heap/*` or `/dev/udmabuf`, neither
of which is on it, so the software ISP never initialises:

```
DmaBufAllocator dma_buf_allocator.cpp:119 Could not open any dma-buf provider
SoftwareIsp     software_isp.cpp:90      Failed to create DmaBufAllocator object
SimplePipeline  simple.cpp:620           Failed to create software ISP, disabling software debayering
                gstlibcamera-utils.cpp:369  Unsupported DRM format BA10
libcamerasrc    error: streaming stopped, reason not-negotiated (-4)
```

Black frames, and nothing in the log names the sandbox.
[libcamera documents](https://libcamera.org/faq.html) that the software ISP
needs these devices and that distributions usually do not grant them; a service
sandbox is another way to lose them.

This is the bill for [step 6](#6-keeping-applications-off-the-raw-nodes).
Hiding the raw nodes from unprivileged users means the relay has to be root,
which means it is the packaged system service, which means its sandbox is now
your problem. Leaving the nodes readable and running the relay as your own user
avoids all of this — at the cost of applications still being able to grab them.

**`sync=false`.** The output pipeline is `appsrc ! videoconvert ! v4l2sink`, and
`v4l2sink` synchronises to the clock by default. Buffers arriving through
`appsink → appsrc` carry timestamps it judges late, so it drops nearly all of
them:

```
basesink gstbasesink.c:3146: <v4l2sink> A lot of buffers are being dropped.
basesink gstbasesink.c:3146: <v4l2sink> There may be a timestamping problem, or this computer is too slow.
v4l2allocator gstv4l2allocator.c:1336: buffer 1 was not queued, this indicate a driver bug.
```

That last line is a consequence, not a cause. `gst_base_sink_is_too_late()`
emits both warnings and only runs when the sink is synchronising, so their
presence is the proof.

**`ExecStartPost`.** With `Agc` removed in [step 7](#7-exposure-and-colour),
nothing sets the sensor gain. Pinning it here re-applies it on every start,
since the value does not survive a reboot.

### Install and enable

```bash
sudo install -Dm644 etc/v4l2-relayd.d/ipu7.conf /etc/v4l2-relayd.d/ipu7.conf
sudo install -Dm644 etc/systemd/system/v4l2-relayd@.service.d/override.conf \
    /etc/systemd/system/v4l2-relayd@.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable --now v4l2-relayd.service
```

## 9. Checking it works

The relay is running but idle. Nothing is streaming until something opens the
device — that is the point of it:

```bash
$ systemctl status v4l2-relayd@ipu7 | grep Active
     Active: active (running)

$ ps -o %cpu= -p $(systemctl show -p MainPID --value v4l2-relayd@ipu7.service)
   0.0
```

Attach a consumer and it starts:

```bash
$ v4l2-ctl -d /dev/video33 --stream-mmap --stream-count=1500 --stream-to=/dev/null
<<<<< 28.57 fps
```

```
idle                CPU  0.0 %
streaming           CPU 92.8 %      1920x1080, 28.57 fps
consumer detaches   CPU  0.0 %
```

**Measure over a minute.** Start-up is under a second, but it is inside every
short run: ten frames come out at about 10 fps, two hundred at 26, fifteen
hundred at the 28.57 above.

Then open a real application. `IPU7 Webcam` should be in the camera list of any
browser, Discord or Slack. A brief black frame on opening is the pipeline
starting, not a hang.

Worth checking at the same time:

```bash
$ wpctl get-volume @DEFAULT_AUDIO_SINK@      # step 4 still holding
Volume: 0.40

$ v4l2-ctl -d /dev/v4l-subdev4 --get-ctrl=analogue_gain    # step 7 applied
analogue_gain: 600
```

The subdev number shuffles between boots — `ipu7-set-gain` resolves it by entity
name for exactly that reason, and so should you if you script anything against
it.

---

## Adjusting it afterwards

**Brightness** is the sensor's analogue gain, and it is live:

```bash
sudo ipu7-set-gain 750      # brighter
sudo ipu7-set-gain 450      # darker
```

Measured on `/dev/video33`, one static scene, twelve consecutive frames per
setting. `noise` is the median per-pixel standard deviation across those frames
— the same pixel over time, which isolates sensor noise from picture detail:

```
gain            brightness   noise   noise/brightness
 128 (1.0x)         58        1.78        3.4 %
 300 (2.3x)         78        2.19        3.0 %
 600 (4.7x)        102        2.57        2.8 %
1200 (9.4x)        132        2.76        2.1 %
1984 (15.5x)       154        3.26        2.1 %
```

Note the last column. **Lowering the gain does not give you a cleaner picture** —
it gives you a darker one with proportionally the same noise, or slightly more.
Gain is a brightness knob, nothing else; pick the value that exposes your desk
correctly and ignore the noise argument. Anything at or above 1984 also blows
out a large part of the frame, which is what the stock AGC does on a backlit
desk and why step 7 takes it out.

Once you find a value you like, put it in the `ExecStartPost` line of
`override.conf` so it survives a reboot.

Because gain is now fixed, **the camera no longer adapts to changing light.**
That is the trade: a backlight-blind automatic controller replaced by a number
you choose. Good for a desk, worse for a laptop that moves.

**Resolution** is `WIDTH` and `HEIGHT` in `/etc/v4l2-relayd.d/ipu7.conf`, then
`sudo systemctl restart v4l2-relayd@ipu7`. Applications need restarting to see
the change.

Higher is not automatically better here. Relay CPU against this configuration:

```
1280x720   ~78 %  of one core
1920x1080  ~93 %
3848x2176  ~59 %      no scaling at all -- but see below
```

Native is cheapest for the relay because it skips the downscale, but it moves
that work to whatever is reading, and 3848x2176 is not a standard webcam size:
Discord's background-blur filter fails on it outright. 1080p is the compromise.

`videobalance` sits before `videoscale`, so it runs on the full 3848x2176 frame
and is most of that cost. Moving it after `videoscale` should recover a good
part of it — untested.

## When it does not work

| symptom | likely cause | where |
|---|---|---|
| No camera in any application | sensors never bound | [step 3](#3-reboot-and-check-the-kernel-half) — check `Connected 2 cameras` first |
| **Sound stopped after a reboot** | WirePlumber stalled with no video devices | [step 4](#4-your-sound-just-stopped--fix-that-first) |
| Camera listed, picture permanently black | an application is holding a raw node | `fuser -v /dev/video0`; kill it, check the udev rule from [step 6](#6-keeping-applications-off-the-raw-nodes) |
| `v4l2-relayd@ipu7` fails instantly | `VIDEOSRC` ends with a capsfilter | [step 8](#8-the-relay) |
| Black frames, `Unsupported DRM format BA10` in the journal | sandbox is hiding dma-buf | `override.conf`, [step 8](#8-the-relay) |
| Under 1 fps | `v4l2sink` synchronising | [step 8](#8-the-relay) |
| A tear across the middle of the picture | loopback buffer starvation | `max_buffers=6`, [step 5](#5-a-virtual-webcam-applications-can-open) |
| Washed out, blown highlights, heavy noise | tuning file not picked up | [step 7](#7-exposure-and-colour); check the journal for `falling back to uncalibrated.yaml` |
| Device names contain quote marks | `card_label="A","B"` | quote the list once: `card_label="A,B"` |
| Camera dies after a kernel upgrade | DKMS did not build for the new kernel | install its headers, then `sudo dkms autoinstall` |

Useful:

```bash
journalctl -u 'v4l2-relayd@*' -b --no-pager | tail -40
v4l2-ctl --list-devices
media-ctl -d /dev/media0 -p | grep -E 'ov08x40|hm1092'
systemctl status v4l2-relayd@ipu7
```

## What this does not fix

- **Noise, and no setting removes it.** Measured temporally over a static
  scene, the delivered 1080p stream carries a median per-pixel deviation of
  about 2.5 of 255 — roughly 1 % — in well-lit areas, rising to 4-5 in the
  darkest parts of the frame. That shape is the giveaway: the noise sits in the
  shadows, so it is a light-level problem, and the only real cure is more light
  on your face. Every control was tried against it — gain across its full
  128-1984 range, exposure, and `vertical_blanking` — and none of them improves
  the ratio (see [Adjusting it afterwards](#adjusting-it-afterwards)). The
  underlying reason is that the sensor's 2x2-binned mode, which collects four
  times the light per output pixel and is what Windows uses for video, makes
  libcamera's software ISP abort. Every frame here is a full 8 MP readout scaled
  down in software instead.
- **Colour is approximate.** The CCM is a generic daylight matrix judged by eye,
  not a measurement. A real one needs a colour chart.
- **Exposure cannot be lengthened, and I cannot say why.** Shortening it
  works: `exposure=1200` is visibly darker than the default 2492. Lengthening it
  does nothing: 4992 — the ceiling the driver itself advertises at the default
  `vertical_blanking` — gives the same brightness as 2492. Raising
  `vertical_blanking` to 2600 does not help either; the frame rate does not
  budge (26.1 fps at 324, 25.2 at 2600). The obvious explanations do not hold
  up: libcamera is not rewriting the controls (they read back unchanged), the
  sensor is runtime-active while streaming, and the v7.2 `ov08x40` driver
  writes both registers whenever it is. Something between the control and the
  picture is clamping, and finding it needs the I2C bus. Gain is the only
  control that does anything, and it is now fixed.
- **About 90% of a core while streaming.** All the debayering and scaling is on
  the CPU. There is no hardware ISP: `/dev/ipu7-psys0` does not exist, and no
  PSYS driver exists in mainline at all.
- **IR is not covered.** The sensor binds and the illuminator registers, so
  Howdy face unlock is reachable through the fix pack's `--howdy-only`, but none
  of it was tested here.
- **The LTS kernel is not covered.** `int3472-patched` does not build against
  6.18 headers, so that kernel does not get the full set.

One thing worth knowing before you install any of this: **mainline has carried a
CVS driver since v7.2**, at `drivers/media/i2c/cvs/`, and its ACPI match table
lists `INTC10E1` — this laptop's bridge. CachyOS simply does not enable
`CONFIG_VIDEO_INTEL_CVS`. Whether the in-tree driver is sufficient on its own I
did not test; the out-of-tree one was already working by the time I found out.
If your distribution enables that symbol, try without the fix pack first.

## Credits

- [jibsta210/svp7500-camera-fix-pack](https://github.com/jibsta210/svp7500-camera-fix-pack)
  — the kernel drivers, which are the hard part and not my work.
- [grichard99/hp-spectre-x360-ipu6-camera-linux](https://github.com/grichard99/hp-spectre-x360-ipu6-camera-linux)
  — solves the adjacent problem on IPU6 and reached several of the same
  conclusions first, including the sandbox and `sync=false`.
- [vicamo/v4l2-relayd](https://gitlab.com/vicamo/v4l2-relayd) — the on-demand
  relay.

## Licence

GPL-2.0-only ([`LICENSE`](LICENSE)), same as everything this sits on: the
kernel, the fix pack, v4l2-relayd. The tuning file starts from libcamera's
`uncalibrated.yaml`, which is CC0-1.0 and can be carried under GPL.
