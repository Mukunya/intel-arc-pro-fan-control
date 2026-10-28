# Arch Linux packages

This directory contains independent PKGBUILDs for the kernel-driver DKMS module
and userspace:

- `kernel/`: builds `intel-xe-oc-dkms`, which installs the patched `xe` DKMS
  source tree under `/usr/src` for automatic rebuilds on kernel updates.
- `userspace/`: builds `intel-arc-pro-fan-control` with the CLI utilities,
  GTK4/libadwaita GUI, polkit rule, configuration files, and systemd units.

The userspace programs are an executable Python GUI and shell utilities rather
than compiled native code. Its PKGBUILD still has a build phase that compiles
the GUI for syntax validation and checks all packaged shell scripts before
installing the runtime entry points.

The DKMS package builds only the patched `xe` module (fan + VF-curve OC) for
each installed kernel, and installs it under `/updates` so it is preferred over
the stock in-tree `xe`.

## Build

Build the DKMS kernel-driver package:

```bash
cd kernel
makepkg -si
```

Build the userspace package separately:

```bash
cd userspace
makepkg -si
```

After installation, DKMS should build/install `xe` for your kernel
automatically. Verify that the GPU binds to `xe` and that the patched sysfs
files exist before enabling persistent fan or overclock settings:

```bash
lspci -k
find /sys/class/drm -path '*hwmon*/pwm1_enable'
find /sys/devices -path '*gt0/oc/vf_curve'
```

The normal Arch kernel module remains available as a recovery path. If a DKMS
build fails, remove the DKMS package and regenerate your initramfs before
rebooting.
