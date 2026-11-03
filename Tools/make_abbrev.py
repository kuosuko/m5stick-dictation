"""Build Keyboard/Resources/abbrev.txt: McBopomofo phrases keyed by the first
Bopomofo symbol of each syllable, so 簡拼 like ㄏㄏㄏ finds 哈哈哈.

Same sorted format as data.txt, so the engine memory-maps it with ParselessLM.
usage: python3 Tools/make_abbrev.py Keyboard/Resources/data.txt Keyboard/Resources/abbrev.txt
"""
import sys
from collections import defaultdict

HEADER = "# format org.openvanilla.mcbopomofo.sorted\n"
PER_KEY = 40  # most likely phrases kept per abbreviation

src, dst = sys.argv[1], sys.argv[2]
rows = defaultdict(list)
with open(src, encoding="utf-8") as f:
    for line in f:
        if line.startswith("#"):
            continue
        parts = line.rstrip("\n").split(" ")
        if len(parts) != 3:
            continue
        reading, value, score = parts
        if reading.startswith("_") or value.startswith("MACRO@"):
            continue
        syllables = reading.split("-")
        if len(syllables) < 2:
            continue  # single syllables are expanded live from the main data
        key = "-".join(s[0] for s in syllables)
        rows[key].append((float(score), value))

lines = []
for key in sorted(rows):
    seen = set()
    for score, value in sorted(rows[key], key=lambda r: -r[0]):
        if value in seen:
            continue
        seen.add(value)
        lines.append(f"{key} {value} {score}\n")
        if len(seen) >= PER_KEY:
            break

with open(dst, "w", encoding="utf-8") as out:
    out.write(HEADER)
    out.writelines(lines)
print(f"{len(rows)} keys, {len(lines)} rows")
