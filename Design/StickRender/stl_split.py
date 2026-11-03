import struct, sys, os
src, outdir = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
n = struct.unpack('<I', data[80:84])[0]
key = {}
def vid(p):
    k = (round(p[0], 4), round(p[1], 4), round(p[2], 4))
    if k not in key: key[k] = len(key)
    return key[k]
tris = []
for i in range(n):
    rec = data[84+i*50:84+i*50+50]
    vs = [struct.unpack('<fff', rec[12+v*12:24+v*12]) for v in range(3)]
    tris.append(([vid(p) for p in vs], vs, rec))
parent = list(range(len(key)))
def find(a):
    while parent[a] != a:
        parent[a] = parent[parent[a]]; a = parent[a]
    return a
for ids, _, _ in tris:
    a = find(ids[0])
    for b in ids[1:]:
        rb = find(b)
        if rb != a: parent[rb] = a
groups = {}
for ids, vs, rec in tris:
    groups.setdefault(find(ids[0]), []).append((vs, rec))
# keep the assembled copy (x < 30)
assembled = [g for g in groups.values() if min(v[0] for vs, _ in g for v in vs) < 30]
assembled.sort(key=lambda g: -len(g))
names = ["shell", "cover", "button"]
for name, g in zip(names, assembled):
    with open(os.path.join(outdir, name + ".stl"), 'wb') as f:
        f.write(b'\0' * 80)
        f.write(struct.pack('<I', len(g)))
        for _, rec in g:
            f.write(rec)
    zs = [v[2] for vs, _ in g for v in vs]
    print(name, len(g), "z", round(min(zs), 2), round(max(zs), 2))
