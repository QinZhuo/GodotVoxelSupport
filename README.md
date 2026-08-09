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
- **VoxelData** — voxel storage & editing (materials, chunk buffers)
- **VoxelStream** (`@abstract`) — persistence backend (chunk-level read/write)
  - `VoxelFileStream` — disk region-file streaming (persist voxel worlds)
  - `VoxelProceduralStream` (`@abstract`) — infinite procedural world; subclass and override `_generate_chunk()`
- **VoxelRenderer** — mesh generation, LOD, streaming, collision
- **VoxelDestructible** — extends `VoxelRenderer`: destruction, collapse, debris

### Procedural infinite world

```gdscript
class_name MyWorld
extends VoxelProceduralStream

## Override the base @abstract method: return a 16³ PackedInt32Array (value = material id, 0 = empty).
## Must be deterministic: same chunk_key → same terrain.
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	# ... generation algorithm

# usage
var stream := MyWorld.new()
stream.persist_directory = "user://world_edits"   # optional: persist user edits
var data := VoxelData.new()
data.stream = stream
# ... assign to VoxelRenderer.data
```

Features:
- Deterministic generation, continuous across chunk borders and origin shifts
- **Origin shift**: camera far away auto-shifts world origin to keep coordinates small (float32 precision safe)
- **Edit persistence**: user-modified chunks are stored under `persist_directory` and survive restart
- **Async generation**: chunk generation runs on background threads (`WorkerThreadPool`)

### Streaming demo
`res://demo/streaming_demo.tscn` — switch between disk-file stream and procedural infinite world with **key 0**.
Controls: WASD move, Q/E up/down, Space fast, 1 streaming on/off, 2 frustum culling on/off.
