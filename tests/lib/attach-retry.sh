# platform: host-agnostic
#   Sourced by tests/smoke-mavericks.sh (and tests/parity-test.sh), which provide bounded, image_disk and OUT.
#   da_attach_retry IMAGE   a plain `hdiutil attach` of a raw IMAGE (automount); sets `out` to what it printed and returns
#                           its status. The one failure of Apple's own, hdiutil's "no mountable file systems" (item 3:
#                           diskimages-helper claims and ejects the disk before DiskArbitration mounts it, on HFS+
#                           too; `diskutil mount` works), is tried once more, as da_eject does a busy eject: the
#                           stalled disk is detached, the retry printed (`# retrying hdiutil attach: ...`) and
#                           recorded in $OUT/parity/attach-retries.txt, where attach_retries counts them
#                           (push C's numbers). Any other failure, and a second stall, are not retried.
da_attach_retry() {
  out=$(bounded 3000 hdiutil attach -imagekey diskimage-class=CRawDiskImage "$1" 2>&1); _ar_rc=$?
  if test "$_ar_rc" -ne 0 && printf '%s\n' "$out" | grep -q 'no mountable file systems'; then
    _ar_line=$(printf '%s\n' "$out" | grep 'no mountable file systems' | tail -n 1)
    echo "# retrying hdiutil attach: $_ar_line"
    mkdir -p "$OUT/parity" && echo "$(date +%H:%M:%S) $1: no mountable file systems" >> "$OUT/parity/attach-retries.txt"
    _ar_d=$(bounded 300 image_disk "$1")
    # a plain detach first: a mount that came late is not forced away
    test -z "$_ar_d" || bounded 600 hdiutil detach "$_ar_d" > /dev/null 2>&1 || bounded 600 hdiutil detach -force "$_ar_d" > /dev/null 2>&1
    sleep 2
    out=$(bounded 3000 hdiutil attach -imagekey diskimage-class=CRawDiskImage "$1" 2>&1); _ar_rc=$?
  fi
  return "$_ar_rc"
}
# attach_retries: how many retries the run made
attach_retries() { if test -f "$OUT/parity/attach-retries.txt"; then wc -l < "$OUT/parity/attach-retries.txt" | tr -d ' '; else echo 0; fi; }
