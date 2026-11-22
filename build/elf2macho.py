#!/usr/bin/env python3
# platform: host-agnostic
#   usage: elf2macho.py IN.o OUT.o
#          Converts LKL's lkl.o (an x86_64 ELF relocatable, already linked with the kernel's
#          linker script) into an x86_64 Mach-O relocatable for 10.9, so that the macOS linker
#          can take it. Allocated sections map one to one; debug sections are dropped. Every
#          symbol gains the Mach-O leading underscore. GOT-relative references go through a GOT
#          section this script adds, so no instruction is rewritten. Fails on any relocation it
#          does not know how to carry over exactly.
import struct
import sys

SHF_ALLOC, SHF_EXECINSTR = 0x2, 0x4
SHT_NOBITS = 8
SHN_UNDEF, SHN_ABS, SHN_COMMON = 0, 0xFFF1, 0xFFF2
STB_LOCAL, STB_GLOBAL, STB_WEAK = 0, 1, 2
STT_SECTION, STT_FILE, STT_TLS, STT_GNU_IFUNC = 3, 4, 6, 10
R_X86_64_64, R_X86_64_PC32, R_X86_64_PLT32 = 1, 2, 4
R_X86_64_GOTPCREL, R_X86_64_GOTPCRELX, R_X86_64_REX_GOTPCRELX = 9, 41, 42
GOT_TYPES = (R_X86_64_GOTPCREL, R_X86_64_GOTPCRELX, R_X86_64_REX_GOTPCRELX)

MH_MAGIC_64, CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, MH_OBJECT = 0xFEEDFACF, 0x01000007, 3, 1
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_VERSION_MIN_MACOSX = 0x19, 0x2, 0xB, 0x24
S_REGULAR, S_ZEROFILL = 0x0, 0x1
S_ATTR_PURE_INSTRUCTIONS, S_ATTR_SOME_INSTRUCTIONS = 0x80000000, 0x400
N_EXT, N_UNDF, N_ABS, N_SECT, N_WEAK_DEF = 0x1, 0x0, 0x2, 0xE, 0x80
X86_64_RELOC_UNSIGNED, X86_64_RELOC_SIGNED, X86_64_RELOC_BRANCH, X86_64_RELOC_SUBTRACTOR = 0, 1, 2, 5
MACOS_10_9 = (10 << 16) | (9 << 8)


def die(msg):
    sys.exit("elf2macho: " + msg)


def align_up(n, a):
    return (n + a - 1) & ~(a - 1) if a > 1 else n


class Elf:
    def __init__(self, data):
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
            die("not a little-endian ELF64 file")
        e_type, e_machine = struct.unpack_from("<HH", data, 16)
        if e_type != 1 or e_machine != 62:
            die("not an x86_64 relocatable")
        shoff, = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        self.data = data
        self.sh = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
        shstr = self.sh[shstrndx]
        self.names = [self.cstr(shstr[4] + s[0]) for s in self.sh]
        symtab = [i for i, s in enumerate(self.sh) if s[1] == 2]
        if len(symtab) != 1:
            die("expected exactly one symbol table")
        st = self.sh[symtab[0]]
        strtab = self.sh[st[6]]
        self.syms = []
        for off in range(st[4], st[4] + st[5], 24):
            name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", data, off)
            self.syms.append((self.cstr(strtab[4] + name), info >> 4, info & 0xF, shndx, value))

    def cstr(self, off):
        return self.data[off:self.data.index(b"\0", off)].decode()

    def contents(self, i):
        s = self.sh[i]
        return b"" if s[1] == SHT_NOBITS else self.data[s[4]:s[4] + s[5]]

    def relas(self, target):
        for i, s in enumerate(self.sh):
            if s[1] == 4 and s[7] == target:
                for off in range(s[4], s[4] + s[5], 24):
                    r_off, r_info, r_add = struct.unpack_from("<QQq", self.data, off)
                    yield r_off, r_info >> 32, r_info & 0xFFFFFFFF, r_add


class Section:
    def __init__(self, elf_index, name, data, size, align, is_text, is_bss):
        self.elf_index, self.elf_name = elf_index, name
        self.data = bytearray(data)
        self.size, self.align = size, max(align, 1)
        self.is_text, self.is_bss = is_text, is_bss
        self.relocs = []  # (address, symbolnum, pcrel, length, extern, type)
        self.addr = 0


def convert(elf):
    secs, by_elf = [], {}
    for i, (name, typ, flags, addr, off, size, link, info, align, entsize) in enumerate(elf.sh):
        # Allocated sections, plus empty ones (e.g. __ex_table), whose __start_/__stop_ symbols
        # the kernel still refers to.
        if not (flags & SHF_ALLOC or (size == 0 and typ in (1, 7, SHT_NOBITS))):
            continue
        s = Section(i, elf.names[i], elf.contents(i), size, align, bool(flags & SHF_EXECINSTR), typ == SHT_NOBITS)
        by_elf[i] = s
        secs.append(s)
    got = Section(None, ".lkl_got", b"", 0, 8, False, False)
    secs.append(got)
    # File-backed sections first, zero-fill last: the Mach-O linker lays zero-fill out at the end.
    secs.sort(key=lambda s: s.is_bss)
    for n, s in enumerate(secs):
        s.ordinal = n + 1
        if s.is_text:
            s.sectname, s.segname = "__text", "__TEXT"
            s.flags = S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
        else:
            s.sectname = ("__k%d%s" % (n, s.elf_name.replace(".", "_")))[:16]
            s.segname = "__DATA"
            s.flags = S_ZEROFILL if s.is_bss else S_REGULAR
    if sum(1 for s in secs if s.is_text) > 1:
        die("more than one executable section")

    # Symbols: one local per section start (relocation anchor), then the ELF symbols.
    syms = []  # [name, n_type, n_sect_section_or_None, value_offset, n_desc]
    sect_sym = {}
    for s in secs:
        sect_sym[s] = len(syms)
        syms.append(["__lkl_section_%d" % s.ordinal, N_SECT, s, 0, 0])
    elf_to_macho = {}
    undef = {}
    for idx, (name, bind, typ, shndx, value) in enumerate(elf.syms):
        if idx == 0 or typ in (STT_SECTION, STT_FILE) or not name:
            continue
        if typ in (STT_TLS, STT_GNU_IFUNC):
            die("symbol %s is %s, which Mach-O cannot express here" % (name, "TLS" if typ == STT_TLS else "an IFUNC"))
        if shndx == SHN_COMMON:
            die("common symbol %s (link with -d)" % name)
        if shndx == SHN_UNDEF:
            continue  # added on first use, so unused ones stay out
        if shndx == SHN_ABS:
            continue  # resolved on use, if ever used
        if shndx not in by_elf:
            continue  # lives in a dropped (non-allocated) section
        sec = by_elf[shndx]
        if value >= 1 << 63 and (1 << 64) - value < sec.align:
            # In the alignment padding before its own section (e.g. __bss_start): its start.
            value = 0
        elif value > sec.size:
            # A linker-script symbol in the padding after its section (e.g. __bss_start): it
            # belongs to the later section that starts at its address.
            at = elf.sh[shndx][3] + value
            home = [i for i in sorted(by_elf) if i > shndx and elf.sh[i][3] == at]
            if not home:
                die("symbol %s lies past its section, and no later section starts there" % name)
            sec, value = by_elf[home[0]], 0
        n_type = N_SECT | (N_EXT if bind in (STB_GLOBAL, STB_WEAK) else 0)
        desc = N_WEAK_DEF if bind == STB_WEAK else 0
        elf_to_macho[idx] = len(syms)
        syms.append(["_" + name, n_type, sec, value, desc])

    got_slot = {}

    def target(symidx, addend):
        """(macho symbol index, addend) for an ELF relocation target."""
        name, bind, typ, shndx, value = elf.syms[symidx]
        if typ == STT_SECTION:
            if shndx not in by_elf:
                die("relocation against dropped section %d" % shndx)
            return sect_sym[by_elf[shndx]], addend
        if idx_ok := elf_to_macho.get(symidx):
            return idx_ok, addend
        if shndx == SHN_UNDEF:
            if name not in undef:
                undef[name] = len(syms)
                syms.append(["_" + name, N_UNDF | N_EXT, None, 0, 0])
            return undef[name], addend
        die("relocation against unsupported symbol %s (shndx %#x)" % (name, shndx))

    def put32(sec, off, v):
        if not -(1 << 31) <= v < (1 << 31):
            die("addend %d overflows 32 bits in %s+%#x" % (v, sec.elf_name, off))
        struct.pack_into("<i", sec.data, off, v)

    for s in [s for s in secs if s.elf_index is not None]:
        for off, symidx, typ, addend in elf.relas(s.elf_index):
            if s.is_bss:
                die("relocation in zero-fill section %s" % s.elf_name)
            if typ == R_X86_64_64:
                sym, a = target(symidx, addend)
                struct.pack_into("<q", s.data, off, a)
                s.relocs.append((off, sym, 0, 3, 1, X86_64_RELOC_UNSIGNED))
            elif typ in (R_X86_64_PC32, R_X86_64_PLT32) and s.is_text:
                # Mach-O computes S + inplace - (P + 4): store A + 4 to get ELF's S + A - P.
                sym, a = target(symidx, addend)
                put32(s, off, a + 4)
                kind = X86_64_RELOC_BRANCH if typ == R_X86_64_PLT32 and a == -4 else X86_64_RELOC_SIGNED
                s.relocs.append((off, sym, 1, 2, 1, kind))
            elif typ == R_X86_64_PC32:
                # Data: S + A - P as SUBTRACTOR(section start) + UNSIGNED(S), inplace A - offset.
                sym, a = target(symidx, addend)
                put32(s, off, a - off)
                s.relocs.append((off, sect_sym[s], 0, 2, 1, X86_64_RELOC_SUBTRACTOR))
                s.relocs.append((off, sym, 0, 2, 1, X86_64_RELOC_UNSIGNED))
            elif typ in GOT_TYPES:
                if not s.is_text:
                    die("GOT relocation outside text")
                sym, a = target(symidx, 0)
                if sym not in got_slot:
                    got_slot[sym] = len(got.data)
                    got.data += b"\0" * 8
                    got.relocs.append((got_slot[sym], sym, 0, 3, 1, X86_64_RELOC_UNSIGNED))
                # displacement = slot + A - P, via the GOT section's start symbol
                put32(s, off, got_slot[sym] + addend + 4)
                s.relocs.append((off, sect_sym[got], 1, 2, 1, X86_64_RELOC_SIGNED))
            else:
                die("unsupported relocation type %d in %s+%#x" % (typ, s.elf_name, off))
    got.size = len(got.data)

    # Layout: section addresses in one segment; file offsets after the load commands.
    addr = 0
    for s in secs:
        addr = align_up(addr, s.align)
        s.addr = addr
        addr += s.size
    vmsize = addr

    # Mach-O symbol order: locals, external definitions, undefined; each external group by name.
    loc = [i for i, y in enumerate(syms) if not y[1] & N_EXT]
    ext = sorted((i for i, y in enumerate(syms) if y[1] & N_EXT and y[1] & N_SECT == N_SECT), key=lambda i: syms[i][0])
    und = sorted((i for i, y in enumerate(syms) if y[1] == N_UNDF | N_EXT), key=lambda i: syms[i][0])
    order = loc + ext + und
    newidx = {old: new for new, old in enumerate(order)}

    strtab = bytearray(b"\0")
    nlist = bytearray()
    for old in order:
        name, n_type, sec, value, desc = syms[old]
        strx = len(strtab)
        strtab += name.encode() + b"\0"
        if sec is None:
            nlist += struct.pack("<IBBHQ", strx, n_type, 0, desc, 0)
        else:
            if value > sec.size:
                die("symbol %s lies past its section" % name)
            nlist += struct.pack("<IBBHQ", strx, n_type, sec.ordinal, desc, sec.addr + value)
    strtab += b"\0" * (-len(strtab) % 8)

    nsects = len(secs)
    seg_cmd = 72 + 80 * nsects
    sizeofcmds = seg_cmd + 16 + 24 + 80
    off = align_up(32 + sizeofcmds, 16)
    body = bytearray()
    for s in secs:
        if s.is_bss:
            s.offset = 0
            continue
        pad = align_up(off + len(body), s.align) - (off + len(body))
        body += b"\0" * pad
        s.offset = off + len(body)
        if len(s.data) != s.size:
            die("section %s data/size mismatch" % s.elf_name)
        body += s.data
    filesize = len(body)
    seg_fileoff = off
    for s in secs:
        body += b"\0" * (-(off + len(body)) % 8)
        s.reloff = off + len(body) if s.relocs else 0
        for (address, sym, pcrel, length, extern, typ) in s.relocs:
            word = (newidx[sym] & 0xFFFFFF) | (pcrel << 24) | (length << 25) | (extern << 27) | (typ << 28)
            body += struct.pack("<iI", address, word)
    body += b"\0" * (-(off + len(body)) % 8)
    symoff = off + len(body)
    body += nlist
    stroff = off + len(body)
    body += strtab

    out = bytearray(struct.pack("<IiiIIIII", MH_MAGIC_64, CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_ALL, MH_OBJECT, 4, sizeofcmds, 0, 0))
    out += struct.pack("<II16sQQQQiiII", LC_SEGMENT_64, seg_cmd, b"", 0, vmsize, seg_fileoff, filesize, 7, 7, nsects, 0)
    for s in secs:
        out += struct.pack("<16s16sQQIIIIIIII", s.sectname.encode(), s.segname.encode(), s.addr, s.size,
                           s.offset, (s.align.bit_length() - 1), s.reloff, len(s.relocs), s.flags, 0, 0, 0)
    out += struct.pack("<IIII", LC_VERSION_MIN_MACOSX, 16, MACOS_10_9, MACOS_10_9)
    out += struct.pack("<IIIIII", LC_SYMTAB, 24, symoff, len(order), stroff, len(strtab))
    out += struct.pack("<II18I", LC_DYSYMTAB, 80, 0, len(loc), len(loc), len(ext), len(loc) + len(ext), len(und), *([0] * 12))
    out += b"\0" * (off - len(out))
    return bytes(out + body)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: elf2macho.py IN.o OUT.o")
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    out = convert(Elf(data))
    with open(sys.argv[2], "wb") as f:
        f.write(out)


main()
