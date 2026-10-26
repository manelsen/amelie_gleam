package main

// animatedWebPToFramesScript decodifica uma figurinha WebP animada em PNGs
// e escreve a lista ffconcat para o ffmpeg. Argumentos: entrada, diretório
// de quadros, máximo de quadros e máximo de pixels do canvas.
const animatedWebPToFramesScript = `
import os
import sys
from PIL import Image

def concat_quote(path):
    return "'" + path.replace("'", "'\\''") + "'"

def frame_duration_seconds(image):
    duration_ms = image.info.get("duration") or 100
    try:
        duration_ms = int(duration_ms)
    except Exception:
        duration_ms = 100
    duration_ms = max(20, min(duration_ms, 2000))
    return duration_ms / 1000.0

def main():
    if len(sys.argv) != 5:
        raise SystemExit("uso: decode_webp_animation.py entrada.webp diretorio_frames max_quadros max_pixels")

    input_path = sys.argv[1]
    frames_dir = sys.argv[2]
    max_frames = int(sys.argv[3])
    max_pixels = int(sys.argv[4])
    os.makedirs(frames_dir, exist_ok=True)

    # Só o decodificador WebP: o conteúdo vem de terceiros e Image.open,
    # sem essa restrição, detecta qualquer formato que o Pillow conheça.
    Image.MAX_IMAGE_PIXELS = max_pixels
    image = Image.open(input_path, formats=["WEBP"])
    width, height = image.size
    if width <= 0 or height <= 0 or width * height > max_pixels:
        raise SystemExit("canvas da figurinha excede o limite")
    frame_count = getattr(image, "n_frames", 1)
    if frame_count < 2:
        raise SystemExit("WebP sem animação útil")
    if frame_count > max_frames:
        raise SystemExit("figurinha com quadros demais")

    paths = []
    durations = []
    for index in range(frame_count):
        image.seek(index)
        frame = image.convert("RGBA")
        background = Image.new("RGBA", frame.size, (128, 128, 128, 255))
        background.alpha_composite(frame)
        output_path = os.path.join(frames_dir, f"frame_{index:05d}.png")
        background.convert("RGB").save(output_path)
        paths.append(output_path)
        durations.append(frame_duration_seconds(image))

    concat_path = os.path.join(frames_dir, "frames.txt")
    with open(concat_path, "w", encoding="utf-8") as concat:
        concat.write("ffconcat version 1.0\n")
        for path, duration in zip(paths, durations):
            concat.write(f"file {concat_quote(path)}\n")
            concat.write(f"duration {duration:.3f}\n")
        concat.write(f"file {concat_quote(paths[-1])}\n")

    print(f"frames={len(paths)}")

if __name__ == "__main__":
    main()
`
