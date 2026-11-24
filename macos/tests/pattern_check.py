"""Counts, in a screenshot of d3d11_pattern_test's picture, how the columns of one row alternate:

    python3 pattern_check.py screenshot.png [row]

Prints the picture's width and, of the neighbouring pairs of pixels in the row, the share that
are one white and one black ("exact") and the share that are both near grey ("smoothed")."""
import os, struct, subprocess, sys
src = sys.argv[1]
bmp = src + ".bmp"
subprocess.run(["sips", "-s", "format", "bmp", src, "--out", bmp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
d = open(bmp, "rb").read()
os.remove(bmp)
off = struct.unpack_from("<I", d, 10)[0]
w, h = struct.unpack_from("<ii", d, 18)
bpp = struct.unpack_from("<H", d, 28)[0] // 8
rowsize = (w * bpp + 3) // 4 * 4
row = int(sys.argv[2]) if len(sys.argv) > 2 else abs(h) // 2
o = off + ((abs(h) - 1 - row) if h > 0 else row) * rowsize
lum = [sum(d[o + x * bpp:o + x * bpp + 3]) // 3 for x in range(w)]
pairs = list(zip(lum, lum[1:]))
exact = sum(1 for a, b in pairs if (a > 215 and b < 40) or (b > 215 and a < 40))
grey = sum(1 for a, b in pairs if 60 < a < 195 and 60 < b < 195)
print("width %d, row %d: %.1f%% exact, %.1f%% smoothed, first pixels %s" % (w, row, 100.0 * exact / len(pairs), 100.0 * grey / len(pairs), lum[:8]))
