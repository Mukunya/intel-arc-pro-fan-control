#!/usr/bin/env bash
# dkms-build.sh <kernelver> — build the patched xe.ko for a specific kernel,
# invoked by DKMS (see dkms.conf). Reproduces the verified recipe from
# docs/LINUX-BUILD.md for $kernelver (which, during a kernel update, is NOT
# necessarily the running kernel — so nothing here uses `uname -r`).
#
# STATUS: BETA. The load-bearing assumption is that the matching kernel SOURCE
# (linux-source-<base>) is installable for $kernelver. If your distro ships xe
# source differently, adapt the "kernel source" section.
#
# Output: build-<kernelver>/xe.ko  (BUILT_MODULE_LOCATION in dkms.conf).
set -euo pipefail

KVER="${1:?usage: dkms-build.sh <kernelver>}"
BASE="${KVER%%-*}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # the DKMS source dir
OUT="${HERE}/build-${KVER}"
SRC="${OUT}/linux-source-${BASE}"
XE="${SRC}/drivers/gpu/drm/xe"

HDR=""
for cand in \
  "/lib/modules/${KVER}/build" \
  "/usr/lib/modules/${KVER}/build" \
  "/usr/src/linux-headers-${KVER}" \
  "/usr/src/kernels/${KVER}"
do
  [ -d "$cand" ] || continue
  HDR="$(readlink -f "$cand")"
  break
done
[ -n "$HDR" ] || {
  echo "dkms-build: headers/build tree for $KVER not found."
  echo "            checked /lib/modules/<kver>/build and common source locations."
  exit 1
}

# --- kernel source -----------------------------------------------------------
rm -rf "$OUT"; mkdir -p "$OUT"

if [ -d "$HDR/drivers/gpu/drm/xe" ] && [ -f "$HDR/Makefile" ]; then
  cp -a "$HDR" "$SRC"
else
  KERNEL_SRC=""
  for cand in \
    "/lib/modules/${KVER}/source" \
    "/usr/lib/modules/${KVER}/source" \
    "/usr/src/linux" \
    "/usr/src/kernels/${KVER}"
  do
    [ -d "$cand/drivers/gpu/drm/xe" ] || continue
    KERNEL_SRC="$(readlink -f "$cand")"
    break
  done

  if [ -n "$KERNEL_SRC" ]; then
    cp -a "$KERNEL_SRC" "$SRC"
  else
    TARBALL="$(ls /usr/src/linux-source-${BASE}/linux-source-${BASE}.tar.* 2>/dev/null | head -1 || true)"
    if [ -z "$TARBALL" ]; then
      echo "dkms-build: no full kernel source tree found for $KVER."
      echo "            install distro kernel source (Debian: linux-source-${BASE}; Arch: linux source tree under /usr/src/linux)."
      exit 1
    fi
    tar -xf "$TARBALL" -C "$OUT"
  fi
fi
[ -d "$XE" ] || { echo "dkms-build: xe not in source tree ($SRC)"; exit 1; }

# --- patches (shipped alongside this script in the DKMS source dir) ----------
FANPATCH="$(ls "$HERE"/patch/xe-fan-control-*.patch 2>/dev/null | head -1 || \
            ls "$HERE"/xe-fan-control-*.patch 2>/dev/null | head -1 || true)"
[ -f "$FANPATCH" ] || { echo "dkms-build: fan patch not found next to dkms-build.sh"; exit 1; }
( cd "$SRC" && patch -p1 --fuzz=5 -i "$FANPATCH" )

OCDIR="$HERE/kernel"; [ -d "$OCDIR" ] || OCDIR="$HERE"
cp "$OCDIR/xe_gt_oc.c" "$OCDIR/xe_gt_oc.h" "$XE/"
python3 - "$XE" <<'PY'
import sys
XE=sys.argv[1]
mk=XE+"/Makefile"; lines=open(mk).read().split("\n")
if not any("xe_gt_oc.o" in l for l in lines):
    out=[]
    for l in lines:
        out.append(l)
        if "xe_gt_freq.o" in l:
            out.append(l[:len(l)-len(l.lstrip())]+"xe_gt_oc.o \\")
    open(mk,"w").write("\n".join(out))
gt=XE+"/xe_gt.c"; s=open(gt).read()
if '#include "xe_gt_oc.h"' not in s:
    s=s.replace('#include "xe_gt_freq.h"\n','#include "xe_gt_freq.h"\n#include "xe_gt_oc.h"\n',1)
if "xe_gt_oc_init(gt)" not in s:
    a="\terr = xe_gt_freq_init(gt);\n\tif (err)\n\t\treturn err;\n"
    if a in s: s=s.replace(a,a+"\n\terr = xe_gt_oc_init(gt);\n\tif (err)\n\t\treturn err;\n",1)
    else: sys.exit("dkms-build: xe_gt.c init anchor not found")
open(gt,"w").write(s)
PY

# --- real config + version from the target kernel's headers ------------------
cp "$HDR/.config" "$SRC/.config"
( cd "$SRC" && ./scripts/config --set-str SYSTEM_TRUSTED_KEYS '' \
                                --set-str SYSTEM_REVOCATION_KEYS '' )
( cd "$SRC" && make olddefconfig >/dev/null && make -j"$(nproc)" modules_prepare >/dev/null )
cp "$HDR/include/generated/utsrelease.h" "$SRC/include/generated/utsrelease.h"
cp "$HDR/include/config/kernel.release"  "$SRC/include/config/kernel.release"
cp "$HDR/Module.symvers"                 "$SRC/Module.symvers"

# --- build -------------------------------------------------------------------
( cd "$SRC" && env PATH="$PATH:$XE" make -j"$(nproc)" M=drivers/gpu/drm/xe modules )
[ -f "$XE/xe.ko" ] || { echo "dkms-build: xe.ko not produced"; exit 1; }

VM="$(modinfo "$XE/xe.ko" | awk '/^vermagic:/{print $2}')"
[ "$VM" = "$KVER" ] || { echo "dkms-build: vermagic '$VM' != '$KVER'"; exit 1; }

# hand xe.ko to DKMS (BUILT_MODULE_LOCATION = build-<KVER>)
cp "$XE/xe.ko" "$OUT/xe.ko"
echo "dkms-build: OK  ($OUT/xe.ko, vermagic $VM)"
