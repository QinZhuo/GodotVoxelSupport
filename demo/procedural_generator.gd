class_name ProceduralTerrainGenerator
extends RefCounted

## 示例程序化地形生成器（无限世界 chunk 生成器）。
## 用 FastNoiseLite 连续噪声（世界坐标）生成高度场地形，同 chunk_key 确定性地形。
## 高度用**绝对体素 y** 判断：任意 y 层 chunk 按世界高度填，地形跨层连续。
## 用法：VoxelProceduralStream.generator = ProceduralTerrainGenerator.generate_chunk

static var _noise_h := FastNoiseLite.new()
static var _noise_det := FastNoiseLite.new()

static func _static_init() -> void:
	_noise_h.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise_h.frequency = 0.02
	_noise_h.seed = 42
	_noise_det.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_det.frequency = 0.08
	_noise_det.seed = 1234

## 生成 16³ chunk 缓冲（值 = 材质ID，0=空）。确定性：同 chunk_key 同地形。
static func generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	var base := chunk_key * VoxelChunk.CHUNK_SIZE
	for z in VoxelChunk.CHUNK_SIZE:
		for x in VoxelChunk.CHUNK_SIZE:
			var wx := base.x + x
			var wz := base.z + z
			# 绝对高度（体素）：大尺度地形 + 细节起伏
			var h := _noise_h.get_noise_2d(wx, wz) * 14.0 + _noise_det.get_noise_2d(wx, wz) * 4.0 + 8.0
			var hi := int(h)
			if hi <= 0:
				continue
			for y in VoxelChunk.CHUNK_SIZE:
				var wy := base.y + y
				if wy < hi:
					buf[x + y * VoxelChunk.CHUNK_SIZE + z * VoxelChunk.CHUNK_SLICE] = 1
	return buf
