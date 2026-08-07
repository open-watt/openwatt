# Parse a font .txt (the editable '#'/space art) and either preview a string or
# emit D source.  Column-major packing, one byte per 8 rows, LSB = topmost row --
# the same order the ST7565 page buffer wants.
#
#   python fontgen.py preview font_small.txt "HELLO 32.5A"
#   python fontgen.py check   font_small.txt
#   python fontgen.py d       font_small.txt > ../../src/driver/font/small.d
import re
import sys

BLOCK = re.compile(r"^U\+([0-9A-Fa-f]{4})\s+'(.)'\s+(\S+)")

FIRST, LAST = 0x20, 0x88

# Lowercase is folded onto the capitals; this font has no lowercase of its own.
ALIAS = {c: c - 0x20 for c in range(0x61, 0x7B)}

# codepoint -> (identifier, the character it maps from, how to show it in a comment)
# These take the slots straight after printable ASCII; 0x7F has no glyph of its own.
EXTRAS = {
    0x7F: ("ohm", "Ω", "Ω"),
    0x80: ("caret_down", "⌄", "⌄"),
    0x81: ("degree", "°", "°"),
    0x82: ("bolt", "⚡", "⚡"),
    0x83: ("check", "✓", "✓"),
    0x84: ("sun", "☀", "☀"),
    0x85: ("middot", "·", "·"),
    0x86: ("times", "×", "×"),
    0x87: ("plusminus", "±", "±"),
    0x88: ("nbsp", " ", "_"),   # prints as nothing, so the comment shows a stand-in
}

WIDTH_MASK = 7          # width nybble: bits 0-2 the width, bit 3 "stored raw"
RAW_FLAG = 8


def parse(path):
    glyphs = []          # (codepoint, name, [row strings])
    cp = name = None
    rows = []
    for lineno, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n").rstrip("\r")
        if line.startswith("|"):
            if cp is None:
                raise SystemExit(f"{path}:{lineno}: pixel row outside a glyph block")
            if not line.endswith("|"):
                raise SystemExit(f"{path}:{lineno}: row missing closing '|'")
            rows.append(line[1:-1])
            continue
        m = BLOCK.match(line)
        if m:
            if cp is not None:
                glyphs.append((cp, name, rows))
            cp = int(m.group(1), 16)
            name = m.group(3)
            rows = []
    if cp is not None:
        glyphs.append((cp, name, rows))

    height = max(len(r) for _, _, r in glyphs)
    for c, n, r in glyphs:
        if not (FIRST <= c <= LAST):
            raise SystemExit(f"{path}: glyph {n} (U+{c:04X}) is outside {FIRST:#04x}..{LAST:#04x}")
        if len(r) != height:
            raise SystemExit(f"{path}: glyph {n} (U+{c:04X}) has {len(r)} rows, expected {height}")
        widths = {len(x) for x in r}
        if len(widths) != 1:
            raise SystemExit(f"{path}: glyph {n} (U+{c:04X}) rows disagree on width: {sorted(widths)}")
        if widths.pop() > WIDTH_MASK:
            raise SystemExit(f"{path}: glyph {n} (U+{c:04X}) exceeds {WIDTH_MASK} columns; "
                             "bit 3 of the width nybble is the raw flag")
        for x in r:
            bad = set(x) - {" ", "#"}
            if bad:
                raise SystemExit(f"{path}: glyph {n} (U+{c:04X}) has stray {bad!r}; use only '#' and ' '")
    return height, glyphs


def pack(height, rows):
    pages = (height + 7) // 8
    out = []
    for col in range(len(rows[0])):
        for page in range(pages):
            b = 0
            for bit in range(8):
                y = page * 8 + bit
                if y < height and rows[y][col] == "#":
                    b |= 1 << bit
            out.append(b)
    return out


# A byte with bit 7 set stands for two columns of its low seven bits. Glyphs that
# need bit 7 as pixel data -- row 7, so the descenders and the underscore -- cannot
# play along, and are stored raw and flagged in the width nybble instead.
def encode(columns):
    if any(b & 0x80 for b in columns):
        return bytes(columns), True
    out, i = bytearray(), 0
    while i < len(columns):
        if i + 1 < len(columns) and columns[i] == columns[i + 1]:
            out.append(columns[i] | 0x80)
            i += 2
        else:
            out.append(columns[i])
            i += 1
    return bytes(out), False


def decode(data, offset, width, is_raw):
    if is_raw:
        return list(data[offset:offset + width])
    out = []
    bits = data[offset]
    while True:
        out.append(bits & 0x7F)
        if len(out) == width:
            return out
        if bits & 0x80:
            bits &= 0x7F
        else:
            offset += 1
            bits = data[offset]


def render(height, table, text, gap=1):
    canvas = [""] * height
    for ch in text:
        rows = table.get(ord(ch))
        if rows is None and 0x61 <= ord(ch) <= 0x7A:
            rows = table.get(ord(ch) - 0x20)
        if rows is None:
            continue
        for y in range(height):
            canvas[y] += rows[y] + " " * gap
    return "\n".join(canvas)


def layout(height, glyphs):
    enc = {}
    for cp, _, rows in glyphs:
        data, is_raw = encode(pack(height, rows))
        enc[cp] = (data, len(rows[0]), is_raw)

    # Shortest-common-superstring, greedy: drop anything already contained in a
    # longer glyph, then repeatedly merge the pair sharing the most bytes. Beats
    # feeding the glyphs in some order and appending, by a wide margin.
    def overlap(a, b):
        for n in range(min(len(a), len(b)) - 1, 0, -1):
            if a.endswith(b[:n]):
                return n
        return 0

    parts = []
    for k in sorted({e[0] for e in enc.values()}, key=lambda k: (-len(k), k)):
        if not any(k in p for p in parts):
            parts.append(k)

    while len(parts) > 1:
        best_n, best_i, best_j = 0, 0, 1
        for i, a in enumerate(parts):
            for j, b in enumerate(parts):
                if i != j:
                    n = overlap(a, b)
                    if n > best_n:
                        best_n, best_i, best_j = n, i, j
        if best_n == 0:
            break
        merged = parts[best_i] + parts[best_j][best_n:]
        parts = [p for k, p in enumerate(parts) if k not in (best_i, best_j)] + [merged]

    blob = b"".join(parts)
    slot = {}
    for cp, (data, width, is_raw) in enc.items():
        assert data in blob, "packed blob lost a glyph"
        slot[cp] = (blob.index(data), width, is_raw)
    for cp, target in ALIAS.items():
        if target in slot:
            slot[cp] = slot[target]

    # a coding scheme is only worth having if it survives a decode
    for cp, _, rows in glyphs:
        o, w, r = slot[cp]
        assert decode(blob, o, w, r) == pack(height, rows), f"U+{cp:04X} does not decode"
    return list(blob), slot


def emit_d(height, glyphs, out=sys.stdout):
    blob, slot = layout(height, glyphs)
    count = LAST - FIRST + 1
    empty = (0, 0, False)
    offsets = [slot.get(c, empty)[0] for c in range(FIRST, LAST + 1)]
    widths = [slot.get(c, empty)[1] for c in range(FIRST, LAST + 1)]
    raws = [slot.get(c, empty)[2] for c in range(FIRST, LAST + 1)]
    if max(offsets) > 0xFF:
        raise SystemExit(f"offset {max(offsets)} does not fit in a byte; bitmap is {len(blob)} bytes")

    nybbles = [w | (RAW_FLAG if r else 0) for w, r in zip(widths, raws)]
    padded = nybbles + [0] * (count & 1)
    packed = [padded[i] | (padded[i + 1] << 4) for i in range(0, len(padded), 2)]
    extras = sorted(EXTRAS)
    extra_base = min(EXTRAS) - FIRST

    p = lambda *a: print(*a, file=out)
    p("// Generated by tools/font/fontgen.py from tools/font/font_small.txt.")
    p("// Edit the .txt and regenerate; do not edit this file.")
    p("module driver.font.small;")
    p("")
    p("nothrow @nogc:")
    p("")
    p(f"enum font_small_height = {height};")
    p(f"enum font_small_first = 0x{FIRST:02X};")
    p(f"enum font_small_max_width = {max(widths)};")
    p("enum font_small_gap = 1;   // blank columns a renderer must insert between glyphs")
    p("")
    p("// The symbols with no ASCII slot. font_small_extra maps each to the character")
    p("// a caller would actually write, so lookup takes a wchar rather than a code.")
    p("enum : char")
    p("{")
    for cp in extras:
        p(f"    font_small_{EXTRAS[cp][0]} = 0x{cp:02X},")
    p("}")
    p("")
    # a non-printing character has to go in as an escape or the source is unreadable
    lit = lambda ch: f"'{ch}'" if ch.isprintable() else "'\\u%04X'" % ord(ch)
    p("immutable wchar[%d] font_small_extra = [ %s ];"
      % (len(extras), ", ".join(lit(EXTRAS[cp][1]) for cp in extras)))
    p("")
    p("// One byte per column, LSB = top row, run-length coded: a byte with bit 7 set")
    p("// stands for two columns of its low seven bits. Glyphs whose columns already")
    p("// appear elsewhere point into them, so offsets are neither ordered nor disjoint.")
    p(f"immutable ubyte[{len(blob)}] font_small_bitmap = [")
    for i in range(0, len(blob), 16):
        p("    " + " ".join(f"0x{b:02X}," for b in blob[i:i + 16]))
    p("];")
    p("")
    # font_small_glyph no longer guards against a zero width, because a hole in the
    # table would run its decode loop off the end of the buffer. Enforce it here.
    for c, w in zip(range(FIRST, LAST + 1), widths):
        if w == 0:
            raise SystemExit(f"U+{c:04X} has no glyph; a hole in the table would overrun the "
                             "decode buffer, so every slot must be filled or the range trimmed")

    rows = []
    i = 0
    while i < count:
        n = min(8, count - i)
        if i < extra_base < i + n:      # start the symbols on a line of their own
            n = extra_base - i
        rows.append((i, n))
        i += n

    p("// Indexed by c - font_small_first.")
    p(f"immutable ubyte[{count}] font_small_offset = [")
    for i, n in rows:
        row = " ".join(f"{offsets[j]:3d}," for j in range(i, i + n)).ljust(8 * 5 - 1)
        chars = "".join(EXTRAS[c][2] if c in EXTRAS else chr(c)
                        for c in range(FIRST + i, FIRST + i + n))
        p(f"    {row}   // {chars}")
    p("];")
    p("")
    p("// Two glyphs per byte: low nybble is the even index, high nybble the odd one.")
    p("// Within a nybble, bits 0-2 are the width and bit 3 means the glyph is stored")
    p("// raw because its pixels need bit 7. A width of zero means there is no glyph.")
    p(f"immutable ubyte[{len(packed)}] font_small_width = [")
    for i in range(0, len(packed), 12):
        p("    " + " ".join(f"0x{b:02X}," for b in packed[i:i + 12]))
    p("];")
    p("")
    p("// Table index for a character, or -1 if the font has no glyph for it.")
    p("int font_small_index(wchar c) pure")
    p("{")
    p("    if (c >= font_small_first && c < 0x7F)")
    p("        return c - font_small_first;")
    p("    foreach (i, extra; font_small_extra)")
    p("    {")
    p("        if (extra == c)")
    p(f"            return cast(int)i + {min(EXTRAS) - FIRST};")
    p("    }")
    p("    return -1;")
    p("}")
    p("")
    p("uint font_small_width_of(wchar c) pure")
    p("{")
    p("    immutable int i = font_small_index(c);")
    p("    if (i < 0)")
    p("        return 0;")
    p("    return (font_small_width[i >> 1] >> ((i & 1) * 4)) & 0x7;")
    p("}")
    p("")
    p("// Expands one glyph into buffer, which must hold font_small_max_width bytes.")
    p("// Returns the columns written, or zero if the font has no glyph for c.")
    p("uint font_small_glyph(wchar c, ubyte[] buffer)")
    p("{")
    p("    immutable int i = font_small_index(c);")
    p("    if (i < 0)")
    p("        return 0;")
    p("")
    p("    immutable uint nybble = (font_small_width[i >> 1] >> ((i & 1) * 4)) & 0xF;")
    p("    immutable uint width = nybble & 0x7;")
    p("    if (buffer.length < width)")
    p("        return 0;")
    p("")
    p("    uint o = font_small_offset[i];")
    p("    if (nybble & 0x8)")
    p("    {")
    p("        buffer[0 .. width] = font_small_bitmap[o .. o + width];")
    p("        return width;")
    p("    }")
    p("")
    p("    ubyte bits = font_small_bitmap[o];")
    p("    for (uint n = 0;;)")
    p("    {")
    p("        buffer[n] = bits & 0x7F;")
    p("        if (++n == width)")
    p("            return width;")
    p("        if (bits & 0x80)")
    p("            bits &= 0x7F;")
    p("        else")
    p("            bits = font_small_bitmap[++o];")
    p("    }")
    p("}")


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    height, glyphs = parse(path)
    if mode == "preview":
        print(render(height, {cp: rows for cp, _, rows in glyphs}, sys.argv[3]))
    elif mode == "d":
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        emit_d(height, glyphs)
    elif mode == "check":
        blob, slot = layout(height, glyphs)
        offsets = [slot[cp][0] for cp, _, _ in glyphs]
        raw = sum(len(pack(height, r)) for _, _, r in glyphs)
        coded = sum(len(encode(pack(height, r))[0]) for _, _, r in glyphs)
        print(f"{path}: {len(glyphs)} glyphs, height {height}")
        print(f"  bitmap      {len(blob)} bytes, max offset {max(offsets)} / 255")
        print(f"  tables      {LAST - FIRST + 1} offset + {(LAST - FIRST + 2) // 2} width bytes")
        print(f"  columns     {raw} raw -> {coded} run-length coded -> {len(blob)} packed")
        print(f"  stored raw  {', '.join(n for cp, n, _ in glyphs if slot[cp][2]) or 'none'}")
        seq = {n: encode(pack(height, r))[0] for _, n, r in glyphs}
        for name, k in sorted(seq.items()):
            hosts = sorted(n for n, hk in seq.items() if n != name and len(hk) > len(k) and k in hk)
            if hosts:
                print(f"  free        {name} in {', '.join(hosts)}")
        show = lambda c: f"'{chr(c)}'" if 0x21 <= c <= 0x7E else f"0x{c:02X}"
        absent = [c for c in range(FIRST, LAST + 1) if c not in slot]
        print(f"  absent      {' '.join(show(c) for c in absent) or 'none'}")
    else:
        raise SystemExit("mode must be preview|d|check")
