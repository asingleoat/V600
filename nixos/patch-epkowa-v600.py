#!/usr/bin/env python3
"""Patch Epson's epkowa backend for V600 16-bit TPU scans.

The Nix overlay intentionally patches the unpacked epkowa source with a small
Python tool instead of shell sed snippets.  The script is idempotent, checks
the exact source sites it depends on, and fails loudly when Epson or nixpkgs
changes the backend shape.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
import tempfile


USB_MAX_REQUEST_SIZE = "(self->interpreter ? 256 : 1024) * 1024"
USB_MAX_REQUEST_DECL = "static size_t channel_usb_max_request_size (const channel *);\n"
USB_MAX_REQUEST_IMPL = f"""
static size_t
channel_usb_max_request_size (const channel *self)
{{
  /* Increased buffer sizes for V600 16-bit TPU scanning. */
  return {USB_MAX_REQUEST_SIZE};
}}
"""


class PatchError(RuntimeError):
    pass


class PatchLog:
    def __init__(self) -> None:
        self.entries: list[str] = []

    def add(self, label: str, action: str) -> None:
        self.entries.append(f"{label}: {action}")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise PatchError(f"required epkowa source file is missing: {path}") from exc


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def replace_exact(
    text: str,
    before: str,
    after: str,
    label: str,
    log: PatchLog,
    *,
    allow_existing: bool = True,
) -> str:
    count = text.count(before)
    if count == 1:
        log.add(label, "applied")
        return text.replace(before, after, 1)
    if count == 0 and allow_existing and after in text:
        log.add(label, "already applied")
        return text
    raise PatchError(
        f"{label}: expected exactly one patch site, found {count}; "
        "upstream epkowa source changed"
    )


def insert_after_exact(
    text: str,
    anchor: str,
    insertion: str,
    label: str,
    log: PatchLog,
) -> str:
    if insertion in text:
        log.add(label, "already applied")
        return text
    count = text.count(anchor)
    if count != 1:
        raise PatchError(
            f"{label}: expected exactly one anchor, found {count}; "
            "upstream epkowa source changed"
        )
    log.add(label, "applied")
    return text.replace(anchor, anchor + insertion, 1)


def patch_channel_usb(root: Path, log: PatchLog) -> None:
    channel_h = read_text(root / "backend/channel.h")
    if "size_t (*max_request_size) (const struct channel *self);" not in channel_h:
        raise PatchError(
            "backend/channel.h no longer exposes channel.max_request_size; "
            "re-audit V600 USB buffer patch"
        )

    path = root / "backend/channel-usb.c"
    text = read_text(path)

    recv_decl = (
        "static ssize_t channel_usb_recv (channel *, void *,\n"
        "                                 size_t, SANE_Status *);\n"
    )
    text = insert_after_exact(
        text,
        recv_decl,
        "\n" + USB_MAX_REQUEST_DECL,
        "channel-usb max_request_size declaration",
        log,
    )

    text = replace_exact(
        text,
        "  self->max_size = 128 * 1024;\n",
        "  self->max_request_size = channel_usb_max_request_size;\n",
        "channel-usb initial ctor override",
        log,
    )
    text = replace_exact(
        text,
        "  self->max_size = 32 * 1024;\n",
        "  self->max_request_size = channel_usb_max_request_size;\n",
        "channel-usb interpreter ctor override",
        log,
    )

    if USB_MAX_REQUEST_IMPL in text:
        log.add("channel-usb max_request_size implementation", "already applied")
    else:
        existing = re.compile(
            r"\nstatic size_t\s+channel_usb_max_request_size "
            r"\(const channel \*self\)\s*\{.*?\n\}",
            re.DOTALL,
        )
        matches = list(existing.finditer(text))
        if matches:
            if len(matches) != 1:
                raise PatchError(
                    "channel-usb max_request_size implementation: expected at most "
                    f"one existing function, found {len(matches)}"
                )
            text = text[: matches[0].start()] + USB_MAX_REQUEST_IMPL + text[matches[0].end() :]
            log.add("channel-usb max_request_size implementation", "normalized")
        else:
            text = text.rstrip() + "\n" + USB_MAX_REQUEST_IMPL
            log.add("channel-usb max_request_size implementation", "applied")

    if text.count("self->max_request_size = channel_usb_max_request_size;") != 2:
        raise PatchError("channel-usb ctor override validation failed")
    if text.count(USB_MAX_REQUEST_DECL) != 1:
        raise PatchError("channel-usb declaration validation failed")
    if USB_MAX_REQUEST_SIZE not in text:
        raise PatchError("channel-usb implementation validation failed")

    write_text(path, text)


def patch_epkowa(root: Path, log: PatchLog) -> None:
    path = root / "backend/epkowa.c"
    text = read_text(path)
    old = "s->hw->channel->max_size"
    new_spaced = "s->hw->channel->max_request_size (s->hw->channel)"
    new_unspaced = "s->hw->channel->max_request_size(s->hw->channel)"

    count = text.count(old)
    if count:
        text = text.replace(old, new_spaced)
        log.add("epkowa raw channel max_size call sites", f"replaced {count}")
    elif new_spaced in text or new_unspaced in text:
        log.add("epkowa raw channel max_size call sites", "already absent")
    else:
        raise PatchError(
            "epkowa channel request-size call site changed; expected either the "
            "old raw max_size field or the current max_request_size callback"
        )

    if old in text:
        raise PatchError("epkowa raw channel max_size validation failed")
    write_text(path, text)


def patch_dip(root: Path, log: PatchLog) -> None:
    path = root / "backend/dip-obj.c"
    text = read_text(path)

    before = (
        "  require (8 == buf->ctx.depth);\n"
        "\n"
        "  if (SANE_FRAME_RGB != buf->ctx.format)\n"
        "    return;\n"
        "\n"
        "  data = buf->ptr;\n"
    )
    after = (
        "  require (buf->ctx.depth == 8 || buf->ctx.depth == 16);\n"
        "\n"
        "  if (SANE_FRAME_RGB != buf->ctx.format)\n"
        "    return;\n"
        "\n"
        "  if (buf->ctx.depth == 16)\n"
        "    return;\n"
        "\n"
        "  data = buf->ptr;\n"
    )
    text = replace_exact(
        text,
        before,
        after,
        "dip 16-bit depth guard and profile bypass",
        log,
    )

    if "require (8 == buf->ctx.depth);" in text:
        raise PatchError("dip depth guard validation failed")
    if text.count("if (buf->ctx.depth == 16)\n    return;") != 1:
        raise PatchError("dip 16-bit bypass validation failed")

    write_text(path, text)


def patch_source_tree(root: Path) -> list[str]:
    log = PatchLog()
    patch_channel_usb(root, log)
    patch_epkowa(root, log)
    patch_dip(root, log)
    return log.entries


def write_fixture(root: Path) -> None:
    backend = root / "backend"
    backend.mkdir()
    (backend / "channel.h").write_text(
        "typedef struct channel {\n"
        "  size_t (*max_request_size) (const struct channel *self);\n"
        "} channel;\n",
        encoding="utf-8",
    )
    (backend / "channel-usb.c").write_text(
        "static ssize_t channel_usb_recv (channel *, void *,\n"
        "                                 size_t, SANE_Status *);\n"
        "\n"
        "channel *\n"
        "channel_usb_ctor (channel *self, const char *dev_name, SANE_Status *status)\n"
        "{\n"
        "  self->recv = channel_usb_recv;\n"
        "  self->max_size = 128 * 1024;\n"
        "  self->max_size = 32 * 1024;\n"
        "  return self;\n"
        "}\n",
        encoding="utf-8",
    )
    (backend / "epkowa.c").write_text(
        "size_t max_req = s->hw->channel->max_size;\n",
        encoding="utf-8",
    )
    (backend / "dip-obj.c").write_text(
        "void\n"
        "dip_apply_color_profile (const void *self, const buffer *buf,\n"
        "                         const double profile[9])\n"
        "{\n"
        "  require (8 == buf->ctx.depth);\n"
        "\n"
        "  if (SANE_FRAME_RGB != buf->ctx.format)\n"
        "    return;\n"
        "\n"
        "  data = buf->ptr;\n"
        "}\n",
        encoding="utf-8",
    )


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_fixture(root)
        patch_source_tree(root)
        patch_source_tree(root)

        channel_usb = read_text(root / "backend/channel-usb.c")
        dip = read_text(root / "backend/dip-obj.c")
        if channel_usb.count("channel_usb_max_request_size") != 4:
            raise PatchError("self-test failed: channel_usb patch is not idempotent")
        if (
            "if (SANE_FRAME_RGB != buf->ctx.format)\n"
            "    return;\n"
            "\n"
            "  if (buf->ctx.depth == 16)\n"
            "    return;\n"
            "\n"
            "  data = buf->ptr;"
        ) not in dip:
            raise PatchError("self-test failed: 16-bit bypass placement is wrong")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "source_root",
        nargs="?",
        default=".",
        help="unpacked epkowa source root",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.self_test:
            self_test()
            print("epkowa V600 patcher self-test passed")
            return 0
        for entry in patch_source_tree(Path(args.source_root)):
            print(f"[V600 epkowa patch] {entry}")
        return 0
    except PatchError as exc:
        print(f"[V600 epkowa patch] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
