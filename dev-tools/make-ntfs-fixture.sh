#!/usr/bin/env bash
set -euo pipefail

# Creates a small NTFS-formatted sparse disk image to simulate a pendrive
# during development, without needing real USB hardware. Attaching the
# resulting image triggers the same DiskArbitration events (DiskAppeared,
# DiskDescriptionChanged) as inserting a physical NTFS drive, since
# DiskArbitration doesn't distinguish image-backed media from physical media.
#
# Requires ntfs-3g-mac for `mkntfs`:
#   brew install --cask macfuse
#   brew tap gromgit/homebrew-fuse
#   brew install ntfs-3g-mac
#
# Usage: dev-tools/make-ntfs-fixture.sh [name] [size_mb] [volume_label]
#
# Implementation notes (learned the hard way, see README):
# - `hdiutil create -fs none` is no longer accepted on recent macOS, so this
#   starts the image as FAT32 (a plain FDisk/MBR partition) and reformats
#   that partition with mkntfs afterwards.
# - `mkntfs` needs the *block* device (/dev/diskNsN), not the raw/character
#   one (/dev/rdiskNsN) — the raw device fails with "Invalid argument" on
#   disk-image-backed volumes.
# - mkntfs only rewrites the filesystem content, not the MBR partition-type
#   byte, so without patching it DiskArbitration keeps reporting the volume
#   as DOS_FAT_32 forever (verified: detaching/reattaching does NOT fix
#   this on its own). The byte is patched directly on the whole-disk raw
#   device, sector-aligned, then a fresh detach+attach makes DiskArbitration
#   re-probe and correctly report `Windows_NTFS` / kind "ntfs".

IMAGE_NAME="${1:-ntfs-fixture}"
SIZE_MB="${2:-200}"
VOLUME_LABEL="${3:-TestNTFS}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BASE="${SCRIPT_DIR}/${IMAGE_NAME}"
IMAGE_FILE="${IMAGE_BASE}.sparseimage"

HOMEBREW_PREFIX=""
for prefix in /opt/homebrew /usr/local; do
  if [ -x "${prefix}/bin/brew" ]; then
    HOMEBREW_PREFIX="${prefix}"
    break
  fi
done

if [ -z "${HOMEBREW_PREFIX}" ]; then
  echo "error: Homebrew not found in /opt/homebrew or /usr/local" >&2
  exit 1
fi

MKNTFS="${HOMEBREW_PREFIX}/opt/ntfs-3g-mac/sbin/mkntfs"
if [ ! -x "${MKNTFS}" ]; then
  echo "error: mkntfs not found at ${MKNTFS}" >&2
  echo "Install it with:" >&2
  echo "  brew install --cask macfuse" >&2
  echo "  brew tap gromgit/homebrew-fuse" >&2
  echo "  brew install ntfs-3g-mac" >&2
  exit 1
fi

if [ -f "${IMAGE_FILE}" ]; then
  echo "error: ${IMAGE_FILE} already exists — remove it first" >&2
  exit 1
fi

echo "Creating ${SIZE_MB}MB sparse image at ${IMAGE_FILE}..."
hdiutil create -size "${SIZE_MB}m" -type SPARSE -fs "MS-DOS FAT32" -volname "${VOLUME_LABEL}" "${IMAGE_BASE}"

echo "Attaching image without mounting..."
ATTACH_OUTPUT="$(hdiutil attach -nomount "${IMAGE_FILE}")"
WHOLE_DISK="$(echo "${ATTACH_OUTPUT}" | awk 'NR==1{print $1}')"
PARTITION_DEVICE="$(echo "${ATTACH_OUTPUT}" | awk '/DOS_FAT_32/{print $1; exit}')"
RAW_WHOLE_DISK="${WHOLE_DISK/disk/rdisk}"

if [ -z "${WHOLE_DISK}" ] || [ -z "${PARTITION_DEVICE}" ]; then
  echo "error: could not parse hdiutil attach output:" >&2
  echo "${ATTACH_OUTPUT}" >&2
  exit 1
fi
echo "Attached: whole disk ${WHOLE_DISK}, partition ${PARTITION_DEVICE}"

echo "Formatting ${PARTITION_DEVICE} as NTFS (label: ${VOLUME_LABEL})..."
"${MKNTFS}" -Q -F -L "${VOLUME_LABEL}" "${PARTITION_DEVICE}"

echo "Patching MBR partition type to NTFS (0x07)..."
TMP_SECTOR="$(mktemp)"
trap 'rm -f "${TMP_SECTOR}"' EXIT
dd if="${RAW_WHOLE_DISK}" of="${TMP_SECTOR}" bs=512 count=1 2>/dev/null
printf '\x07' | dd of="${TMP_SECTOR}" bs=1 seek=450 count=1 conv=notrunc 2>/dev/null
dd if="${TMP_SECTOR}" of="${RAW_WHOLE_DISK}" bs=512 count=1 conv=notrunc 2>/dev/null

echo "Detaching (a fresh attach is required for DiskArbitration to re-probe the filesystem type)..."
hdiutil detach "${WHOLE_DISK}"

cat <<EOF

Done: ${IMAGE_FILE}

To simulate inserting the drive (fires the same DiskArbitration events
DiskWatcher listens for as a real pendrive):
  hdiutil attach "${IMAGE_FILE}"

To simulate ejecting it:
  hdiutil detach <device node printed after attaching>

To delete the fixture entirely:
  rm "${IMAGE_FILE}"
EOF
