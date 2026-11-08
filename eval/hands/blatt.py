"""Kontaktbogen: alle Bilder eines Ordners, Treffer des Detektors rot umrandet.
Aufruf: python blatt.py archiv/name archiv/name.csv ausgabe_prefix [von bis]"""
import csv, sys, cv2, numpy as np
d, c, out = sys.argv[1:4]
hit = {r[0]: r[1] == "1" for r in csv.reader(open(c))}
names = sorted(hit)
a, b = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else (1, len(names))
names = names[a - 1:b]
W, H, COLS = 200, 150, 10
for page in range(0, len(names), 80):
    chunk = names[page:page + 80]
    rows = (len(chunk) + COLS - 1) // COLS
    sheet = np.full((rows * (H + 18), COLS * W, 3), 255, np.uint8)
    for i, n in enumerate(chunk):
        im = cv2.resize(cv2.imread(f"{d}/{n}"), (W - 6, H - 6))
        col = (0, 0, 220) if hit[n] else (200, 200, 200)
        im = cv2.copyMakeBorder(im, 3, 3, 3, 3, cv2.BORDER_CONSTANT, value=col)
        y, x = (i // COLS) * (H + 18), (i % COLS) * W
        sheet[y:y + H, x:x + W] = im
        cv2.putText(sheet, n.split("_")[1][:4], (x + 4, y + H + 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1)
    cv2.imwrite(f"{out}_{page // 80 + 1}.jpg", sheet, [cv2.IMWRITE_JPEG_QUALITY, 80])
    print(f"{out}_{page // 80 + 1}.jpg")
