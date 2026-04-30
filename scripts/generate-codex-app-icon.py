#!/usr/bin/env python3
"""Generate the Superartes Codex plugin PNG icon."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = REPO_ROOT / "assets" / "app-icon.png"
WIDTH = 256
HEIGHT = 256


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    """Create a PNG chunk with CRC."""
    checksum = zlib.crc32(chunk_type)
    checksum = zlib.crc32(data, checksum)
    return (
        struct.pack(">I", len(data))
        + chunk_type
        + data
        + struct.pack(">I", checksum & 0xFFFFFFFF)
    )


def pixel_at(x_position: int, y_position: int) -> tuple[int, int, int, int]:
    """Return the RGBA color for one icon pixel."""
    margin = 28
    stripe_bottom = 72
    letter_left = 66
    letter_right = 190
    letter_top = 86
    letter_bottom = 184

    if x_position < margin or x_position >= WIDTH - margin:
        return (37, 99, 235, 255)
    if y_position < margin or y_position >= HEIGHT - margin:
        return (37, 99, 235, 255)
    if margin <= y_position < stripe_bottom:
        return (245, 158, 11, 255)
    if letter_left <= x_position < letter_right and letter_top <= y_position < letter_top + 24:
        return (255, 255, 255, 255)
    if letter_left <= x_position < letter_left + 34 and letter_top <= y_position < letter_bottom:
        return (255, 255, 255, 255)
    if letter_left <= x_position < letter_right - 14 and 123 <= y_position < 147:
        return (255, 255, 255, 255)
    if letter_left <= x_position < letter_right and letter_bottom - 24 <= y_position < letter_bottom:
        return (255, 255, 255, 255)
    return (37, 99, 235, 255)


def build_image_data() -> bytes:
    """Build raw filtered RGBA scanlines."""
    rows: list[bytes] = []

    for y_position in range(HEIGHT):
        row = bytearray([0])
        for x_position in range(WIDTH):
            row.extend(pixel_at(x_position, y_position))
        rows.append(bytes(row))

    return b"".join(rows)


def main() -> None:
    """Write the PNG icon."""
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)

    signature = b"\x89PNG\r\n\x1a\n"
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0)
    image_data = zlib.compress(build_image_data(), level=9)

    OUTPUT_PATH.write_bytes(
        signature
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", image_data)
        + png_chunk(b"IEND", b"")
    )
    print(f"Wrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
