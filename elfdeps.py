#!/usr/bin/env python3
"""elfdeps.py - dependances dynamiques d'un binaire ELF (comme `readelf -d`).

Stdlib uniquement, fonctionne sous Windows.
Usage : python elfdeps.py binaire [binaire2 ...]
"""
import struct
import sys

PT_LOAD, PT_DYNAMIC, PT_INTERP = 1, 2, 3
DT_NULL, DT_NEEDED, DT_STRTAB, DT_SONAME, DT_RPATH, DT_RUNPATH = 0, 1, 5, 14, 15, 29
MACHINES = {3: "x86", 0x3E: "x86-64", 0x28: "ARM", 0xB7: "AArch64",
            0xF3: "RISC-V", 8: "MIPS", 0x14: "PowerPC", 0x15: "PowerPC64", 0x16: "s390x"}


def elf_deps(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF":
        raise ValueError("pas un fichier ELF")

    is64 = data[4] == 2
    e = "<" if data[5] == 1 else ">"  # endianness
    machine, = struct.unpack_from(e + "H", data, 0x12)

    # Program headers -> (type, offset, vaddr, filesz)
    if is64:
        phoff, = struct.unpack_from(e + "Q", data, 0x20)
        phentsize, phnum = struct.unpack_from(e + "HH", data, 0x36)
        phdrs = [struct.unpack_from(e + "IIQQQQQQ", data, phoff + i * phentsize)
                 for i in range(phnum)]
        phdrs = [(p[0], p[2], p[3], p[5]) for p in phdrs]
        dyn_fmt = e + "qQ"
    else:
        phoff, = struct.unpack_from(e + "I", data, 0x1C)
        phentsize, phnum = struct.unpack_from(e + "HH", data, 0x2A)
        phdrs = [struct.unpack_from(e + "IIIIIIII", data, phoff + i * phentsize)
                 for i in range(phnum)]
        phdrs = [(p[0], p[1], p[2], p[4]) for p in phdrs]
        dyn_fmt = e + "iI"
    dyn_size = struct.calcsize(dyn_fmt)

    def cstr(off):
        return data[off:data.index(b"\0", off)].decode("utf-8", "replace")

    def vaddr_to_off(addr):
        for typ, off, vaddr, filesz in phdrs:
            if typ == PT_LOAD and vaddr <= addr < vaddr + filesz:
                return addr - vaddr + off
        raise ValueError(f"adresse 0x{addr:x} hors des segments PT_LOAD")

    info = {"arch": f"{MACHINES.get(machine, hex(machine))}, {64 if is64 else 32} bits, "
                    f"{'little' if e == '<' else 'big'} endian",
            "interp": None, "dynamic": False}
    entries = []
    for typ, off, vaddr, filesz in phdrs:
        if typ == PT_INTERP:
            info["interp"] = cstr(off)
        elif typ == PT_DYNAMIC:
            info["dynamic"] = True
            for i in range(filesz // dyn_size):
                tag, val = struct.unpack_from(dyn_fmt, data, off + i * dyn_size)
                if tag == DT_NULL:
                    break
                entries.append((tag, val))

    # DT_STRTAB est une adresse virtuelle : il faut la convertir en offset fichier
    strtab = next((vaddr_to_off(v) for t, v in entries if t == DT_STRTAB), None)
    names = {DT_NEEDED: "NEEDED", DT_SONAME: "SONAME", DT_RPATH: "RPATH", DT_RUNPATH: "RUNPATH"}
    info["entries"] = [(names[t], cstr(strtab + v)) for t, v in entries
                       if t in names and strtab is not None]
    return info


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        if len(sys.argv) > 2:
            print(f"== {path}")
        try:
            info = elf_deps(path)
        except (OSError, ValueError, struct.error) as exc:
            print(f"erreur : {exc}")
            continue
        print(f"arch   : {info['arch']}")
        if info["interp"]:
            print(f"interp : {info['interp']}")
        if not info["dynamic"]:
            print("binaire statique, aucune dependance dynamique")
        for name, value in info["entries"]:
            print(f"{name:<7}: {value}")


if __name__ == "__main__":
    main()
