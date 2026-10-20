import numpy as np
def components(tri, nverts):
    parent = np.arange(nverts)
    def find_all(p):
        while True:
            q = p[p]
            if np.array_equal(q, p): return p
            p = q
    # union along triangle edges by repeated min-propagation
    a, b, c = tri[:,0], tri[:,1], tri[:,2]
    lab = np.arange(nverts)
    for _ in range(200):
        m = np.minimum(np.minimum(lab[a], lab[b]), lab[c])
        new = lab.copy()
        np.minimum.at(new, a, m); np.minimum.at(new, b, m); np.minimum.at(new, c, m)
        new = new[new]  # pointer jumping
        if np.array_equal(new, lab): break
        lab = new
    return lab
