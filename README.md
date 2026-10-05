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

```
VoxelData                    — voxel storage & editing (materials, chunk buffers)
  ├─ VoxelStream (@abstract)     — STORAGE: chunk-level persistence API (all @abstract)
  │    ├─ QVoxStream             — single-file .qvox block-stream world storage (disk)
  │    └─ VoxelMemoryStream      — memory only (no persistence; a home for edits)
  └─ VoxelGenerator (@abstract)  — GENERATION: compute data from a key (no I/O, no state)
       └─ your subclass overrides @abstract `_generate_chunk()` / `_generate_chunk_lod()`
VoxelRenderer              — async mesh generation, LOD, streaming, collision
VoxelDestructible          — extends VoxelRenderer: destruction, collapse, falling debris
```

**Storage and generation are two parallel parts**: `stream` stores (disk or memory),
`generator` generates (procedural terrain). They can coexist (procedural world + persisted
destruction); lookup order is always **stream first** — anything stored is authoritative and
must never be overwritten by a freshly generated result.
Pending/ready bookkeeping, dedup, throttling and background dispatch live in one place
(`VoxelAsyncLoader`); each source only answers two synchronous questions: "is it stored?" and
"can you generate it?".

**Data access order** (per chunk): memory buffer → stream → generator.
All mesh generation runs on background threads (`WorkerThreadPool`); the main thread never builds voxel meshes or generates chunks synchronously.

### Static world (disk streaming)

```gdscript
var data := VoxelData.new()
# ... add materials, fill voxels (set_voxels / load_voxels_dict)

var stream := QVoxStream.new()
stream.file_path = "user://my_world/world.qvox"
data.stream = stream

var renderer := VoxelDestructible.new()
renderer.data = data
renderer.voxel_scale = 0.2
renderer.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
renderer.view_distance = 60.0
renderer.unload_distance = 100.0
renderer.lod_count = 4   # 多级 LOD：4 层（LOD0 全精度 + LOD1/2/3 每级 ×2 粗化），
                         # 各层距离由 view_distance 自动等比（×2）推导
```

### Procedural infinite world

```gdscript
class_name MyWorld
extends VoxelGenerator

## Override the base @abstract method: return a 32³ PackedInt32Array
## (value = material id, 0 = empty). Must be deterministic: same chunk_key → same terrain.
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	# e.g. noise-based heightmap — use ABSOLUTE voxel y for cross-layer continuity
	...

# usage: the generator GENERATES, the stream STORES (swap freely, independently)
var data := VoxelData.new()
data.stream = QVoxStream.new()          # player edits go to disk, survive restart
data.stream.file_path = "user://world_edits/world.qvox"
data.generator = MyWorld.new()          # untouched parts generated from the key
# assign to VoxelRenderer.data (recommend visibility_mode = STREAMING)
```

> Swap `stream` for `VoxelMemoryStream` to keep edits in memory only; leave it unset and the
> engine falls back to a memory stream automatically. The generator code never changes.

Features:
- **Deterministic** — same chunk_key → same terrain, continuous across borders and origin shifts
- **Origin shift** — camera moving far auto-shifts the world origin so coordinates stay small (float32 precision safe) → truly unlimited world
- **Edit persistence** — player-modified chunks are stored by `stream`, surviving restart
- **Async generation** — chunk generation runs on background threads; main thread only submits/collects
- **Auto-unload** — chunks beyond `view_distance` are dropped and regenerated on return

### Destruction & collapse

```gdscript
var target := renderer as VoxelDestructible
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
| `_stream_load_per_frame` / `_stream_unload_per_frame` | visibility_mode = STREAMING | otherwise |
| `_lod1_build_per_frame` / `_lod1_build_budget_ms` | lod_count > 1 | lod_count = 1 |
| `_collision_rebuild_per_frame` | generate_collision = true | generate_collision = false |
| `max_debris_per_hit` / `debris_*` | spawn_debris_on_damage = true | spawn_debris_on_damage = false |

### Common pitfalls

- **Procedural world**: use `visibility_mode = STREAMING` — infinite worlds are always distance-driven (FULL/FRUSTUM previously rendered nothing; now auto-fixed)
- `lod_count = 1` disables LOD (everything full-precision); for large worlds set `lod_count >= 2`.
  LOD_i 半径自动 = `view_distance / 2^(lod_count-1-i)`（每级 ×2，对齐 Voxel Tools 标准做法）
- `unload_distance = 0` falls back to `view_distance * 1.5`
- `generate_collision` is **false by default** — enable it for physics collision
- `voxel_scale` = world units per voxel (data coordinates are 1-voxel units); all distances are in world units

### Streaming demo

`res://demo/streaming_demo.tscn` — **key 0** switches between disk-file stream and procedural infinite world.
Controls: WASD move, Q/E up/down, Space fast, 1 streaming on/off, 2 frustum culling on/off.
