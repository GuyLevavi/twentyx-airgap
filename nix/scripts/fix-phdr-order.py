#!/usr/bin/env python3
"""Reorder ELF program headers so bun-compiled binaries run on Linux <= 6.6.

The failure this repairs, in one paragraph: nixpkgs patchelf's the bun
template, and patchelf's sortPhdrs() moves PT_GNU_STACK (p_paddr 0) to the
front of the header table. `bun build --compile` recycles *the slot that
holds PT_GNU_STACK* into the PT_LOAD for its appended payload, so the
compiled binary lists its highest-vaddr PT_LOAD first and the BSS-carrying
PT_LOAD last. The pre-6.7 kernel loader computes one global BSS range
(max(vaddr+filesz) .. max(vaddr+memsz)) while walking the table in order;
the table-first payload pins both maxima to the top of memory, the writable
segment's BSS tail is never mapped, and glibc's ld.so SIGSEGVs applying
R_X86_64_COPY relocations before main(). Linux >= 6.7 maps BSS per segment
and is immune. WSL2 ships 6.6; RHEL 8/9 nodes run 4.18/5.14, so RunAI pods
built from this closure are affected too.

The repair: put the PT_LOAD entries back in address-ascending order, which
is the order every normal linker emits. Only the contents of the existing
LOAD slots are permuted; no header is added, removed or moved across a
non-LOAD slot, so the table's size and file offset do not change.

Reference: https://www.whexy.com/dyn/3b6a3698-3ee7-80f5-8b50-ff0d0e5f365f
(nixpkgs issues #520383 / #523047, opencode #26846)

  fix-phdr-order <binary>...          reorder in place (idempotent)
  fix-phdr-order --check <binary>...  exit 1 if the layout is still unsafe
"""

import struct
import sys

PT_LOAD = 1
ELFCLASS64 = 2
PHDR_SIZE_64 = 56

PH_TYPE = slice(0, 4)
PH_OFFSET = slice(8, 16)
PH_VADDR = slice(16, 24)
PH_FILESZ = slice(32, 40)
PH_MEMSZ = slice(40, 48)


def die(msg):
    print(f"fix-phdr-order: error: {msg}", file=sys.stderr)
    sys.exit(1)


def u32(raw, field):
    return struct.unpack("<I", raw[field])[0]


def u64(raw, field):
    return struct.unpack("<Q", raw[field])[0]


def read_phdrs(path):
    with open(path, "rb") as f:
        ident = f.read(16)
        if len(ident) < 16 or ident[:4] != b"\x7fELF":
            die(f"{path}: not an ELF file")
        if ident[4] != ELFCLASS64:
            die(f"{path}: only 64-bit ELF is supported")
        rest = f.read(64 - 16)
        e_phoff = struct.unpack("<Q", rest[16:24])[0]
        e_phentsize = struct.unpack("<H", rest[38:40])[0]
        e_phnum = struct.unpack("<H", rest[40:42])[0]
        if e_phentsize != PHDR_SIZE_64:
            die(f"{path}: unexpected e_phentsize {e_phentsize}")
        f.seek(e_phoff)
        table = f.read(e_phentsize * e_phnum)
        if len(table) != e_phentsize * e_phnum:
            die(f"{path}: truncated program header table")
    phdrs = [
        table[i * e_phentsize : (i + 1) * e_phentsize] for i in range(e_phnum)
    ]
    return phdrs, e_phoff


def is_load(p):
    return u32(p, PH_TYPE) == PT_LOAD


def load_addr(p):
    return u64(p, PH_VADDR)


def bss_segments(loads):
    return [p for p in loads if u64(p, PH_MEMSZ) > u64(p, PH_FILESZ)]


def covered(start, end, ranges):
    """True iff [start, end) is contained in the union of `ranges`."""
    cur = start
    for lo, hi in sorted(ranges):
        if hi <= cur:
            continue
        if lo > cur:
            return False
        cur = max(cur, hi)
        if cur >= end:
            return True
    return cur >= end


def kernel66_maps_bss(loads):
    """Replay Linux <= 6.6's load_elf_binary() maxima walk over the table.

    The anonymous ranges below are what set_brk() actually maps; a BSS tail
    not covered by them is the SIGSEGV-in-ld.so case. Byte ranges, not page
    granularity: every real BSS tail is page-aligned.
    """
    elf_bss = elf_brk = 0
    anon = []
    for p in loads:
        if elf_brk > elf_bss:
            anon.append((elf_bss, elf_brk))
        elf_bss = max(elf_bss, u64(p, PH_VADDR) + u64(p, PH_FILESZ))
        elf_brk = max(elf_brk, u64(p, PH_VADDR) + u64(p, PH_MEMSZ))
    anon.append((elf_bss, elf_brk))
    for p in bss_segments(loads):
        start = u64(p, PH_VADDR) + u64(p, PH_FILESZ)
        end = u64(p, PH_VADDR) + u64(p, PH_MEMSZ)
        if not covered(start, end, anon):
            return False
    return True


def describe(path, phdrs):
    lines = [f"{path}: unsafe program header order:"]
    for p in phdrs:
        if is_load(p):
            lines.append(
                "  LOAD vaddr 0x%x filesz 0x%x memsz 0x%x"
                % (
                    u64(p, PH_VADDR),
                    u64(p, PH_FILESZ),
                    u64(p, PH_MEMSZ),
                )
            )
    return "\n".join(lines)


def main(argv):
    check = False
    files = []
    for arg in argv[1:]:
        if arg == "--check":
            check = True
        elif arg.startswith("-"):
            die(f"unknown option {arg}")
        else:
            files.append(arg)
    if not files:
        die(f"usage: {argv[0]} [--check] <binary>...")

    failed = False
    for path in files:
        phdrs, e_phoff = read_phdrs(path)
        loads = [p for p in phdrs if is_load(p)]

        if kernel66_maps_bss(loads):
            print(f"{path}: layout already fine")
            continue

        if check:
            print(describe(path, phdrs), file=sys.stderr)
            failed = True
            continue

        slots = [i for i, p in enumerate(phdrs) if is_load(p)]
        for slot, entry in zip(slots, sorted(loads, key=load_addr)):
            phdrs[slot] = entry

        if not kernel66_maps_bss([p for p in phdrs if is_load(p)]):
            print(describe(path, phdrs), file=sys.stderr)
            die(f"{path}: reordering did not make the layout safe")

        with open(path, "r+b") as f:
            f.seek(e_phoff)
            for p in phdrs:
                f.write(p)
        print(f"{path}: reordered")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
