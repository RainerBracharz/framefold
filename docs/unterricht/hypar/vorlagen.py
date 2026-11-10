"""Druckbare Faltvorlagen (A4, Vektor-PDF) ohne Foto: Hypar, Kreisfalte, Miura-ori.
Gleiche Geometrie wie in FrameFold (Algorithms.concentricPleat / miuraOri).
Hypar und Kreisfalte nach CreasePatternScripts/Hypar des Origami Simulator
(Amanda Ghassaei, MIT-Lizenz). Aufruf: python3 vorlagen.py"""
import math, os

def concentric(cx, cy, half, segments, pleats):
    square = segments == 4
    outer = half * math.sqrt(2) if square else half
    spacing = outer / (2 * pleats + 2)
    turn = math.pi / 4 if square else 0
    pt = lambda r, i: (cx + r * math.cos(i / segments * 2 * math.pi + turn), cy + r * math.sin(i / segments * 2 * math.pi + turn))
    out = []
    ring = lambda r, k: out.extend((pt(r, i), pt(r, i + 1), k) for i in range(segments))
    ring(outer, 'C'); r = outer
    for _ in range(pleats):
        r -= spacing; ring(r, 'M')
        r -= spacing; ring(r, 'V')
    r -= spacing
    if square:
        ring(r, 'F')
        for i in range(4):
            out.append((pt(outer, i), pt(r, i), 'F')); out.append((pt(r, i), (cx, cy), 'F'))
    else:
        ring(r, 'C')
    return out

def miura(x0, y0, w, h, cols=8, rows=8):
    cw, rh = w / cols, h / rows; amp = rh * 0.35
    X = lambda i: x0 + i * cw
    def Y(i, j):
        if j == 0: return y0
        if j == rows: return y0 + h
        return y0 + j * rh + (-amp / 2 if i % 2 == 0 else amp / 2)
    out = [((x0, y0), (x0 + w, y0), 'C'), ((x0 + w, y0), (x0 + w, y0 + h), 'C'),
           ((x0 + w, y0 + h), (x0, y0 + h), 'C'), ((x0, y0 + h), (x0, y0), 'C')]
    for j in range(1, rows):
        k = 'M' if j % 2 == 1 else 'V'
        out += [((X(i), Y(i, j)), (X(i + 1), Y(i + 1, j)), k) for i in range(cols)]
    for i in range(1, cols):
        out += [((X(i), Y(i, j)), (X(i), Y(i, j + 1)), 'M' if (i + j) % 2 == 0 else 'V') for j in range(rows)]
    return out

STYLE = {'M': ('0.85 0.16 0.12', '[6 2.5 1.2 2.5] 0', 0.9), 'V': ('0.12 0.32 0.85', '[4 3] 0', 0.9),
         'F': ('0.55 0.55 0.55', '[1 2.5] 0', 0.6), 'C': ('0.1 0.1 0.1', '[] 0', 1.0)}
W, H = 595.28, 841.89

def esc(s): return s.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')

def page(title, sub, creases, steps, legend_kinds):
    c = []
    def text(x, y, s, size=10, bold=False):
        c.append(f"BT /{'F2' if bold else 'F1'} {size} Tf {x:.1f} {H - y:.1f} Td ({esc(s)}) Tj ET")
    def line(a, b, k):
        col, dash, lw = STYLE[k]
        c.append(f"{col} RG {dash} d {lw} w {a[0]:.2f} {H - a[1]:.2f} m {b[0]:.2f} {H - b[1]:.2f} l S")
    text(48, 52, title, 14, True); text(48, 70, sub, 8)
    for a, b, k in creases: line(a, b, k)
    y = 610; x = 48
    names = {'M': 'Bergfalte', 'V': 'Talfalte', 'F': 'nur leicht vorknicken', 'C': 'schneiden'}
    for k in legend_kinds:
        line((x, y - 3), (x + 26, y - 3), k); text(x + 32, y, names[k], 8); x += 32 + 6 * len(names[k]) + 18
    y = 636
    for i, s in enumerate(steps, 1):
        words, cur = s.split(), ''
        lines = []
        for w_ in words:
            if len(cur) + len(w_) > 92: lines.append(cur); cur = w_
            else: cur = (cur + ' ' + w_).strip()
        lines.append(cur)
        text(48, y, f"{i}.", 9, True)
        for l in lines: text(62, y, l, 9); y += 13
        y += 4
    text(48, H - 30, "Faltmuster nach dem Origami Simulator von Amanda Ghassaei, entstanden mit Erik Demaine und Tomohiro Tachi (MIT-Lizenz).", 6.5)
    text(48, H - 20, "Unterrichtsmaterial FrameFold, CC BY 4.0, Rainer Bracharz. github.com/RainerBracharz/framefold", 6.5)
    return "\n".join(c).encode('cp1252')

def write_pdf(path, content):
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W} {H}] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>".encode(),
            b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"]
    out = b"%PDF-1.4\n"; offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offs)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    open(path, 'wb').write(out)

here = os.path.dirname(os.path.abspath(__file__))
S = 500; X0 = (W - S) / 2; Y0 = 90
write_pdf(os.path.join(here, 'faltvorlage-hypar.pdf'), page(
    "HYPAR", "FALTVORLAGE · BAUHAUS, VORKURS JOSEF ALBERS",
    concentric(W / 2, Y0 + S / 2, S / 2, 4, 7),
    ["Das Quadrat entlang der schwarzen Linie ausschneiden.",
     "Alle roten Quadrate als Bergfalte vorfalten, alle blauen als Talfalte. Mit einem Lineal und einem leeren Kugelschreiber vorher nachziehen, dann knickt das Papier sauber.",
     "Die Diagonalen nur leicht vorknicken.",
     "Von außen nach innen alle Ringe gleichzeitig zusammenschieben. Das Blatt wölbt sich zu einem Sattel."],
    ['M', 'V', 'F', 'C']))
write_pdf(os.path.join(here, 'faltvorlage-kreisfalte.pdf'), page(
    "KREISFALTE", "FALTVORLAGE · BAUHAUS",
    concentric(W / 2, Y0 + S / 2, S / 2, 96, 7),
    ["Den äußeren Kreis und das Loch in der Mitte ausschneiden.",
     "Die roten Kreise als Bergfalte, die blauen als Talfalte vorfalten. Kreise vorher mit einem leeren Kugelschreiber nachziehen.",
     "Den Ring rundherum zusammenschieben, bis er sich zu einem Sattel dreht. Das braucht Geduld und ist die schwierigste der drei Vorlagen."],
    ['M', 'V', 'C']))
write_pdf(os.path.join(here, 'faltvorlage-miura.pdf'), page(
    "MIURA-ORI", "FALTVORLAGE · KORYO MIURA",
    miura(X0, Y0, S, S),
    ["Das Quadrat entlang der schwarzen Linie ausschneiden.",
     "Erst alle Zickzacklinien falten, dann die senkrechten Linien. Rot ist Bergfalte, blau ist Talfalte.",
     "Zwei gegenüberliegende Ecken zusammenschieben. Das Blatt legt sich mit einer Bewegung flach zusammen und lässt sich ebenso wieder auseinanderziehen."],
    ['M', 'V', 'C']))
print('ok')
