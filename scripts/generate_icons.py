"""Generate Ligament icons from assets/icons/logo_mark.svg.

Requires CairoSVG, Pillow, and the system Cairo library.
Client assets: python scripts/generate_icons.py
Client + server assets: python scripts/generate_icons.py --server-root ../2fa
"""

import argparse
import io
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/icons/logo_mark.svg"
BACKGROUND = "#111827"
ICO_SIZES = [(size, size) for size in (16, 24, 32, 48, 64, 128, 256)]
MASTER_SIZE = 2048


def render_mark() -> Image.Image:
    data = cairosvg.svg2png(
        url=str(SOURCE), output_width=MASTER_SIZE, output_height=MASTER_SIZE
    )
    return Image.open(io.BytesIO(data)).convert("RGBA")


def generate_lockups() -> None:
    """Combine the mark and outlined lettering without depending on fonts."""
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    mark = ET.parse(SOURCE).getroot()
    wordmark = ET.parse(ROOT / "assets/icons/wordmark.svg").getroot()
    width = 180 + int(wordmark.attrib["width"])
    mark_graphic = "".join(
        ET.tostring(child, encoding="unicode") for child in mark
        if not child.tag.endswith("title")
    )
    lettering = "".join(
        ET.tostring(child, encoding="unicode") for child in wordmark
        if not child.tag.endswith("title")
    )
    for name, color in (("logo", "#111827"), ("logo_light", "#f8fafc")):
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} 160" '
            f'width="{width}" height="160">\n'
            '<title>Ligament 2FA</title>\n'
            f'<g transform="scale(0.8)">{mark_graphic}</g>\n'
            f'<g transform="translate(180 0)">{lettering}</g>\n</svg>\n'
        ).replace("currentColor", color)
        svg = "\n".join(line.rstrip() for line in svg.splitlines()) + "\n"
        destination = ROOT / "assets/icons" / name
        destination.with_suffix(".svg").write_text(svg, encoding="utf-8")
        cairosvg.svg2png(
            bytestring=svg.encode("utf-8"),
            write_to=str(destination.with_suffix(".png")),
            output_width=width * 3, output_height=480,
        )


def app_icon(
    master: Image.Image, size: int, *, rounded: bool = False, scale: float = 0.94
) -> Image.Image:
    """Render at master resolution before downsampling, including small ICOs."""
    canvas = Image.new("RGBA", master.size, BACKGROUND)
    mark_size = round(MASTER_SIZE * scale)
    mark = master.resize((mark_size, mark_size), Image.Resampling.LANCZOS)
    offset = (MASTER_SIZE - mark_size) // 2
    canvas.alpha_composite(mark, (offset, offset))
    if rounded:
        alpha = Image.new("L", master.size, 0)
        ImageDraw.Draw(alpha).rounded_rectangle(
            (0, 0, MASTER_SIZE - 1, MASTER_SIZE - 1),
            radius=round(MASTER_SIZE * 0.22),
            fill=255,
        )
        canvas.putalpha(alpha)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def generate_clients(master: Image.Image) -> None:
    master.resize((1024, 1024), Image.Resampling.LANCZOS).save(
        ROOT / "assets/icons/logo_mark.png"
    )
    app_icon(master, 1024, rounded=True).save(ROOT / "assets/icons/app_icon.png")
    ico = ROOT / "assets/icons/app_icon.ico"
    app_icon(master, 256, rounded=True).save(ico, sizes=ICO_SIZES)
    shutil.copyfile(ico, ROOT / "windows/runner/resources/app_icon.ico")

    for platform in ("macos", "ios"):
        folder = ROOT / platform / "Runner/Assets.xcassets/AppIcon.appiconset"
        entries = json.loads((folder / "Contents.json").read_text())["images"]
        for entry in entries:
            if "filename" not in entry:
                continue
            size = round(
                float(entry["size"].split("x")[0])
                * float(entry["scale"].rstrip("x"))
            )
            image = app_icon(master, size, rounded=platform == "macos")
            if platform == "ios":
                image = image.convert("RGB")
            image.save(folder / entry["filename"])

    for density, size in (
        ("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
        ("xxhdpi", 144), ("xxxhdpi", 192),
    ):
        image = app_icon(master, size).convert("RGB")
        image.save(ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png")

    pixels = app_icon(master, 256).tobytes()
    header = [
        "// Generated from assets/icons/logo_mark.svg; 256x256 ARGB.",
        "#pragma once",
        "#include <stdint.h>",
        "static const uint32_t c_AppLogoWidth = 256;",
        "static const uint32_t c_AppLogoHeight = 256;",
        "static const uint32_t c_AppLogoPixels[256 * 256] = {",
    ]
    for offset in range(0, len(pixels), 64):
        block = pixels[offset:offset + 64]
        row = ", ".join(
            f"0x{a:02X}{r:02X}{g:02X}{b:02X}"
            for r, g, b, a in zip(block[0::4], block[1::4], block[2::4], block[3::4])
        )
        header.append("    " + row + ",")
    header.append("};")
    (ROOT / "windows/credential_provider/app_logo_data.h").write_text(
        "\n".join(header) + "\n", encoding="utf-8"
    )


def generate_server(master: Image.Image, server_root: Path) -> None:
    static = server_root / "internal/web/static"
    shutil.copyfile(SOURCE, static / "logo-mark.svg")
    shutil.copyfile(ROOT / "assets/icons/logo.svg", static / "logo.svg")
    shutil.copyfile(ROOT / "assets/icons/logo_light.svg", static / "logo-light.svg")
    shutil.copyfile(ROOT / "assets/icons/logo_light.svg", static / "pwa/logo.svg")
    app_icon(master, 256, rounded=True).save(static / "favicon.ico", sizes=ICO_SIZES)
    for size in (192, 512):
        app_icon(master, size, rounded=True).save(static / f"pwa/icon-{size}.png")
        # The complete mark fits inside the maskable icon's central safe circle.
        app_icon(master, size, scale=0.75).convert("RGB").save(
            static / f"pwa/icon-maskable-{size}.png"
        )
    app_icon(master, 180).convert("RGB").save(static / "pwa/apple-touch-icon.png")
    splash = Image.new("RGB", (1290, 2796), "#0b0f19")
    mark = master.resize((512, 512), Image.Resampling.LANCZOS)
    splash.paste(mark, ((1290 - 512) // 2, (2796 - 512) // 2), mark)
    splash.save(static / "pwa/apple-touch-startup.png")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--server-root", type=Path,
        help="Also update the checked-out Ligament server's embedded brand assets",
    )
    args = parser.parse_args()
    server_root = args.server_root.resolve() if args.server_root else None
    if server_root and not (server_root / "internal/web/static/pwa").is_dir():
        parser.error("--server-root must point to a Ligament server checkout")
    master = render_mark()
    generate_lockups()
    generate_clients(master)
    if server_root:
        generate_server(master, server_root)
    print("Generated client icons" + (" and server branding assets" if server_root else ""))


if __name__ == "__main__":
    main()
