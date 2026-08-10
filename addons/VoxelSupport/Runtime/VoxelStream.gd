@tool
@abstract
class_name VoxelStream
extends Resource

## 体素数据流抽象（数据层磁盘流式）
##
## 提供 chunk 级数据的持久化原语，让 VoxelData 在流式模式下只保留"活跃"chunk
## 在内存中，其余 chunk 数据由 stream 负责写盘 / 读盘：
##   - 内存只保留最近活跃的 chunk，其余写入磁盘（磁盘为权威）
##   - 修改过的 chunk 卸载时写回；未修改的丢弃（磁盘原本就有）
##   - 访问 / 范围查询 / 破坏 / 网格生成会自动从磁盘加载所需 chunk
##
## 全部方法为 @abstract 抽象方法（无实现，函数头后直接换行）。子类必须实现，
## 未实现会编译报错。内置实现：VoxelFileStream（region 块级存储）、
## VoxelProceduralStream（程序化无限世界，其子类覆写 _generate_chunk 实现生成算法）。
## 数据格式约定（与 VoxelData 统一材质契约一致）：
##   buffer = PackedInt32Array(16³)，值 = 材质ID（0 = 空/空气）。
##   空 chunk（全 0）不落盘，由 VoxelData 在变空时调用 erase_chunk。

## 保存单个 chunk 的体素数据到流（写盘）。
## buffer 为 16³ PackedInt32Array（值 = 材质ID，0 = 空）。空 chunk 不会被调用。
@abstract
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array) -> void

## 从流加载单个 chunk 数据。流中不存在返回空数组 PackedInt32Array()（区分于
## 有数据的 buffer：有数据时长度恒为 16³）。
## 返回 PackedInt32Array(16³)（值 = 材质ID，0 = 空）。
@abstract
func load_chunk(chunk_key: Vector3i) -> PackedInt32Array

## 流中是否存在该 chunk 的数据（已保存过）。
## 程序化流覆写为"是否属于本流可生成范围"（见 VoxelProceduralStream）。
@abstract
func has_chunk(chunk_key: Vector3i) -> bool

## 移除该 chunk 的数据（世界该处已清空，磁盘不得残留）。
@abstract
func erase_chunk(chunk_key: Vector3i) -> void

## 获取流中所有已保存的 chunk key（用于恢复世界索引）。
@abstract
func get_all_chunk_keys() -> Array[Vector3i]

## 刷新写入缓存（无写缓存的实现可留空）。
@abstract
func flush() -> void

## 数据存储路径描述（供调试 / HUD 显示）。
@abstract
func get_stream_path() -> String

## 异步请求 chunk 数据（后台线程加载/生成）。渲染器统一流式扫描提交后，由
## poll_all_ready 取回结果，实现"程序化生成 / 磁盘读"两种数据源共用一套加载流程。
## 同 key 已提交则忽略（内部去重）。
@abstract
func request_chunk_async(chunk_key: Vector3i) -> void

## 主线程批量取回异步就绪的 chunk 数据。返回 [[chunk_key, PackedInt32Array], ...]，
## 每项 buffer 为 CHUNK_VOLUME 长度（值 = 材质ID，0 = 空），未就绪的保持待下次轮询。
@abstract
func poll_all_ready(max_count: int) -> Array


# ----------------------------------------------------------------------------
# 【可选有限范围】所有流共有的"可生成范围"能力（非抽象，子类可直接使用）
# ----------------------------------------------------------------------------
# 两层判定，渲染器扫描循环高频调用（如 VoxelRenderer._process_streaming 的
# has_chunk 存在性判断），需保证 O(1) 且零内存分配：
#   1) AABB 范围（_bounds_active，chunk 坐标 min/max）：矩形世界（如整张地图）的
#      O(1) 判定——3 轴整数比较。通常由 VoxelData.grid_size 自动推导（set_grid_size）。
#   2) 精确集合 _chunk_set（chunk_key → true）：稀疏/不规则覆盖（如建筑内部空心，
#      只有墙与房间所在 chunk）。空 = 该层不启用。
# 无限世界流（AABB 未启用且集合空）：恒 true（任何 chunk 可生成）。

var _bounds_min: Vector3i = Vector3i.ZERO
var _bounds_max: Vector3i = Vector3i.ZERO
var _bounds_active: bool = false
var _chunk_set: Dictionary = {}


## 按体素尺寸设定矩形覆盖范围（chunk 坐标从 0 到 size-1 所在 chunk）。
## 与 VoxelData.grid_size 配合：VoxelData.set_stream 时自动调用，调用方无需手动。
## size = ZERO 视为无限世界（保持恒 true）。
func set_grid_size(voxel_size: Vector3i) -> void:
	if voxel_size == Vector3i.ZERO:
		_bounds_active = false
		return
	_bounds_min = Vector3i.ZERO
	_bounds_max = VoxelChunk.chunk_of(voxel_size - Vector3i.ONE)
	_bounds_active = true


## 设定有限 chunk 覆盖范围（有限模板流，如建筑蓝图）。
## 调用后 is_in_generation_bounds 直接查此精确集合（集合已含出界雨棚/屋檐等元素，
## 故此时 AABB 不参与判定——按 grid_size 的 AABB 会漏掉出界元素）。
func set_chunk_bounds(keys: Array[Vector3i]) -> void:
	_chunk_set.clear()
	for ck in keys:
		_chunk_set[ck] = true


## 该 chunk 是否属于本流可生成范围。供子类 has_chunk 复用：
##   无限世界流（无 AABB、无集合）：恒 true（任何 chunk 可生成）。
##   精确集合模式（_chunk_set 非空，如建筑）：直接查集合。
##   纯 AABB 模式（有 AABB、无集合，如矩形地图 TownGroundStream）：3 轴整数比较 O(1)。
## 避免渲染器对相机 view_distance 内所有 chunk 提交生成海量空 chunk。
func is_in_generation_bounds(chunk_key: Vector3i) -> bool:
	if not _chunk_set.is_empty():
		return _chunk_set.has(chunk_key)
	if _bounds_active:
		return chunk_key.x >= _bounds_min.x and chunk_key.x <= _bounds_max.x \
			and chunk_key.y >= _bounds_min.y and chunk_key.y <= _bounds_max.y \
			and chunk_key.z >= _bounds_min.z and chunk_key.z <= _bounds_max.z
	return true


## origin shift 时同步平移范围限制（chunk 坐标随数据基准移动）。
func shift_bounds(offset: Vector3i) -> void:
	if _bounds_active:
		_bounds_min += offset
		_bounds_max += offset


## 渲染器距离扫描的垂直半跨度（chunk 数）：dy ∈ [-span, span]。
## 无限世界（程序化，地表以下全实心/以上全空）默认 ±1 层足够；
## 有限世界（AABB 生效）按 grid_size 推导的世界高度覆盖全部层。
func get_vertical_half_span() -> int:
	if _bounds_active:
		return maxi(absi(_bounds_max.y - _bounds_min.y), 1)
	return 1
