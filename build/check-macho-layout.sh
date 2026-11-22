#!/bin/sh
# platform: host-agnostic
#   usage: check-macho-layout.sh OTOOL BINARY
#          Checks the linked BINARY keeps the kernel's data sections (elf2macho.py's __k<N>_*) as
#          the kernel's linker script laid them out: contiguous, nothing of another object's in
#          between, in N order. Symbols at a section's end (e.g. __start_ro_after_init at the end of
#          .data) stand for the next section's start only while that holds. The zero-fill .bss is
#          exempt: the linker places zero-fill last, and its symbols lie inside it. OTOOL is an
#          `otool -l` (llvm-otool will do).
set -eu
[ "$#" -eq 2 ] || { echo "usage: check-macho-layout.sh OTOOL BINARY" >&2; exit 2; }
"$1" -l "$2" | awk '
  $1 == "sectname" { name = $2 }
  $1 == "segname"  { seg = $2 }
  $1 == "addr"     { addr = $2 }
  $1 == "flags" && seg == "__DATA" {
    zerofill = (substr($2, length($2) - 1) == "01")
    if (!zerofill) print addr, name
  }' | sort | awk '
  { k = ($2 ~ /^__k[0-9]+_/) }
  k { n = substr($2, 4) + 0
      if (seen && !inrun) { print "check-macho-layout: " $2 " comes after another object'"'"'s section " prev; bad = 1 }
      if (seen && n <= last) { print "check-macho-layout: " $2 " is out of order (after __k" last ")"; bad = 1 }
      seen = 1; inrun = 1; last = n; count++ }
  !k { if (inrun) inrun = 0; prev = $2 }
  END { if (!count) { print "check-macho-layout: no __k sections found"; exit 1 }
        if (bad) exit 1
        print "check-macho-layout: " count " kernel data sections contiguous and in order" }'
