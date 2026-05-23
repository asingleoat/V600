#!/usr/bin/env python3
"""Create the V600 IR variant of Epson's proprietary interpreter.

The input tarball is already pinned by Nix.  This tool adds a second layer of
protection around the binary patch itself: it validates the original shared
object hash, checks each expected byte sequence, treats already-patched input
as idempotent, and validates the final patched hash.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import hashlib
import sys
import tempfile


EXPECTED_INPUT_SHA256 = "9daaf53b8b058b2037b7aac6da731805ca28dceec91e0a0f3e44ac6d289f405a"
EXPECTED_OUTPUT_SHA256 = "9627a8a1f3fc492f826265b9db620b3820f7e30da642adc1004765eeaff1e74a"

PATCHES = (
    {
        "name": "TPU+IR source validation",
        "offset": 0x17C83,
        "expected": bytes.fromhex("80 7a 1a 03"),
        "replacement": bytes.fromhex("80 7a 1a 04"),
        "why": "allow TPU+IR mode validation",
    },
    {
        "name": "TPU source selector",
        "offset": 0x18F01,
        "expected": bytes.fromhex("c6 40 1a 01"),
        "replacement": bytes.fromhex("c6 40 1a 03"),
        "why": "request the IR channel for TPU scans",
    },
)


class PatchError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def format_bytes(data: bytes) -> str:
    return data.hex(" ")


def patch_bytes(
    data: bytes,
    *,
    expected_input_sha256: str | None = EXPECTED_INPUT_SHA256,
    expected_output_sha256: str | None = EXPECTED_OUTPUT_SHA256,
) -> tuple[bytes, list[str]]:
    input_sha = sha256(data)
    if expected_input_sha256 is not None and expected_output_sha256 is not None:
        if input_sha == expected_input_sha256:
            pass
        elif input_sha == expected_output_sha256:
            pass
        else:
            raise PatchError(
                "unexpected interpreter sha256 "
                f"{input_sha}; expected original {expected_input_sha256} "
                f"or patched {expected_output_sha256}"
            )

    out = bytearray(data)
    log: list[str] = []
    for patch in PATCHES:
        name = str(patch["name"])
        offset = int(patch["offset"])
        expected = patch["expected"]
        replacement = patch["replacement"]
        assert isinstance(expected, bytes)
        assert isinstance(replacement, bytes)

        end = offset + len(expected)
        if end > len(out):
            raise PatchError(
                f"{name}: patch site {offset:#x} extends past EOF "
                f"(size {len(out)})"
            )
        actual = bytes(out[offset:end])
        if actual == expected:
            out[offset:end] = replacement
            log.append(f"{name}: applied at {offset:#x}")
        elif actual == replacement:
            log.append(f"{name}: already applied at {offset:#x}")
        else:
            raise PatchError(
                f"{name}: unexpected bytes at {offset:#x}; "
                f"actual {format_bytes(actual)}, expected {format_bytes(expected)}, "
                f"already-patched {format_bytes(replacement)}"
            )

    patched = bytes(out)
    output_sha = sha256(patched)
    if expected_output_sha256 is not None and output_sha != expected_output_sha256:
        raise PatchError(
            f"patched interpreter sha256 {output_sha} did not match "
            f"expected {expected_output_sha256}"
        )

    return patched, log


def patch_file(input_path: Path, output_path: Path) -> list[str]:
    data = input_path.read_bytes()
    patched, log = patch_bytes(data)
    output_path.write_bytes(patched)
    return log


def self_test() -> None:
    size = max(int(patch["offset"]) + len(patch["expected"]) for patch in PATCHES)
    data = bytearray(b"\x00" * size)
    for patch in PATCHES:
        offset = int(patch["offset"])
        expected = patch["expected"]
        assert isinstance(expected, bytes)
        data[offset : offset + len(expected)] = expected

    patched, _ = patch_bytes(
        bytes(data),
        expected_input_sha256=None,
        expected_output_sha256=None,
    )
    repatched, _ = patch_bytes(
        patched,
        expected_input_sha256=None,
        expected_output_sha256=None,
    )
    if patched != repatched:
        raise PatchError("self-test failed: patch is not idempotent")

    corrupt = bytearray(data)
    corrupt[int(PATCHES[0]["offset"])] ^= 0xFF
    try:
        patch_bytes(
            bytes(corrupt),
            expected_input_sha256=None,
            expected_output_sha256=None,
        )
    except PatchError:
        return
    raise PatchError("self-test failed: corrupted patch site was accepted")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", nargs="?")
    parser.add_argument("output", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.self_test:
            self_test()
            print("V600 interpreter IR patcher self-test passed")
            return 0
        if args.input is None or args.output is None:
            parser.error("input and output are required unless --self-test is used")
        for entry in patch_file(Path(args.input), Path(args.output)):
            print(f"[V600 interpreter patch] {entry}")
        print(f"[V600 interpreter patch] sha256={EXPECTED_OUTPUT_SHA256}")
        return 0
    except PatchError as exc:
        print(f"[V600 interpreter patch] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
