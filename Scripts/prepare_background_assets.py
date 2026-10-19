#!/usr/bin/env python3
"""Create offline, 16:9 Aurevix Cam scene exports from verified CC0 sources."""
from pathlib import Path
from PIL import Image, ImageCms, ImageOps
import numpy as np
import math

ROOT = Path(__file__).resolve().parents[1]
ORIGINALS = ROOT / "Assets/BackgroundLibrary/Originals"
EXPORTS = ROOT / "Assets/BackgroundLibrary/Exports"
PREVIEWS = ROOT / "Assets/BackgroundLibrary/Previews"
MASTER = (1920, 1080)
DELIVERY = (1280, 720)
PREVIEW = (480, 270)

# id, source filename, projection type, yaw, pitch, horizontal FOV, crop-center-y
SCENES = [
    ("beach-sunrise", "umhlanga_sunrise_pretty.jpg", "photo", 0, 0, 0, 0.46),
    ("quiet-office", "poly_haven_studio_tonemapped_equirectangular.jpg", "equirect", 120, 0, 85, 0.50),
    ("warm-lounge", "anniversary_lounge_tonemapped_equirectangular.jpg", "equirect", 270, 0, 85, 0.50),
    ("coastal-morning", "secluded_beach_pretty.jpg", "photo", 0, 0, 0, 0.48),
]


def srgb(image: Image.Image) -> Image.Image:
    profile = image.info.get("icc_profile")
    if profile:
        try:
            src = ImageCms.ImageCmsProfile(bytes(profile))
            dst = ImageCms.createProfile("sRGB")
            image = ImageCms.profileToProfile(image, src, dst, outputMode="RGB")
        except Exception:
            image = image.convert("RGB")
    else:
        image = image.convert("RGB")
    return image


def crop_rectilinear(image: Image.Image, center_y: float) -> Image.Image:
    w, h = image.size
    target = 16 / 9
    if w / h > target:
        crop_w = round(h * target)
        left = (w - crop_w) // 2
        image = image.crop((left, 0, left + crop_w, h))
    else:
        crop_h = round(w / target)
        center = min(max(center_y, 0), 1) * h
        top = round(min(max(center - crop_h / 2, 0), h - crop_h))
        image = image.crop((0, top, w, top + crop_h))
    return image


def equirect_to_rectilinear(image: Image.Image, yaw_degrees: float, pitch_degrees: float,
                             hfov_degrees: float, output_size: tuple[int, int]) -> Image.Image:
    src = np.asarray(image.convert("RGB"), dtype=np.float32)
    src_h, src_w = src.shape[:2]
    out_w, out_h = output_size
    hfov = math.radians(hfov_degrees)
    vfov = 2 * math.atan(math.tan(hfov / 2) * out_h / out_w)
    x = (np.arange(out_w, dtype=np.float32) + 0.5 - out_w / 2) / (out_w / 2) * math.tan(hfov / 2)
    y = -(np.arange(out_h, dtype=np.float32) + 0.5 - out_h / 2) / (out_h / 2) * math.tan(vfov / 2)
    xx, yy = np.meshgrid(x, y)
    zz = np.ones_like(xx)
    norm = np.sqrt(xx * xx + yy * yy + zz * zz)
    xx, yy, zz = xx / norm, yy / norm, zz / norm
    yaw, pitch = math.radians(yaw_degrees), math.radians(pitch_degrees)
    # Rotate camera ray by pitch, then yaw, without changing the horizon roll.
    y2 = yy * math.cos(pitch) + zz * math.sin(pitch)
    z2 = zz * math.cos(pitch) - yy * math.sin(pitch)
    x3 = xx * math.cos(yaw) + z2 * math.sin(yaw)
    z3 = z2 * math.cos(yaw) - xx * math.sin(yaw)
    longitude = np.arctan2(x3, z3)
    latitude = np.arcsin(np.clip(y2, -1, 1))
    px = ((longitude / (2 * math.pi) + 0.5) % 1) * src_w
    py = np.clip((0.5 - latitude / math.pi) * src_h, 0, src_h - 1.001)
    x0 = np.floor(px).astype(np.int32) % src_w
    x1 = (x0 + 1) % src_w
    y0 = np.floor(py).astype(np.int32)
    y1 = np.minimum(y0 + 1, src_h - 1)
    fx, fy = (px - np.floor(px))[..., None], (py - y0)[..., None]
    top = src[y0, x0] * (1 - fx) + src[y0, x1] * fx
    bottom = src[y1, x0] * (1 - fx) + src[y1, x1] * fx
    pixels = np.clip(top * (1 - fy) + bottom * fy, 0, 255).astype(np.uint8)
    return Image.fromarray(pixels, "RGB")


def save_jpeg(image: Image.Image, path: Path, quality: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "JPEG", quality=quality, subsampling=0, optimize=True, progressive=True)


def main() -> None:
    for name, source_name, kind, yaw, pitch, fov, crop_y in SCENES:
        source_path = ORIGINALS / source_name
        image = ImageOps.exif_transpose(Image.open(source_path))
        image = srgb(image)
        if kind == "equirect":
            master = equirect_to_rectilinear(image, yaw, pitch, fov, MASTER)
        else:
            master = crop_rectilinear(image, crop_y).resize(MASTER, Image.Resampling.LANCZOS)
        delivery = master.resize(DELIVERY, Image.Resampling.LANCZOS)
        preview = delivery.resize(PREVIEW, Image.Resampling.LANCZOS)
        save_jpeg(master, EXPORTS / "1920x1080" / f"{name}.jpg", 92)
        save_jpeg(delivery, EXPORTS / "1280x720" / f"{name}.jpg", 86)
        save_jpeg(preview, PREVIEWS / f"{name}.jpg", 82)
        print(f"{name}: source={image.size} projection={kind} yaw={yaw} pitch={pitch} hfov={fov} master={master.size} delivery={delivery.size}")

if __name__ == "__main__":
    main()
