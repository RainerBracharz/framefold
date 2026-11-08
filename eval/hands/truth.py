# Wahrheit für Learning1959 (1 Bild/s): Nummern OHNE Hände/Arme/Menschen.
# Alles andere zeigt Hände, Arme oder einen Menschen. Von Hand beschriftet am 08.11.2026.
def ranges(*rs):
    s = set()
    for r in rs:
        a, b = (r, r) if isinstance(r, int) else r
        s |= set(range(a, b + 1))
    return s
NO_HANDS = ranges((1, 41), (113, 144), (149, 150), (155, 169), 179, 266, (384, 386),
                  (478, 481), 542, (615, 621))
