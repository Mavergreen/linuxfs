#!/bin/sh
# platform: host-agnostic
# spec: tests/package-test.sh -- the six filesystem bundles DiskArbitration runs on 10.9 (shape proven by spike/da-bundle)
#   usage: fs-bundles.sh --version V --out DIR
#          Writes DIR/linuxfs_<fs>.fs/Contents/Info.plist for ext4, ntfs, btrfs, xfs, f2fs and apfs (0644, DIR's
#          bundles replaced): probe by linuxfs_<fs>.util, mount by mount_linuxfs_<fs>, personality names as the
#          Global Constraints give them. No format, verify or repair keys: phase 1 only mounts. The programs
#          themselves (all one linuxfs-fs binary, picking its role from argv[0]) are build/stage.sh's.
set -eu
usage() { echo "usage: fs-bundles.sh --version V --out DIR" >&2; exit 2; }
V=; out=
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || usage; V=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$V" ] && [ -n "$out" ] || usage
LINUX_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4
BASIC_GUID=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
APFS_GUID=7C3457EF-0000-11AA-AA11-00306543ECAC

# platform: DiskArbitration probes a bundle for each FSMediaTypes entry: Partitionless is the whole-disk, no-map
#           case, the rest are content hints (media_type NAME writes one)
media_type() {
  printf '\t\t<key>%s</key>\n\t\t<dict>\n\t\t\t<key>FSMediaProperties</key>\n\t\t\t<dict>\n' "$1"
  if [ "$1" = Partitionless ]; then printf '\t\t\t\t<key>Leaf</key>\n\t\t\t\t<true/>\n\t\t\t\t<key>Whole</key>\n\t\t\t\t<true/>\n'
  else printf '\t\t\t\t<key>Content Hint</key>\n\t\t\t\t<string>%s</string>\n\t\t\t\t<key>Leaf</key>\n\t\t\t\t<true/>\n' "$1"; fi
  printf '\t\t\t</dict>\n\t\t\t<key>FSProbeArguments</key>\n\t\t\t<string>-p</string>\n\t\t\t<key>FSProbeExecutable</key>\n'
  printf '\t\t\t<string>linuxfs_%s.util</string>\n\t\t\t<key>FSProbeOrder</key>\n\t\t\t<integer>900</integer>\n\t\t</dict>\n' "$fs"
}

mkdir -p "$out"
sub=0
for fs in ext4 ntfs btrfs xfs f2fs apfs; do
  case $fs in
    ntfs) pers=NTFS-linuxfs; label="Windows NTFS (linuxfs)"; types="$BASIC_GUID Windows_NTFS Partitionless" ;;
    btrfs) pers=btrfs; label="Linux btrfs (linuxfs)"; types="$LINUX_GUID $BASIC_GUID Linux Partitionless" ;;
    xfs) pers=XFS; label="Linux XFS (linuxfs)"; types="$LINUX_GUID $BASIC_GUID Linux Partitionless" ;;
    f2fs) pers=F2FS; label="Linux F2FS (linuxfs)"; types="$LINUX_GUID $BASIC_GUID Linux Partitionless" ;;
    apfs) pers=APFS; label="APFS (linuxfs)"; types="$APFS_GUID Partitionless" ;;
    *) pers=$fs; label="Linux $fs (linuxfs)"; types="$LINUX_GUID $BASIC_GUID Linux Partitionless" ;;
  esac
  d="$out/linuxfs_$fs.fs/Contents"
  rm -rf "$out/linuxfs_$fs.fs"
  mkdir -p "$d"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    printf '\t<key>CFBundleIdentifier</key>\n\t<string>dev.mavergreen.linuxfs.%s</string>\n' "$fs"
    printf '\t<key>CFBundleName</key>\n\t<string>linuxfs_%s</string>\n' "$fs"
    printf '\t<key>CFBundlePackageType</key>\n\t<string>fs  </string>\n'
    printf '\t<key>CFBundleShortVersionString</key>\n\t<string>%s</string>\n\t<key>CFBundleVersion</key>\n\t<string>%s</string>\n' "$V" "$V"
    printf '\t<key>FSMediaTypes</key>\n\t<dict>\n'
    for t in $(printf '%s\n' $types | sort); do media_type "$t"; done
    printf '\t</dict>\n\t<key>FSPersonalities</key>\n\t<dict>\n\t\t<key>%s</key>\n\t\t<dict>\n' "$pers"
    printf '\t\t\t<key>FSMountArguments</key>\n\t\t\t<string></string>\n\t\t\t<key>FSMountExecutable</key>\n\t\t\t<string>mount_linuxfs_%s</string>\n' "$fs"
    printf '\t\t\t<key>FSName</key>\n\t\t\t<string>%s</string>\n\t\t\t<key>FSSubType</key>\n\t\t\t<integer>%s</integer>\n' "$label" "$sub"
    printf '\t\t</dict>\n\t</dict>\n</dict>\n</plist>\n'
  } > "$d/Info.plist"
  chmod 644 "$d/Info.plist"
  sub=$((sub + 1))
done
