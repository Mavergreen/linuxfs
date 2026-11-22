#!/bin/sh
# platform: host-agnostic
#   usage: elf2macho-test.sh
#          build/elf2macho.py on small objects assembled here: a plain one (PC32, PLT32, a GOT load,
#          R_X86_64_64 and a data PC32) converts, and symbol kinds it cannot carry over (a TLS
#          variable, an IFUNC) are refused by name. Needs GNU as and python3 (the Linux host).
set -u
command -v as >/dev/null && command -v python3 >/dev/null || { echo "elf2macho-test.sh: needs as and python3" >&2; exit 77; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/elf2macho-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
n=0 bad=0
tap() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; bad=1; fi; }
conv() { as --64 -o "$T/$1.o" "$T/$1.s" && python3 "$ROOT/build/elf2macho.py" "$T/$1.o" "$T/$1.macho.o" 2> "$T/$1.err"; }
cat > "$T/plain.s" <<'S'
	.text
	.globl	lkl_entry
lkl_entry:
	call	helper
	leaq	table(%rip), %rax
	movq	counter@GOTPCREL(%rip), %rax
	ret
helper:
	ret
	.data
counter:	.quad	0
table:	.quad	helper + 8
	.long	helper - .
S
conv plain; tap $? "a plain object converts"
magic=$(od -An -tx4 -N4 "$T/plain.macho.o" 2>/dev/null | tr -d ' ')
[ "$magic" = feedfacf ]; tap $? "and the result is a 64-bit Mach-O"
printf '\t.section .tbss,"awT",@nobits\n\t.globl tlsvar\ntlsvar:\t.zero 8\n' > "$T/tls.s"
conv tls; rc=$?
[ $rc -ne 0 ] && grep -q "tlsvar" "$T/tls.err"; tap $? "a TLS symbol is refused, by name"
printf '\t.text\n\t.type pick, @gnu_indirect_function\n\t.globl pick\npick:\tret\n' > "$T/ifunc.s"
conv ifunc; rc=$?
[ $rc -ne 0 ] && grep -q "pick" "$T/ifunc.err"; tap $? "an IFUNC symbol is refused, by name"
echo "1..$n"
exit $bad
