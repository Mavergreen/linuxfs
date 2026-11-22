#!/bin/sh
# platform: macOS-only -- 10.13 or later: diskutil makes the APFS that Linux's mkapfs cannot (native encryption, Fusion)
#   usage: sh make-apfs-fixtures.sh
#          Makes linuxfs's APFS test fixtures as raw disk images, with no sudo and nothing installed: hdiutil attaches
#          each image (as the user, -nomount), diskutil formats it, files are written, and everything is detached.
#          Writes into one new directory, printed at the end:
#            enc.img.gz   1200 MiB: a container with volume "Secret", encrypted with passphrase "linuxfs-test" (hint
#                         "test"), and volume "Plain", unencrypted; the same files on both
#            ssd.img.gz   256 MiB \ one Fusion container (-main ssd, -secondary hdd) with volume "Fused"; its 400 MiB
#            hdd.img.gz   1 GiB   / file cannot fit on the 256 MiB main device, so part of it lies on the secondary
#          (APFS allows one volume per 512 MiB of container, rounded up: enc.img needs more than 512 MiB for two)
#            expected.txt SHA-256 of every file written, per volume, as `shasum -a 256` prints them
#            macos.txt    sw_vers, uname -m and diskutil's version
#            log.txt      everything the tools printed
#          Exits non-zero, naming the step, if any step fails; images still attached are detached on the way out.
#          A macOS that makes no Fusion containers (27 says "Fusion drives are deprecated") skips that step.
set -eu
OUT=$(mktemp -d "${TMPDIR:-/tmp}/linuxfs-apfs-fixtures.XXXXXX")
cd "$OUT"
exec 3>&1 > log.txt 2>&1
cleanup() {
  [ -f attached.lst ] || return 0
  for d in $(cat attached.lst); do hdiutil detach -force "$d" > /dev/null 2>&1 || :; done
}
trap cleanup EXIT
step() { echo "== $*"; echo "== $*" >&3; }
die() { echo "make-apfs-fixtures: $*" >&3; echo "make-apfs-fixtures: $*"; echo "see $OUT/log.txt" >&3; exit 1; }
{ sw_vers; uname -m; } > macos.txt 2>&1 || :

image() { # FILE MiB -> prints the attached whole disk
  mkfile -n "${2}m" "$1" || die "mkfile $1"
  d=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$1" | awk 'NR == 1 { print $1 }')
  [ -n "$d" ] || die "hdiutil attach $1"
  echo "$d" >> attached.lst; printf '%s\n' "$d"
}
synthesized() { diskutil list | awk '/synthesized/ { print $1 }' | sort; }
new_container() { # BEFORE-LIST -> prints the container disk that appeared
  synthesized > after.lst
  c=$(comm -13 "$1" after.lst | head -n 1); rm -f after.lst
  [ -n "$c" ] || die "no new APFS container appeared"
  printf '%s\n' "$c"
}
mounted_at() { mount | awk -v v="$1" '$0 ~ " on /Volumes/" v " \\(" { sub(/^.* on /, ""); sub(/ \(.*$/, ""); print; exit }'; }
fill() { # MOUNTPOINT: the same files on every volume
  m=$1
  echo "hello apfs" > "$m/hello.txt"
  perl -e 'print chr($_ % 251) for 0 .. 1048575' > "$m/pattern-1m.bin"
  mkdir "$m/d"; i=1; while [ $i -le 50 ]; do echo $i > "$m/d/f$i"; i=$((i + 1)); done
  ln -s hello.txt "$m/link"
  cafe=$(printf 'caf\303\251')   # NFC "café": printf expands the escapes, a quoted file name would not
  echo "$cafe" > "$m/unicode-$cafe.txt"
}
record() { # NAME MOUNTPOINT
  (cd "$2" && find . -type f | sort | while read -r f; do shasum -a 256 "$f"; done) | sed "s|^|$1 |" >> expected.txt
}

step "encrypted: enc.img, volumes Secret (passphrase) and Plain"
d=$(image enc.img 1200)
synthesized > before.lst
diskutil apfs createContainer "$d" || die "createContainer on $d"
c=$(new_container before.lst); rm -f before.lst
diskutil apfs addVolume "$c" APFS Secret -passphrase linuxfs-test -passphraseHint test || die "addVolume Secret (encrypted)"
diskutil apfs addVolume "$c" APFS Plain || die "addVolume Plain"
for v in Secret Plain; do
  m=$(mounted_at "$v"); [ -n "$m" ] || die "volume $v is not mounted"
  fill "$m" && record "$v" "$m" || die "writing to $v"
done
diskutil apfs list "$c" || :
diskutil unmountDisk "$c" || die "unmountDisk $c"
hdiutil detach "$d" || die "detach $d"; rm -f attached.lst

step "fusion: ssd.img (main) and hdd.img (secondary), volume Fused"
s=$(image ssd.img 256)
h=$(image hdd.img 1024)
synthesized > before.lst
if ! diskutil apfs createContainer -main "$s" -secondary "$h" > fusion.out 2>&1; then
  cat fusion.out
  grep -q 'Fusion drives are deprecated' fusion.out || die "createContainer -main $s -secondary $h"
  # platform: macOS 27 makes no Fusion containers: keep the encrypted fixture, and say so
  step "fusion: this macOS makes no Fusion containers; skipped"
  hdiutil detach "$s" || :; hdiutil detach "$h" || :; rm -f attached.lst before.lst ssd.img hdd.img fusion.out
  fusion=
else
  fusion=1
  cat fusion.out; rm -f fusion.out
  c=$(new_container before.lst); rm -f before.lst
  diskutil apfs addVolume "$c" APFS Fused || die "addVolume Fused"
  m=$(mounted_at Fused); [ -n "$m" ] || die "volume Fused is not mounted"
  fill "$m" || die "writing to Fused"
  perl -e 'for $b (0 .. 399) { print pack("N", $b) x 262144 }' > "$m/spill-400m.bin" || die "writing the 400 MiB file"
  record Fused "$m"
  diskutil apfs list "$c" || :
  diskutil unmountDisk "$c" || die "unmountDisk $c"
  hdiutil detach "$s" || die "detach $s"; hdiutil detach "$h" || die "detach $h"; rm -f attached.lst
fi

step "compress"
for f in enc ${fusion:+ssd hdd}; do gzip -9 "$f.img" || die "gzip $f.img"; done
exec 1>&3
echo "make-apfs-fixtures: done. Send this directory back: $OUT"
ls -l "$OUT"
