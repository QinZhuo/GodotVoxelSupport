# Godot Voxel Support
[English](https://github.com/QinZhuo/GodotVoxelSupport/blob/main/README.md) | [中文](https://github.com/QinZhuo/GodotVoxelSupport/blob/main/zh/README.md)

[Github](https://github.com/QinZhuo/GodotVoxelSupport) • [Asset Library](https://godotengine.org/asset-library/asset/4480)

> MagicaVoxel large voxel model support, faster import speed, automatic material mapping

- Merge models
- Multi-threaded Mesh generation
- Automatically generate metal, roughness, emissive, and other maps
- Solves the issue of slow import and crashing when importing .vox models larger than 256x256x256

![alt text](Showdown_of_Luck.png)

You can see the rendering effects of voxel models imported using this plugin in the game [Showdown of Luck](https://store.steampowered.com/app/4666770/?utm_source=github). It's an indie game I'm currently developing - an asynchronous multiplayer PVP auto-battler that combines cards with slot machines. Feel free to add it to your wishlist if you're interested!

> If your game is using this plugin, I'd be very happy if you could let me know. I'm also willing to help promote it through my channels.

![](/images/cards.png)
![](/images/teapot.png)

## Voxel Runtime Usage

### Architecture

### Directory layout

Directories are **layers, not topics**. A file only ever imports from its own layer or one below
it, so the dependency graph is acyclic by construction (enforced by static analysis, not by
discipline):

```
addons/VoxelSupport/
  plugin.gd            editor plugin entry (registers the four importers)
  Core/       (23)     leaf types with no layer dependency: VoxelChunk, VoxelVolume,
                       VoxelMaterial, VoxelSpec, QVoxelMate, QVoxelBlockCodec, NativeLoader,
                       VoxelStream / VoxelMemoryStream, VoxelDirtyLedger, VoxelLodGrid, ...
  Format/     ( 7)     .qvx / .vox byte layout: QVoxelFile, QVoxelBlockStream, QVoxelAsset,
                       VoxAsset, VoxAccess, VoxSpace, QVoxelFrame
  Model/      (10)     the in-memory project truth: QVoxelWorld, QVoxelModel, QVoxelNode,
                       QVoxelEvalEngine, QVoxelFileIO, VoxWriter, VoxAssetWorld, MeshVoxelWorld
  Mesh/       ( 4)     voxels -> geometry: VoxelMeshGenerator, VoxelChunkGenerator,
                       VoxelMaterialCache, MeshAccess (external mesh -> snapshot)
  Data/       ( 8)     runtime voxel data + persistence: QVoxelSource, QVoxelStream,
                       VoxelPersistence, VoxelAsyncLoader, VoxelEditKernel, VoxelRay,
                       VoxelPointCloudExporter, ProceduralVoxelSource
  Runtime/    ( 9)     everything that draws: VoxelRenderer, VoxelViewLayer, VoxelCollision,
                       VoxelParticleView, VoxelMesher, VoxelMeshBatch, VoxelDestructible,
                       VoxelDestructionPresenter, VoxelAnimator
  Tools/      ( 5)     scripting / export / preview / MCP: QVoxelScript, QVoxelBuilder,
                       QVoxelMeshExport, QVoxelPreview, QVoxelMCPTools
  Importer/   ( 5)     editor import plugins: mesh, MeshLibrary, .qvx source, noop
  Native/              GDExtension sources + prebuilt libraries
```

`Core → Format → Model → Mesh → Data → Runtime → Tools`, with `Importer` alongside `Tools`:
nothing below ever names a class from a directory to its right.


```
QVoxelSource                    — voxel storage & editing (materials, chunk buffers)
  ├─ VoxelStream (@abstract)     — STORAGE: chunk-level persistence API (all @abstract)
  │    ├─ QVoxelStream             — single-file .qvx block-stream world storage (disk)
  │    └─ VoxelMemoryStream      — memory only (no persistence; a home for edits)
  └─ node: QVoxelNode            — GENERATION: the data layer's single source of truth
	   └─ QVoxelModel            — bounded grid + modifier chain (run by QVoxelEvalEngine)

VoxelMesher                     — MESHING layer: voxels → geometry → ArrayMesh
								  (stateless, no node; both draw modes share it)
VoxelRenderer                   — DRAWING CORE: data → visible geometry
  └─ DrawMode.STATIC / DYNAMIC
	 STATIC  : whole model → 1 mesh (≤2 surfaces), shared across instances → auto-batched
	 DYNAMIC : per-chunk (or per-group) MeshInstance3D, incremental rebuild

Optional capability components (plain child nodes of VoxelRenderer):
  VoxelViewLayer                — streaming load/unload, LOD bands, frustum culling, origin shift
  VoxelCollision                — StaticBody3D + ConcavePolygonShape3D per chunk
  VoxelParticleView             — point cloud → GPUParticles3D
  VoxelDestructible             — destruction, collapse, falling debris (edited via VoxelEditKernel)
```

**Layer rules (one-way dependency, arrows point down only):**

1. **`VoxelRenderer` owns drawing, not viewpoint policy.** It keeps exactly two things it
   cannot avoid: `current_camera()` (used to drop a stale async result whose chunk has since
   moved out of range) and the `view_distance` / `unload_distance` / `lod_count` knobs, which
   the view layer reads back. Everything else — streaming, LOD banding, frustum culling,
   origin shift, destruction, particles — lives in `Runtime/` components that read the
   renderer's public surface and subscribe to its signals.
2. **The simplest path must really be the simplest.** With `DrawMode.STATIC` and no components
   attached, no LOD/streaming code runs in the frame loop at all.
3. **Two draw modes are a deliberate tradeoff, not an optimisation switch:**

   | | draw calls (N instances) | cost of editing one voxel |
   |---|---|---|
   | `STATIC` (default) | ~N (auto-batched) | rebuilds the **whole** model (deer 1.6–3.1 ms / teapot1 85 ms) |
   | `DYNAMIC` | N × chunk count | rebuilds only the affected chunk (0.4–2 ms) |

   Use `STATIC` for static props / buildings / display models, `DYNAMIC` for anything you
   destroy or edit per-voxel (a destruction system **must** use `DYNAMIC`).
   Measured parity with imported ArrayMesh in `STATIC` mode, plus the reasoning, are in
   `docs/渲染性能对比_QVX_vs_ArrayMesh.md`.

**Storage and generation are two parallel parts**: `stream` stores (disk or memory), the
`node` describes what to generate (a bounded `QVoxelModel` whose modifier chain the eval
engine runs). They can coexist (procedural world + persisted destruction); lookup order is
always **stream first** — anything stored is authoritative and must never be overwritten by a
freshly generated result.
Pending/ready bookkeeping, dedup, throttling and background dispatch live in one place
(`VoxelAsyncLoader`); each source only answers two synchronous questions: "is it stored?" and
"can you generate it?" (the latter is the virtual `can_generate_chunk()`, which an infinite
world extension overrides).

**Data access order** (per chunk): memory buffer → stream → node.
All mesh generation runs on background threads (`WorkerThreadPool`); the main thread never builds voxel meshes or generates chunks synchronously.

### Static world (disk streaming)

```gdscript
var data := QVoxelSource.new()
# ... add materials, fill voxels (set_voxel / set_voxels)

var stream := QVoxelStream.new()
stream.file_path = "user://my_world/world.qvx"
data.stream = stream

var renderer := VoxelRenderer.new()
renderer.data = data
renderer.voxel_scale = 0.2
renderer.draw_mode = VoxelRenderer.DrawMode.DYNAMIC   # streaming + LOD needs DYNAMIC
renderer.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
renderer.view_distance = 60.0
renderer.unload_distance = 100.0
renderer.lod_count = 4   # 多级 LOD：4 层（LOD0 全精度 + LOD1/2/3 每级 ×2 粗化），
						  # 各层距离由 view_distance 自动等比（×2）推导
```

### Procedural infinite world

```gdscript
class_name MyWorld
extends ProceduralVoxelSource

## Only generate() is required: the base fills is_streaming / can_generate_chunk /
## is_in_node_bounds and configures the async loader at construction.
## Return a 32³ PackedInt32Array (lod=0) or LOD_BLOCK_SIZE³ (lod>=1), value = material id, 0 = empty.
## Must be deterministic: same chunk_key → same terrain.
func generate(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	# e.g. noise-based heightmap — use ABSOLUTE voxel y for cross-layer continuity
	...

# usage: the source GENERATES, the stream STORES (swap freely, independently)
var data := MyWorld.new()
data.infinite = true                      # enables origin shift
data.stream = QVoxelStream.new()          # player edits go to disk, survive restart
data.stream.file_path = "user://world_edits/world.qvx"
# assign to VoxelRenderer.data (recommend visibility_mode = STREAMING)
```

> Swap `stream` for `VoxelMemoryStream` to keep edits in memory only; leave it unset and the
> engine falls back to a memory stream automatically. The generation code never changes.

Features:
- **Deterministic** — same chunk_key → same terrain, continuous across borders and origin shifts
- **Origin shift** — camera moving far auto-shifts the world origin so coordinates stay small (float32 precision safe) → truly unlimited world
- **Edit persistence** — player-modified chunks are stored by `stream`, surviving restart
- **Async generation** — chunk generation runs on background threads; main thread only submits/collects
- **Auto-unload** — meshes, LOD0 chunk data and coarse LOD blocks beyond distance are all dropped
  and rebuilt on return. LOD0 *data* is unloaded on a wider radius than meshes (`unload_distance`
  plus the coarsest block's extent) so coarse downsampling keeps its LOD0 source; everything is
  re-loaded / re-generated on return — this is what keeps an infinite world's memory bounded

### Destruction & collapse

```gdscript
# Destruction is a COMPONENT, not a subclass:
#   VoxelRenderer (drawing)  +  VoxelDestructible (editing, child node)
var renderer := VoxelRenderer.new()
renderer.data = data
renderer.draw_mode = VoxelRenderer.DrawMode.DYNAMIC   # REQUIRED: STATIC rebuilds the whole model per edit
add_child(renderer)

var target := VoxelDestructible.new()
renderer.add_child(target)
target.configure(renderer)

target.damage_sphere(center, radius)
target.damage_voxel(pos)
target.damage_ray(origin, direction, max_distance)
```

Options: `use_voxel_health` / `damage_per_voxel` / `collapse_mode` / `local_collapse` /
`falling_mode` / `stress_force` / `spawn_debris_on_damage`, etc.
Debris is GPU-particle based (no per-chunk physics bodies).

### Configuration — auto-hidden when not applicable

Related properties are **hidden in the Inspector automatically** when they have no effect:

| Property | Effective when | Hidden when |
|---|---|---|
| `view_distance` / `unload_distance` / `lod_count` | visibility_mode ≠ FULL | visibility_mode = FULL |
| `_collision_rebuild_per_frame` / `collision_rebuild_budget_ms` | generate_collision = true | generate_collision = false |
| `group_shift` | draw_mode = DYNAMIC | draw_mode = STATIC |
| `max_debris_per_hit` / `debris_*` | spawn_debris_on_damage = true | spawn_debris_on_damage = false |

### Common pitfalls

- **`draw_mode` is the first thing to get right.** `STATIC` (default) merges the whole model into
  one mesh and lets the engine batch instances — that is what makes it match imported ArrayMesh.
  The price is that editing one voxel rebuilds everything (deer 1.6–3.1 ms, teapot1 85 ms).
  Anything you destroy / edit per-voxel **must** use `DYNAMIC` (0.4–2 ms per edit).
- **`group_shift` (DYNAMIC only, default 0).** 0 = one draw unit per chunk (cheapest per edit).
  `1`/`2` group 8/64 chunks into one draw unit — fewer draw calls (teapot1: 158 → 35 → 8) but the
  whole group is rebuilt on edit, and that rebuild runs on the main thread. Only raise it for
  many instances of a chunk-dense model that you rarely edit.

- **Procedural world**: extend `ProceduralVoxelSource` (it reports `is_streaming() = true`; the renderer gate uses that instead of `node != null`). `visibility_mode = STREAMING` is still recommended so unload/LOD distance logic is active.
- `lod_count = 1` disables LOD (everything full-precision); for large worlds set `lod_count >= 2`.
  Band radii are automatic: LOD0 = `view_distance / 2^lod_count`, LOD_i (i>=1) =
  `view_distance / 2^(lod_count-1-i)` — each level doubles, matching Voxel Tools.
- `unload_distance = 0` falls back to `view_distance * 1.2`
- `generate_collision` is **false by default** — enable it for physics collision. Collision rebuild is both count- and time-budgeted (`collision_rebuild_budget_ms`, default 4ms); one chunk may still exceed the budget, so set it lower if your chunk meshes are very dense.
- `voxel_scale` = world units per voxel (data coordinates are 1-voxel units); all distances are in world units
- **The native library is a hard dependency** — mesh generation, destruction and CRC all live in
  `addons/VoxelSupport/Native/` (GDExtension `VoxelSupportNative`). If it is missing or version-mismatched,
  the plugin logs one clear error and draws nothing; there is no GDScript fallback.
- **Asset origin is one shared import option: `mesh/origin`** — default `world_origin` = keep the file's
  coordinates: a `.vox` stays where the author put it in the MagicaVoxel world (model `SIZE`-box centre
  plus every `nTRN`/`NODE` transform), and a `.qvx` — which has no world layer — simply uses its stored
  coordinates as-is. This is also what the Mesh import always did, so upgrading never shifts existing
  assets and multi-model assemblies keep their relative layout. The Mesh and the Voxel Data importer
  read the same option with the same meaning, so a model lands in the same spot either way. Pick
  `bottom_center` for the usual game-asset pivot (X/Z centred on the content, bottom at `Y = 0`), or
  `content_center` for a three-axis content-centred origin (the same idea as Blender's
  "Center Origins" option).
- **`.vox` and `.qvx` have separate asset adapters** — `.vox` (MagicaVoxel scene graph) uses
  `VoxAsset.from_asset()`; `.qvx` (one `VXEL` per model + `NODE` placement) uses
  `QVoxelAsset.from_file()`. `VoxAsset.from_asset()` on a `.qvx` **returns null with an error**:
  forcing the MagicaVoxel shape onto QVX silently dropped the `NODE` graph and every model after
  the first. The import plugins dispatch by extension for you.

### Streaming demo

`res://demo/test_world_demo.tscn` — **key 1** cycles `FULL` / `FRUSTUM` / `STREAMING` on a large building
block world; **key 2** cycles `group_shift`, **key 5** orbits the camera for an automatic FPS sweep.
Controls: WASD move, Q/E up/down, Space fast, left click destroys a sphere, Space casts a destruction ray.

## Voxel particles (low-level interface)

Render a voxel model **as a cloud of voxel cubes**. The plugin provides only this mechanism and
**implements no effects** — floating, dissolving, assembling and A→B morphing are your project's
presentation, and should be written by your project.

```gdscript
$VoxelRenderer.display_mode = VoxelRenderer.DisplayMode.PARTICLES   # switch to particles (mesh hidden)
$VoxelRenderer.voxel_shape = VoxelRenderer.VoxelShape.SPHERE    # cube / sphere
var node := $VoxelRenderer.particle_node    # a GPUParticles3D with the point cloud already uploaded
node.process_material = my_particles_shader # replace it; decide how particles move
$VoxelRenderer.particle_points              # the point data (PackedFloat32Array)
```

Demo: `res://demo/particle_demo.tscn` (1 static / 2 float / 3 scatter / 4 gather / T toggle mesh↔particles / F toggle shape).
It shows **two ways to customise**: tweak a uniform (float), or replace the whole process shader (scatter/gather).

### Two enums control what you see

| Enum | Values | Meaning |
|---|---|---|
| `DisplayMode` | `MESH` / `PARTICLES` | merged-face mesh (default) or one cube per voxel |
| `VoxelShape` | `CUBE` / `SPHERE` | draw each particle as a cube or a sphere; switching **does not** rebuild the particle node, it only swaps the draw-pass meshes |

The sphere geometry is generated by the plugin too (`SphereMesh`, three tiers of 6/10/18 rings via
`sphere_subdivisions`), with `sphere_scale` as the radius relative to the voxel edge — the same two
properties the mesh path uses, so both paths reach the same look; the mesh path bakes it at import time,
the particle path swaps the draw mesh at runtime.

These two enums are the only switches: the early boolean/method aliases (`particle_mode`,
`particle_shape`, `show_as_particles()`) are gone — one meaning, one entry point.

### Where the data comes from: `QVoxelSource.build_particle_points()`

**There is no separate point-cloud resource class** — that would be a second view of the same data and
reintroduce the "two sources of truth, which one wins" problem. The point cloud is a **derived query**
on `QVoxelSource`: recomputable at any time, never saved to disk.

```gdscript
# Just the point array (for your own pairing / offsets)
var pts := source.build_particle_points(0.1, 200000, true)

# Or with GPU textures ready to upload (this is what the renderer uses internally)
var tex := source.build_particle_textures(0.1, 200000, true)
tex["positions"]   # ImageTexture RGBAF: xyz
tex["colors"]      # ImageTexture RGBAF: linear albedo + opacity
tex["props"]       # ImageTexture RGBAF: metal / rough / emission
tex["grid_width"]  # what the shader uses to map INDEX to a texel
```

**12 floats per point** (`QVoxelSource.PARTICLE_STRIDE`):

| Offset | Content |
|---|---|
| `P_POS` (0) +0..2 | world position = (voxel + center_offset) × scale, **exactly matching the mesh renderer** |
| `P_MAT` (3) | material id |
| `P_COLOR` (4) +0..2 | albedo (sRGB) |
| `P_SEED` (7) | stable random 0..1 (derived from the coordinate; same voxel → same value) |
| `P_EMIT` (8) | emission 0..1 |
| `P_METAL` (9) | metallic 0..1 |
| `P_ROUGH` (10) | roughness 0..1 |
| `P_TRANS` (11) | transparency 0..1 (0 = opaque) |

### Visual fidelity: things that must be right, and fail silently when wrong

The renderer already handles all of these. If you write your own process shader, don't lose them:

| Problem | Symptom | Fix |
|---|---|---|
| Hard-coded particle size | Cubes 5× the voxel size, occluding each other — looks see-through | edge = `voxel_scale × particle_scale` |
| Colour space (double gamma) | Darks brightened >2×, washed out and flat | `srgb_to_linear()` at bake time (`FORMAT_RGBAF` is linear) |
| Colour only, no material | Metal has no metallic feel; glass is a solid slab | output `METALLIC / ROUGHNESS / EMISSION`, true PBR |
| One material can't separate opaque/transparent | Either see-through, or glass culls what's behind it | **two draw passes**, split by alpha |
| Opaque pass writes ALPHA | Classified as transparent → no depth → see-through | the opaque pass must **never write ALPHA** |
| Surface filter drops glass | Windows vanish outright | **always keep transparent voxels** (enclosed glass is still see-through) |
| Forgetting `preprocess` | Only a few stray points appear | `preprocess = lifetime` so every particle exists from frame one |

Measured (cars.vox, same camera and environment): mean luminance differs by **1.5%**, mean per-pixel
difference **0.065**, metallic mean difference **0.7%**, and both sides have **zero** clipped white pixels.

### Optional pairing helper: `VoxelMorphMap`

A→B morphing needs "which point of B should particle i of A fly to". That is an **algorithm**, not an
**effect**, so it is kept as a tool:

```gdscript
var map := VoxelMorphMap.build(a_points, b_points)   # Morton-sorted pairing by default
map.b_index[i]   # point i of A -> point b_index[i] of B
```

Pairing by index makes particles criss-cross wildly. Measured on 20k points: Morton ≈30 ms with mean
pairing distance 0.418; sorted-axis 130 ms / 1.039; spatial hash 0.108 but 30% slower; greedy O(n²)
already >2 s at 5k points — unusable.
## Voxel modeling (QVoxelier + scripts)

`res://QVoxelier/QVoxelier.tscn` is a standalone voxel modeler built on this plugin.
Its whole capability is also exposed to code through **`QVoxelScript`** — one method per UI action
(models, groups, materials, voxels, frames, cameras, file I/O, mesh export) — which is what the
MCP `voxel_help` tool / `voxel://api` resource documents, so AI can model without the GUI:
`new_model` → `material` → `paint(VoxelPrimitives.*)` → `save`.

`.qvx` is the project file (lossless), `.vox` the MagicaVoxel exchange format (≤ 256, 90° rotations,
integer offsets, current frame only) — see `docs/QVX_FORMAT.md`.

To see the result without opening the app: `await QVoxelScript.preview("user://shot.png", {"file": "user://m.qvx"})`
renders the world offscreen to a PNG (MCP tool: `voxel_render`) — no import pipeline, no `reimport`.
