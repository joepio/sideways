# Reproduce the authored pine crowns

This is a separate offline crown-replacement workflow. It does not retarget or
replace the original Poly Haven `tools/thin_tree.py -> tools/bake_trees.gd` path.
The three binary crown files are the normalized, fitted source data. No network
fetch, absolute machine path, original whole-tree duplicate, or Python geometry
extractor is required to reproduce these exact three crowns.

## Inputs and provenance

`manifest.json` records the CC BY 4.0 author/source URL, upstream repository commit,
original glTF/texture hashes, all fitting parameters, raw binary hashes and layout,
and expected original near-tree bounds. `ATTRIBUTION.txt`, `UPSTREAM-LICENSE.txt`
and `LICENSE-CC-BY-4.0.txt` accompany the derived raw data. Keep the equivalent
attribution in the game's credits when distributing the runtime assets.

The project must contain the pinned `assets/trees/authored_pine_albedo.png` and
`authored_pine_normal.png`, already imported; current `fir_[abc]_{near,mid}.res`;
`tools/bake_trees.gd` with `add_uv_tangents`; and a compatible `foliage.gdshader`.
Texture hashes are enforced. They are not duplicated in this tool-data folder.
`original_fit_input_sha256` records the original six meshes for provenance, not
an enforced whole-file lock: rebuilding after a crown-only promotion must work.
The builder enforces recorded near height/radius/camera size, known unique
surface names, triangle surfaces, one twig surface, no blend shapes/shadow mesh,
and compatible alpha/texture/height-driven-wind material use. It records the
actual six input hashes and shader hash in every build report. Changes to bark,
trunk geometry or materials therefore remain explicit inputs rather than being
silently rolled back to an archived tree. A changed tree fit requires a new raw
manifest and review. The shader compatibility check permits lighting changes;
it is a structural guard, not a shader equivalence proof.

## Guarded build (Godot 4.5.2)

Run in an isolated project checkout after import and the normal parser checks:

    godot --headless --path . --script res://tools/build_pine_crowns.gd -- --out-dir res://build/pine-crowns-review

`res://build/pine-crowns-review` must not exist. Only a single directory name
containing letters, digits, underscores or hyphens is allowed below `res://build`.
The builder refuses symlinked output parents and never writes `assets/`.
It validates all six candidate meshes before creating output. A failed disk write
can leave partial *candidate* files; the report is then marked failed. Do not
promote partial output. Successful output contains six meshes and build-report.json.

All existing non-twig packed surface dictionaries are retained and compared
exactly, including vertex/attribute/index bytes, LODs, flags, names and material
references. Mesh resource name, custom AABB, lightmap hint and metadata are copied.
Only twig is rebuilt: one winding conversion, UV-aligned tangents, original twig
material duplicated, two textures replaced and alpha_cut set to 0.42. Both LODs
use the same 1088-triangle authored crown; variant c mid grows from 576 triangles,
so performance must be measured in the full scene. Saving a new resource can
change serialization ordering; the invariant is packed non-twig content, not
whole-file identity. Build report input/output hashes make a run traceable.

## Review and promotion

1. Check the build report has six successful entries and exact non-twig equality.
   Run the existing `tests/tree_tangents.gd` generator regression. In the isolated
   checkout, place the six candidates at the canonical asset paths only when ready
   to validate the candidate, then run `tests/tree_tangents.gd -- --assets`.
2. Inspect multiple azimuths, near/mid transitions, dead branches and all weather.
   Zero dead-branch vertices outside a crown AABB does not prove concealment.
3. Regenerate all paired albedo/normal impostors with `tools/bake_impostors.gd` in
   that isolated candidate checkout. The default baker reads canonical tree paths;
   this builder's output directory alone does not select its input meshes. Require
   paired alpha equality/nonempty silhouettes and matching recorded bake sizes.
4. Review matching clear/wet/mist and moving split-screen captures and a balanced
   native4K benchmark. Promote all six meshes, the matching atlases and two pinned
   textures together only after that review. Keep the runtime asset credits.

The original Poly Haven workflow still regenerates the original fir twig cards.
To reproduce the authored crown set after that legacy bake, explicitly run this
separate replacement step and then bake matching impostors. Never silently mix
legacy near trees with authored-crown atlases, or the reverse.

The existing export preset excludes `tools/*`, `tests/*`, `build/*` and `*.md`.
Verify the actual export after integration; the raw/tool data are development
inputs, while the shipped game still needs accessible attribution.

## Validation status

Validated with Godot 4.5.2 in an isolated project on 2026-10-21 UTC.
Both the builder and a separate artifact-only verifier parsed successfully.
A fresh output build from all six already-authored-crown inputs passed 1,683
checks: complete packed surfaces, decoded arrays, LOD maps, mesh metadata/bounds
and material storage properties. All non-twig packed dictionaries were preserved.
The rebuilt meshes generated paired albedo/normal impostor atlases byte-identical
to the reviewed candidate; a second bake produced the same bytes again.
The exact prior canonical meshes were restored after this validation.

The reviewed candidate also passed UV tangent checks, multiple azimuth previews,
matched clear/wet/mist split-screen captures and a sampled movement/LOD sequence.
The matched native4K four-player ABBA test reduced mean frame time from 23.8841 ms
to 22.4116 ms (6.17%); mean per-run p95 fell from 31.1800 to 29.8895 ms. These
measurements do not establish the 120 FPS target or complete temporal stability.
The successful reproduction path was engine-tested; disk failure and every
invalid-input guard were not exhaustively injected. Re-run relevant validation
when changing geometry inputs, the material contract or the engine version.
