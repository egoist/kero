#!/usr/bin/env python3

import os
import pathlib
import struct
import sys


AR_MAGIC = b"!<arch>\n"
AR_HEADER_SIZE = 60
MACHO64_LITTLE_ENDIAN_MAGIC = b"\xcf\xfa\xed\xfe"
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 0x80000002
LC_SYMTAB = 0x2
N_TYPE_MASK = 0x0E
N_UNDF = 0x0
NLIST64_SIZE = 16
UNDEFINED_SYMBOL_RENAMES = {
    b"_pthread_create": b"_pa_pthread_cr",
    b"_qsort": b"_pa_qs",
}


def fail(message: str) -> None:
    raise SystemExit(f"[-] {message}")


def parse_decimal(raw: bytes, field: str) -> int:
    try:
        return int(raw.decode("ascii").strip())
    except ValueError:
        fail(f"invalid {field}: {raw!r}")


def rewrite_undefined_symbols(
    data: bytearray,
    object_start: int,
    member_end: int,
) -> dict[bytes, int]:
    object_size = member_end - object_start
    if object_size < 32:
        fail(f"truncated Mach-O header at offset {object_start}")

    command_count, command_bytes = struct.unpack_from("<II", data, object_start + 16)
    command_start = object_start + 32
    command_end = command_start + command_bytes
    if command_end > member_end:
        fail(f"Mach-O load commands cross member boundary at offset {object_start}")

    symtab = None
    cursor = command_start
    for _ in range(command_count):
        if cursor + 8 > command_end:
            fail(f"truncated Mach-O load command at offset {cursor}")
        command, command_size = struct.unpack_from("<II", data, cursor)
        if command_size < 8 or cursor + command_size > command_end:
            fail(f"invalid Mach-O load command size at offset {cursor}")
        if command == LC_SYMTAB:
            if command_size < 24 or symtab is not None:
                fail(f"invalid Mach-O symbol table command at offset {cursor}")
            symtab = struct.unpack_from("<IIII", data, cursor + 8)
        cursor += command_size

    if cursor != command_end:
        fail(f"Mach-O load command sizes do not match header at offset {object_start}")
    if symtab is None:
        return {name: 0 for name in UNDEFINED_SYMBOL_RENAMES}

    symbol_offset, symbol_count, string_offset, string_size = symtab
    symbol_bytes = symbol_count * NLIST64_SIZE
    if symbol_offset + symbol_bytes > object_size:
        fail(f"Mach-O symbol table crosses member boundary at offset {object_start}")
    if string_offset + string_size > object_size:
        fail(f"Mach-O string table crosses member boundary at offset {object_start}")

    string_start = object_start + string_offset
    string_end = string_start + string_size
    renamed = {name: 0 for name in UNDEFINED_SYMBOL_RENAMES}

    for index in range(symbol_count):
        entry = object_start + symbol_offset + index * NLIST64_SIZE
        string_index = struct.unpack_from("<I", data, entry)[0]
        symbol_type = data[entry + 4]
        if string_index == 0 or symbol_type & N_TYPE_MASK != N_UNDF:
            continue

        name_start = string_start + string_index
        if name_start >= string_end:
            fail(f"Mach-O symbol name crosses string table at offset {entry}")
        name_end = data.find(0, name_start, string_end)
        if name_end < 0:
            fail(f"unterminated Mach-O symbol name at offset {name_start}")

        name = bytes(data[name_start:name_end])
        replacement = UNDEFINED_SYMBOL_RENAMES.get(name)
        if replacement is None:
            continue
        if len(replacement) > len(name):
            fail(f"replacement symbol is longer than source: {name!r}")

        replacement_size = len(name) + 1
        data[name_start : name_start + replacement_size] = replacement.ljust(
            replacement_size,
            b"\0",
        )
        renamed[name] += 1

    return renamed


def convert_archive(source: pathlib.Path, destination: pathlib.Path) -> int:
    data = bytearray(source.read_bytes())
    if not data.startswith(AR_MAGIC):
        fail(f"not a static archive: {source}")

    cursor = len(AR_MAGIC)
    patched_objects = 0
    renamed_symbols = {name: 0 for name in UNDEFINED_SYMBOL_RENAMES}

    while cursor < len(data):
        if cursor + AR_HEADER_SIZE > len(data):
            fail(f"truncated archive member header at offset {cursor}")

        header = data[cursor : cursor + AR_HEADER_SIZE]
        if header[58:60] != b"`\n":
            fail(f"invalid archive member header at offset {cursor}")

        member_size = parse_decimal(header[48:58], "archive member size")
        member_start = cursor + AR_HEADER_SIZE
        member_end = member_start + member_size
        if member_end > len(data):
            fail(f"archive member crosses file boundary at offset {cursor}")

        object_start = member_start
        member_name = header[:16].decode("ascii", errors="replace").strip()
        if member_name.startswith("#1/"):
            name_size = parse_decimal(member_name[3:].encode("ascii"), "extended member name size")
            object_start += name_size
            if object_start > member_end:
                fail(f"extended member name crosses member boundary at offset {cursor}")

        if data[object_start : object_start + 4] == MACHO64_LITTLE_ENDIAN_MAGIC:
            if object_start + 12 > member_end:
                fail(f"truncated Mach-O header at offset {object_start}")

            cpu_type, cpu_subtype = struct.unpack_from("<II", data, object_start + 4)
            if cpu_type != CPU_TYPE_ARM64:
                fail(f"unexpected Mach-O CPU type 0x{cpu_type:08x} at offset {object_start}")
            if cpu_subtype not in {CPU_SUBTYPE_ARM64_ALL, CPU_SUBTYPE_ARM64E}:
                fail(f"unexpected ARM64 CPU subtype 0x{cpu_subtype:08x} at offset {object_start}")

            struct.pack_into("<I", data, object_start + 8, CPU_SUBTYPE_ARM64E)
            member_renames = rewrite_undefined_symbols(data, object_start, member_end)
            for name, count in member_renames.items():
                renamed_symbols[name] += count
            patched_objects += 1

        cursor = member_end + (member_size & 1)

    if cursor != len(data):
        fail(f"archive alignment crosses file boundary: {source}")
    if patched_objects == 0:
        fail(f"archive contains no ARM64 Mach-O objects: {source}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    temporary.write_bytes(data)
    os.replace(temporary, destination)
    for name, replacement in UNDEFINED_SYMBOL_RENAMES.items():
        print(
            f"[+] redirected {renamed_symbols[name]} {name.decode()} imports "
            f"to {replacement.decode()}"
        )
    return patched_objects


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} <arm64_archive> <arm64e_archive>")

    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    if not source.is_file():
        fail(f"archive not found: {source}")
    if source.resolve() == destination.resolve():
        fail("source and destination must differ")

    count = convert_archive(source, destination)
    print(f"[+] converted {count} Mach-O objects to arm64e: {destination}")


if __name__ == "__main__":
    main()
