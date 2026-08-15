#!/usr/bin/env bash
set -euo pipefail

# Same idea as make-ntfs-fixture.sh, but lays out TWO NTFS partitions on one
# simulated disk — for testing that DiskWatcher/MountManager handle each
# partition of a multi-partition drive independently (a real pendrive
# re-partitioned from Windows Disk Management, for example).
#
# Requires ntfs-3g-mac for `mkntfs` — see make-ntfs-fixture.sh.
#
# Usage: dev-tools/make-ntfs-fixture-multi.sh [name] [size_mb] [label1] [label2]
#
# Implementation notes (builds on make-ntfs-fixture.sh's, see README):
# - Starts as a single FAT32 partition (same `hdiutil create` constraint as
#   the single-partition fixture), then `diskutil partitionDisk` replaces
#   that with two FAT32 partitions before each gets reformatted with mkntfs.
# - MBR only has one partition-type byte per entry; a 2-partition MBR layout
#   puts entry 1's type byte at offset 450 (0x1C2) and entry 2's at offset
#   466 (0x1D2) — both need patching to 0x07 (NTFS), same reasoning as the
#   single-partition script.

IMAGE_NAME="${1:-ntfs-fixture-multi}"
SIZE_MB="${2:-200}"
LABEL_1="${3:-TestNTFS1}"
LABEL_2="${4:-TestNTFS2}"

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
hdiutil create -size "${SIZE_MB}m" -type SPARSE -fs "MS-DOS FAT32" -volname "seed" "${IMAGE_BASE}"

echo "Attaching image without mounting..."
ATTACH_OUTPUT="$(hdiutil attach -nomount "${IMAGE_FILE}")"
WHOLE_DISK="$(echo "${ATTACH_OUTPUT}" | awk 'NR==1{print $1}')"
RAW_WHOLE_DISK="${WHOLE_DISK/disk/rdisk}"

if [ -z "${WHOLE_DISK}" ]; then
  echo "error: could not parse hdiutil attach output:" >&2
  echo "${ATTACH_OUTPUT}" >&2
  exit 1
fi
echo "Attached: whole disk ${WHOLE_DISK}"

echo "Repartitioning into two FAT32 partitions (will be reformatted as NTFS below)..."
diskutil partitionDisk "${WHOLE_DISK}" 2 MBR \
  "MS-DOS FAT32" "${LABEL_1}" 50% \
  "MS-DOS FAT32" "${LABEL_2}" 50%

PART_1="${WHOLE_DISK}s1"
PART_2="${WHOLE_DISK}s2"

echo "Unmounting both partitions before reformatting..."
diskutil unmount "${PART_1}" || true
diskutil unmount "${PART_2}" || true

echo "Formatting ${PART_1} as NTFS (label: ${LABEL_1})..."
"${MKNTFS}" -Q -F -L "${LABEL_1}" "${PART_1}"

echo "Formatting ${PART_2} as NTFS (label: ${LABEL_2})..."
"${MKNTFS}" -Q -F -L "${LABEL_2}" "${PART_2}"

echo "Patching MBR partition types to NTFS (0x07) for both entries..."
TMP_SECTOR="$(mktemp)"
trap 'rm -f "${TMP_SECTOR}"' EXIT
dd if="${RAW_WHOLE_DISK}" of="${TMP_SECTOR}" bs=512 count=1 2>/dev/null
printf '\x07' | dd of="${TMP_SECTOR}" bs=1 seek=450 count=1 conv=notrunc 2>/dev/null
printf '\x07' | dd of="${TMP_SECTOR}" bs=1 seek=466 count=1 conv=notrunc 2>/dev/null
dd if="${TMP_SECTOR}" of="${RAW_WHOLE_DISK}" bs=512 count=1 conv=notrunc 2>/dev/null

echo "Detaching (a fresh attach is required for DiskArbitration to re-probe the filesystem type)..."
hdiutil detach "${WHOLE_DISK}"

cat <<EOF

Done: ${IMAGE_FILE}

To simulate inserting the drive (fires the same DiskArbitration events
DiskWatcher listens for as a real multi-partition pendrive):
  hdiutil attach "${IMAGE_FILE}"

To simulate ejecting it:
  hdiutil detach <whole-disk device node printed after attaching>

To delete the fixture entirely:
  rm "${IMAGE_FILE}"
EOF
