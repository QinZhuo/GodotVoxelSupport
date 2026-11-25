extends "res://addons/VoxelSupport/Data/ProceduralVoxelSource.gd"

## 测试夹具：只实现 generate，验证 ProceduralVoxelSource 已经替它补齐其余三个判定。

func generate(key: Vector3i, lod: int = 0) -> PackedInt32Array:
	var n := VoxelChunk.CHUNK_VOLUME if lod == 0 else VoxelChunkGenerator.LOD_BLOCK_SIZE * VoxelChunkGenerator.LOD_BLOCK_SIZE * VoxelChunkGenerator.LOD_BLOCK_SIZE
	var buf := PackedInt32Array()
	buf.resize(n)
	var idx := 0
	if key == Vector3i.ZERO:
		idx = 1
	buf[idx] = 1
	return buf
