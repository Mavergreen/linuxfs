#!/bin/sh
# platform: macOS-only -- packages the 10.9 build for a 10.9 guest with Mavergreen macFUSE (Linux, via Docker, makes the images)
#   usage: p3-bundle.sh BUILT DEST
#          Makes DEST, a self-contained P3 run of linuxfs (CLI, root helper):
#          - bin/{lklfuse,linuxfs-probe,linuxfs-open,linuxfs-helper,linuxfs-agent} from BUILT
#            (build/build-lkl-darwin.sh's output) and bin/linuxfs (cli/linuxfs);
#          - the helper's LaunchDaemon plist, tests/p3-darwin.sh and run.sh;
#          - images/{ext4,btrfs,xfs,ntfs,exfat}.img.gz, made by Linux (tests/lib/probe-images.sh), and
#            images/apfs.img.gz, filled by Linux's lklfuse (tests/lib/apfs-image.sh), and images/enc.img.gz with
#            enc-expected.txt, the encrypted container macOS made (tests/fixtures/apfs);
#          - README and SHA256SUMS.
#          After the run, tests/p3-check-bundle.sh DEST checks the images it left in DEST/out.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$#" -eq 2 ] || { echo "usage: p3-bundle.sh BUILT DEST" >&2; exit 2; }
S=$(cd "$1" && pwd); D=$2
[ ! -e "$D" ] || { echo "p3-bundle.sh: $D exists" >&2; exit 1; }
mkdir -p "$D/bin" "$D/images"; D=$(cd "$D" && pwd)
for b in lklfuse linuxfs-probe linuxfs-open linuxfs-helper linuxfs-agent; do
  [ -f "$S/$b" ] || { echo "p3-bundle.sh: no $b in $S" >&2; exit 1; }
  cp "$S/$b" "$D/bin/$b"; chmod 755 "$D/bin/$b"
done
cp "$ROOT/cli/linuxfs" "$D/bin/linuxfs"; chmod 755 "$D/bin/linuxfs"
cp "$ROOT/packaging/dev.mavergreen.linuxfs.helper.plist" "$ROOT/tests/p3-darwin.sh" "$D/"
I=$HOME/Library/Caches/mm-build/p3-images; rm -rf "$I"; mkdir -p "$I"
sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/lib/probe-images.sh" "$I"
sh "$ROOT/build/linux-host.sh" sh "$ROOT/build/build-lkl-linux.sh" /work/gate0-linux/out > "$I/build.log" 2>&1 || { tail "$I/build.log" >&2; exit 1; }
LINUX_HOST_FUSE=1 sh "$ROOT/build/linux-host.sh" sh "$ROOT/tests/lib/apfs-image.sh" "$I/apfs.img"
for i in ext4 btrfs xfs ntfs exfat apfs; do gzip -9c "$I/$i.img" > "$D/images/$i.img.gz"; done
cp "$ROOT/tests/fixtures/apfs/enc.img.gz" "$D/images/enc.img.gz"; cp "$ROOT/tests/fixtures/apfs/expected.txt" "$D/images/enc-expected.txt"
rm -rf "$I"
cat > "$D/run.sh" <<'RUN'
#!/bin/sh
# platform: macOS-only -- the P3 bundle's entry point, on the 10.9 guest with Mavergreen macFUSE
#   usage: sh run.sh       (from the bundle's directory, as the console user; part B uses sudo -n)
set -u
cd "$(dirname "$0")" || exit 1
shasum -a 256 -c SHA256SUMS > sha.log 2>&1 || { echo "run.sh: SHA256SUMS does not match; see sha.log" >&2; exit 1; }
sh p3-darwin.sh 2>&1 | tee results.txt
r=$(grep -c '^not ok' results.txt)
echo "# ok: $(grep -c '^ok' results.txt), not ok: $r" | tee -a results.txt
[ "$r" -eq 0 ]
RUN
cp "$ROOT/tests/p3-bundle-README" "$D/README"
find "$D" -name '._*' -delete
(cd "$D" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 > SHA256SUMS)
echo "p3-bundle: $D ($(du -sh "$D" | cut -f1))"
