#!/usr/bin/env python3
"""Собрать FreeBSD .pkg из DESTDIR-стейджа (формат OPNsense 26.7 / pkg tzst)."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import stat
import subprocess
import sys
import tarfile
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def abs_install_path(dest: str) -> str:
    name = dest.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    return "/" + name.lstrip("/")


def iter_stage_files(stage: Path) -> list[tuple[str, Path]]:
    files: list[tuple[str, Path]] = []
    for path in sorted(stage.rglob("*")):
        if path.is_dir() and not path.is_symlink():
            continue
        rel = "/" + path.relative_to(stage).as_posix()
        files.append((rel, path))
    return files


def file_mode(path: Path, dest: str) -> int:
    mode = path.stat().st_mode
    if dest.endswith("/rc.d/unbound") or "/sbin/" in dest or dest.endswith(".so"):
        return stat.S_IMODE(mode) or 0o755
    if path.is_symlink():
        return 0o777
    if mode & stat.S_IXUSR:
        return stat.S_IMODE(mode)
    return stat.S_IMODE(mode) or 0o644


def compact_manifest(manifest: dict) -> dict:
    skip = {"files", "directories", "scripts"}
    return {k: v for k, v in manifest.items() if k not in skip}


def add_text(tar: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    info = tarfile.TarInfo(name=name)
    info.size = len(data)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    tar.addfile(info, io.BytesIO(data))


def _set_tarinfo_name(info: tarfile.TarInfo, name: str) -> None:
    info.name = name
    if not info.name.startswith("/") and name.startswith("/"):
        info.__dict__["_name"] = name


def add_payload(tar: tarfile.TarFile, dest: str, path: Path) -> None:
    if path.is_symlink():
        info = tarfile.TarInfo()
        _set_tarinfo_name(info, dest)
        info.type = tarfile.SYMTYPE
        info.linkname = os.readlink(path)
        info.mode = 0o777
        info.uid = 0
        info.gid = 0
        info.uname = "root"
        info.gname = "wheel"
        tar.addfile(info)
        return
    data = path.read_bytes()
    info = tarfile.TarInfo()
    _set_tarinfo_name(info, dest)
    info.size = len(data)
    info.mode = file_mode(path, dest)
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    tar.addfile(info, io.BytesIO(data))


def _ustar_file_size(header: bytes) -> int:
    raw = header[124:136].split(b"\0", 1)[0].strip()
    return int(raw, 8) if raw else 0


def _ustar_checksum(header: bytearray) -> None:
    header[148:156] = b"        "
    chksum = sum(header)
    header[148:156] = f"{chksum:06o}".encode("ascii") + b"\0 "


def ensure_absolute_payload_names(blob: bytes) -> bytes:
    out = bytearray()
    off = 0
    n = len(blob)
    while off + 512 <= n:
        header = bytearray(blob[off : off + 512])
        if not any(header):
            out.extend(blob[off:])
            break
        name = header[:100].split(b"\0", 1)[0]
        prefix = header[345:500].split(b"\0", 1)[0]
        size = _ustar_file_size(header)
        data_end = off + 512 + ((size + 511) // 512) * 512
        if data_end > n:
            raise ValueError("truncated ustar archive")
        if name.startswith(b"+"):
            out.extend(blob[off:data_end])
        else:
            if prefix:
                raise ValueError(
                    f"ustar prefix split cannot add leading slash: {prefix!r}/{name!r}"
                )
            if not name.startswith(b"/"):
                new_name = b"/" + name
                if len(new_name) > 100:
                    raise ValueError(f"ustar name too long: {new_name!r}")
                header[:100] = new_name + b"\0" * (100 - len(new_name))
                _ustar_checksum(header)
            out.extend(header)
            out.extend(blob[off + 512 : data_end])
        off = data_end
    else:
        if off < n:
            out.extend(blob[off:])
    return bytes(out)


def compress_zstd(payload: bytes, dest: Path) -> None:
    try:
        import zstandard

        dest.write_bytes(zstandard.ZstdCompressor(level=19).compress(payload))
        print("==> compression: zstd (python)")
        return
    except ImportError:
        pass
    proc = subprocess.run(
        ["zstd", "-19", "-q", "-o", str(dest)],
        input=payload,
        check=False,
    )
    if proc.returncode == 0:
        print("==> compression: zstd (cli)")
        return
    import lzma

    dest.write_bytes(
        lzma.compress(payload, format=lzma.FORMAT_XZ, preset=9 | lzma.PRESET_EXTREME)
    )
    print("==> compression: xz")


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    manifest = load_json(args.manifest)
    files = iter_stage_files(args.stage)
    if not files:
        print("stage is empty", file=sys.stderr)
        return 1

    file_meta = {}
    flatsize = 0
    for dest, path in files:
        if path.is_symlink():
            file_meta[dest] = "1$" + hashlib.sha256(os.readlink(path).encode()).hexdigest()
            continue
        file_meta[dest] = "1$" + sha256_file(path)
        flatsize += path.stat().st_size

    manifest["files"] = file_meta
    manifest["flatsize"] = flatsize

    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        man = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
        compact = json.dumps(
            compact_manifest(manifest), ensure_ascii=False, indent=2
        ).encode("utf-8")
        add_text(tar, "+COMPACT_MANIFEST", compact)
        add_text(tar, "+MANIFEST", man)
        for dest, path in files:
            add_payload(tar, dest, path)

    payload = ensure_absolute_payload_names(raw.getvalue())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        args.output.unlink()
    compress_zstd(payload, args.output)
    print(f"==> {args.output} ({args.output.stat().st_size} bytes, {len(files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
