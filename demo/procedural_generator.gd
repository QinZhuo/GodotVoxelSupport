class_name ProceduralTerrainGenerator
extends VoxelProceduralStream

## 示例程序化地形流子类（覆写虚基类 _generate_chunk 实现生成算法）。
## 用 FastNoiseLite 连续噪声（世界坐标）生成高度场地形，同 chunk_key 确定性地形。
## 高度用**绝对体素 y** 判断：任意 y 层 chunk 按世界高度填，地形跨层连续。

static var _noise_h: FastNoiseLite = null
static var _noise_det: FastNoiseLite = null

static func _static_init() -> void:
	_ensure_noise()

## 惰性初始化噪声（编辑器 @tool 场景/后台线程下 _static_init 可能未执行 → 兜底创建）。
static func _ensure_noise() -> void:
	if _noise_h == null:
		_noise_h = FastNoiseLite.new()
		_noise_h.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise_h.frequency = 0.02
		_noise_h.seed = 42
		_noise_det = FastNoiseLite.new()
		_noise_det.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_noise_det.frequency = 0.08
		_noise_det.seed = 1234

## 覆写虚基类：生成 CHUNK_SIZE³ chunk 缓冲（值 = 材质ID，0=空）。
## 确定性：同 chunk_key 同地形（连续噪声），origin shift 平移 chunk key 后世界连续。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	_ensure_noise()
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	var base := chunk_key * VoxelChunk.CHUNK_SIZE
	for z in VoxelChunk.CHUNK_SIZE:
		for x in VoxelChunk.CHUNK_SIZE:
			var wx := base.x + x
			var wz := base.z + z
			# 绝对高度（体素）：大尺度地形 + 细节起伏。
			# 抬高基准 + 限最小高度：避免噪声负值区域整列无方块 → 地表"深不见底的柱状空洞"
			var h := _noise_h.get_noise_2d(wx, wz) * 16.0 + _noise_det.get_noise_2d(wx, wz) * 6.0 + 20.0
			var hi := maxi(int(h), 2)
			for y in VoxelChunk.CHUNK_SIZE:
				var wy := base.y + y
				if wy < hi:
					buf[x + y * VoxelChunk.CHUNK_SIZE + z * VoxelChunk.CHUNK_SLICE] = 1
	return buf
