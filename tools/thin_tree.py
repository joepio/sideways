"""Thins a Poly Haven card-foliage tree into game LODs.
Twig cards: keep a random share of the card clusters and scale each about its
centre so the crown keeps its volume. Trunk and branches: quadric decimation.
Writes raw arrays (.npz-like .bin + .json) that tools/bake_trees.gd turns into Godot meshes.

    python3 tools/thin_tree.py path/to/fir_tree_01.gltf /tmp/trees_raw   (Poly Haven fir_tree_01, 1k glTF)
"""
import json, sys, numpy as np, fast_simplification
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from components import components
src, out_dir = sys.argv[1], sys.argv[2]
g = json.load(open(src)); b = open(src.replace('.gltf', '.bin'), 'rb').read()
def acc(i):
    a = g['accessors'][i]; v = g['bufferViews'][a['bufferView']]
    n = {'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4}[a['type']]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a['componentType']]
    off = v.get('byteOffset',0) + a.get('byteOffset',0); cnt = a['count']
    arr = np.frombuffer(b, dtype=dt, count=cnt*n, offset=off)
    return arr.reshape(cnt, n) if n > 1 else arr
rng = np.random.default_rng(7)
LODS = {'near': (0.02, 6.0, 0.03), 'mid': (0.006, 9.0, 0.008)}  # twig share, twig scale, wood share
manifest = []
for mi, mesh in enumerate(g['meshes']):
    tree = 'abc'[mi]
    for lod, (share, scale, wood) in LODS.items():
        parts = {}
        for p in mesh['primitives']:
            mat = g['materials'][p['material']]['name'].replace('fir_tree_01_', '')
            pos = acc(p['attributes']['POSITION']).astype(np.float32)
            nrm = acc(p['attributes']['NORMAL']).astype(np.float32)
            uv = acc(p['attributes']['TEXCOORD_0']).astype(np.float32) if 'TEXCOORD_0' in p['attributes'] else np.zeros((len(pos),2),np.float32)
            tri = acc(p['indices']).reshape(-1, 3).astype(np.int64)
            kind = 'twig' if mat == 'twig' else 'bark'
            if kind == 'twig':
                lab = components(tri, len(pos))
                comp = lab[tri[:, 0]]
                uniq = np.unique(comp)
                keep = set(rng.choice(uniq, size=max(1, int(len(uniq) * share)), replace=False).tolist())
                mask = np.isin(comp, list(keep))
                t = tri[mask]
                used = np.unique(t)
                remap = -np.ones(len(pos), np.int64); remap[used] = np.arange(len(used))
                P = pos[used].copy(); N = nrm[used]; U = uv[used]; L = lab[used]
                # scale each cluster about its centroid
                order = np.argsort(L); Ls = L[order]
                starts = np.r_[0, np.nonzero(np.diff(Ls))[0] + 1]
                sums = np.add.reduceat(P[order], starts, axis=0); cnts = np.diff(np.r_[starts, len(Ls)])
                cent = np.zeros_like(P); cent[order] = np.repeat(sums / cnts[:, None], cnts, axis=0)
                P = cent + (P - cent) * scale
                T = remap[t]
            else:
                target = max(0.0, 1.0 - wood)
                if len(tri) * wood < 60:
                    continue
                Pd, Td = fast_simplification.simplify(pos, tri.astype(np.int32), target_reduction=target)
                # carry normals and uvs by nearest original vertex
                from numpy import linalg
                idx = np.empty(len(Pd), np.int64)
                for s in range(0, len(Pd), 4096):
                    d = ((Pd[s:s+4096, None, :] - pos[None, ::max(1, len(pos)//20000), :]) ** 2).sum(-1)
                    idx[s:s+4096] = d.argmin(1) * max(1, len(pos)//20000)
                P, N, U, T = Pd.astype(np.float32), nrm[idx], uv[idx], Td.astype(np.int64)
            key = mat
            parts.setdefault(key, []).append((P, N, U, T))
        for key, lst in parts.items():
            P = np.concatenate([x[0] for x in lst]); N = np.concatenate([x[1] for x in lst]); U = np.concatenate([x[2] for x in lst])
            T = np.concatenate([x[3] + sum(len(y[0]) for y in lst[:i]) for i, x in enumerate(lst)])
            name = f'{tree}_{lod}_{key}'
            with open(f'{out_dir}/{name}.bin', 'wb') as f:
                f.write(P.astype('<f4').tobytes()); f.write(N.astype('<f4').tobytes()); f.write(U.astype('<f4').tobytes()); f.write(T.astype('<i4').tobytes())
            manifest.append({'name': name, 'tree': tree, 'lod': lod, 'material': key, 'verts': int(len(P)), 'tris': int(len(T))})
            print(name, len(P), 'verts', len(T), 'tris', P.min(0).round(1), P.max(0).round(1))
json.dump(manifest, open(f'{out_dir}/manifest.json', 'w'), indent=1)
