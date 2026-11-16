# Baut die Test-Fixtures für FrameFoldTests/ExportMatrixTests.swift aus echtem
# Material. Aufruf: python -I make_fixtures.py <Zielordner>
# Eckmarken in der GEMEINTEN Ansicht: rot oben links, grün oben rechts,
# gelb unten links, blau unten rechts – je einmal in der Ecke und einmal nahe
# der Bildmitte (Mitte ± 14 % der kurzen Kante), damit sie jeden Zuschnitt überleben.
import os, subprocess, sys, shutil
from PIL import Image, ImageOps, ImageDraw, ImageFilter
import numpy as np

OUT = sys.argv[1]
WORK = "/private/tmp/ff-export-qa"
RB = WORK + "/src/rb/f%02d.png"
L59 = "/Users/rbracharz/Desktop/05_Projekte/framefold-spot/archiv-quellen/Learning1959.mp4"
os.makedirs(OUT, exist_ok=True)

RED, GREEN, YELLOW, BLUE = (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255)

def mark(img):
    img = img.convert("RGB").copy()
    w, h = img.size
    s = min(w, h)
    m = round(0.07 * s)
    d = round(0.14 * s)
    dr = ImageDraw.Draw(img)
    # Ecken
    dr.rectangle([0, 0, m - 1, m - 1], fill=RED)
    dr.rectangle([w - m, 0, w - 1, m - 1], fill=GREEN)
    dr.rectangle([0, h - m, m - 1, h - 1], fill=YELLOW)
    dr.rectangle([w - m, h - m, w - 1, h - 1], fill=BLUE)
    # Mitte
    cx, cy = w // 2, h // 2
    for (sx, sy, c) in [(-1, -1, RED), (1, -1, GREEN), (-1, 1, YELLOW), (1, 1, BLUE)]:
        x, y = cx + sx * d, cy + sy * d
        dr.rectangle([x - m // 2, y - m // 2, x + m // 2 - 1, y + m // 2 - 1], fill=c)
    return img

# gespeicherte Pixel = Umkehrung der Anzeige-Drehung
INVERSE = {1: None, 2: Image.FLIP_LEFT_RIGHT, 3: Image.ROTATE_180, 4: Image.FLIP_TOP_BOTTOM,
           5: Image.TRANSPOSE, 6: Image.ROTATE_90, 7: Image.TRANSVERSE, 8: Image.ROTATE_270}

def save_jpeg(intended, name, o, quality=84):
    stored = intended if INVERSE[o] is None else intended.transpose(INVERSE[o])
    exif = Image.Exif()
    exif[0x0112] = o
    exif[0x010F] = "Apple"      # Make – wie eine Kamera
    path = os.path.join(OUT, name)
    stored.save(path, "JPEG", quality=quality, exif=exif)
    # Gegenprobe mit PILs eigener Umsetzung
    back = ImageOps.exif_transpose(Image.open(path))
    assert back.size == intended.size, (name, back.size, intended.size)
    diff = np.abs(np.asarray(back, dtype=int) - np.asarray(intended, dtype=int)).mean()
    assert diff < 6, (name, diff)
    return path

def crop_center(img, ratio):
    w, h = img.size
    if w / h > ratio:
        nw = round(h * ratio); x = (w - nw) // 2
        return img.crop((x, 0, x + nw, h))
    nh = round(w / ratio); y = (h - nh) // 2
    return img.crop((0, y, w, y + nh))

def raw(n):
    return Image.open(RB % n).convert("RGB")

_H = {}
def shake(k):
    """Echte Verwacklung: Abbildung von Bild 1 auf Bild k der Aufnahme aus der Hand (per Merkmalsabgleich gemessen)."""
    if k not in _H:
        import cv2
        g1 = cv2.cvtColor(np.asarray(raw(1)), cv2.COLOR_RGB2GRAY); gk = cv2.cvtColor(np.asarray(raw(k)), cv2.COLOR_RGB2GRAY)
        orb = cv2.ORB_create(4000); k1, d1 = orb.detectAndCompute(g1, None); k2, d2 = orb.detectAndCompute(gk, None)
        m = sorted(cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True).match(d1, d2), key=lambda x: x.distance)[:600]
        H, _ = cv2.findHomography(np.float32([k1[x.queryIdx].pt for x in m]), np.float32([k2[x.trainIdx].pt for x in m]), cv2.RANSAC, 3.0)
        _H[k] = H; print("Verwacklung Bild", k, np.round(H, 4).tolist())
    return _H[k]

def rb(n):
    # Bilder 1 bis 3 der Aufnahme zeigen einen Paketaufkleber mit Name und
    # Adresse; sie gehören nicht ins öffentliche Repo. Ersatz: das Bild der
    # Kopfhörerschachtel (Bild 5), bewegt mit der echten, aus den Bildern 1 bis 3
    # gemessenen Verwacklung. Motiv und Bewegung sind echt, nur nicht aus demselben Bild.
    if n in (1, 2, 3):
        import cv2
        src = np.asarray(raw(5)); h, w = src.shape[:2]
        if n == 1: return Image.fromarray(src)
        return Image.fromarray(cv2.warpPerspective(src, shake(n), (w, h), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT))
    return raw(n)

def edge_ok(img, name):
    a = np.asarray(img.convert("L"), dtype=float)
    for label, strip in [("oben", a[:3]), ("unten", a[-3:]), ("links", a[:, :3]), ("rechts", a[:, -3:])]:
        assert strip.mean() > 30, (name, label, strip.mean())

# Fotosätze (gemeinte Ansicht), je drei Bilder
SETS = {
    # hochkant 3:4 – Kopfhörerschachtel, dieselbe Ansicht mit echter (gemessener) Verwacklung
    "p34": [crop_center(rb(n), 3 / 4).resize((480, 640), Image.LANCZOS) for n in (1, 2, 3)],
    # quer 4:3 – Kopfhörer, ruhige Ansicht
    "l43": [crop_center(rb(n), 4 / 3).resize((640, 480), Image.LANCZOS) for n in (9, 10, 11)],
    # hochkant 9:16 – Kopfhörer
    "p916": [rb(n).resize((360, 640), Image.LANCZOS) for n in (12, 13, 14)],
    # quer 16:9 – drei verschiedene Szenen (aus der Hand, jedes Bild anders)
    "l169": [crop_center(rb(n), 16 / 9).resize((640, 360), Image.LANCZOS) for n in (4, 5, 9)],
}
count = 0
for key, frames in SETS.items():
    for i, f in enumerate(frames):
        edge_ok(f, f"{key}-{i}")
        m = mark(f)
        for o in (1, 3, 6, 8):
            save_jpeg(m, f"exq-{key}-o{o}-{i + 1}.jpg", o); count += 1
# gespiegelte Vermerke (Bildbearbeitung, Scanner): je ein Bild
for o in (2, 4, 5, 7):
    save_jpeg(mark(SETS["p34"][0]), f"exq-p34-o{o}-1.jpg", o); count += 1
# gemischte Größen: groß hochkant mit Vermerk 6, klein im selben Verhältnis, ungerade Maße
big = mark(crop_center(rb(5), 3 / 4).resize((900, 1200), Image.LANCZOS))
save_jpeg(big, "exq-big34-o6-1.jpg", 6, quality=80)
small = mark(crop_center(rb(2), 3 / 4).resize((240, 320), Image.LANCZOS))
save_jpeg(small, "exq-small34-o1-1.jpg", 1)
for i, n in enumerate((9, 10, 11)):
    odd = crop_center(rb(n), 443 / 961).resize((443, 961), Image.LANCZOS)
    edge_ok(odd, "odd")
    save_jpeg(mark(odd), f"exq-odd-o1-{i + 1}.jpg", 1)
    save_jpeg(mark(odd), f"exq-odd-o6-{i + 1}.jpg", 6)
# Graustufen-JPEG (ein Kanal) aus dem Archivfilm, quer 4:3
subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "100", "-i", L59, "-frames:v", "1", WORK + "/src/l59_100.png"], check=True)
gray = Image.open(WORK + "/src/l59_100.png").convert("L")
exif = Image.Exif(); exif[0x0112] = 1
gray.save(os.path.join(OUT, "exq-gray43-o1-1.jpg"), "JPEG", quality=84, exif=exif)

# HEIC über sips (macOS), aus einem aufrechten und einem gedrehten JPEG
for o in (1, 6):
    src = os.path.join(OUT, f"exq-p34-o{o}-1.jpg")
    dst = os.path.join(OUT, f"exq-p34-o{o}-1.heic")
    r = subprocess.run(["sips", "-s", "format", "heic", "-s", "formatOptions", "70", src, "--out", dst],
                       capture_output=True, text=True)
    print("sips", o, r.returncode, r.stderr.strip()[:200])

# Videos: gemeinte Ansicht → Pixel zurückgedreht speichern → Dreh-Vermerk setzen
VID = WORK + "/vid"
os.makedirs(VID, exist_ok=True)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "100", "-i", L59, "-frames:v", "8", VID + "/l59-%d.png"], check=True)
land = [mark(Image.open(VID + f"/l59-{i}.png").convert("RGB")) for i in range(1, 9)]          # 640×480
port = [mark(rb(n).resize((360, 640), Image.LANCZOS)) for n in range(9, 17)]                   # 360×640
for f in land + port:
    edge_ok(f, "video")
# rotate = Grad im Uhrzeigersinn, um die die gespeicherten Pixel zur Anzeige gedreht werden
PLAN = {0: (land, None), 180: (land, Image.ROTATE_180), 90: (port, Image.ROTATE_90), 270: (port, Image.ROTATE_270)}
for rot, (frames, inv) in PLAN.items():
    d = VID + f"/r{rot}"
    os.makedirs(d, exist_ok=True)
    for i, f in enumerate(frames):
        (f if inv is None else f.transpose(inv)).save(d + f"/{i}.png")
        f.save(d + f"/want-{i}.png")
    for codec, args in (("h264", ["-c:v", "libx264", "-crf", "20"]),
                        ("hevc", ["-c:v", "libx265", "-crf", "22", "-tag:v", "hvc1", "-x265-params", "log-level=error"])):
        raw = d + f"/raw-{codec}.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", "10", "-i", d + "/%d.png",
                        *args, "-pix_fmt", "yuv420p", "-movflags", "+faststart", raw], check=True)
        dst = os.path.join(OUT, f"exq-video-r{rot}-{codec}.mp4")
        if rot == 0:
            shutil.copyfile(raw, dst)
        else:
            # -display_rotation zählt gegen den Uhrzeigersinn
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-display_rotation:v:0", str(-rot), "-i", raw,
                            "-c", "copy", "-movflags", "+faststart", dst], check=True)
        # Gegenprobe: ffmpeg dreht beim Dekodieren selbst; Ergebnis muss die gemeinte Ansicht sein
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", dst, "-frames:v", "1", d + f"/check-{codec}.png"], check=True)
        got = Image.open(d + f"/check-{codec}.png").convert("RGB")
        want = frames[0]
        assert got.size == want.size, (dst, got.size, want.size)
        diff = np.abs(np.asarray(got, dtype=int) - np.asarray(want, dtype=int)).mean()
        assert diff < 8, (dst, diff)
        count += 1

total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
print(count, "Dateien geprüft,", len(os.listdir(OUT)), "im Ordner,", round(total / 1e6, 2), "MB")
