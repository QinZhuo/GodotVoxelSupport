@tool
@abstract
class_name VoxelStream
extends Resource

## 体素数据**存储**抽象 —— 只回答一件事：块数据存在哪儿、怎么存取。
##
## 与 VoxelGenerator 的分工（关键设计）：
##   VoxelStream    只管存：save / load / has / erase / keys / flush。不做生成、不做异步。
##   VoxelGenerator 只管造：给定 key 算出数据。不碰 I/O、不持有状态。
## 谁先取、何时异步、结果怎么回填，全部由 VoxelData 一处编排（VoxelAsyncLoader）。
##
## 【为什么把异步与"可生成范围"从这里移走】它们都不是存储的事实：
##   · "在途 / 就绪"是编排状态，两个数据源还要共用同一套去重/限流规则；
##   · "可生成范围"是生成器的几何信息。
## 早先这些都挂在 VoxelStream 上，于是 has_chunk 一个名字要同时表示"已存在流中"与
## "属于可生成范围"，调用方只能靠 `is 类型` 逐处分支猜语义；拆开后各自只有一个含义。
##
## 内置实现：
##   QVoxelStream        —— .qvx 单文件块流（磁盘，一个文件承载整个世界）
##   VoxelMemoryStream —— 纯内存（无持久化；程序化世界的编辑覆盖层用它落脚）
##
## 数据格式约定（与 VoxelData 统一材质契约一致）：
##   buffer = PackedInt32Array(32³)，值 = 材质ID（0 = 空/空气）。
##   空 chunk（全 0）不落盘，由 VoxelData 在变空时调用 erase_chunk。

## 保存单个 chunk/block 的数据。
## buffer 为 CHUNK_VOLUME（lod=0）或 LOD_GRID³（lod>=1）长度（值 = 材质ID，0 = 空）。
## lod 指定数据粒度：0 = 全精度 chunk；>=1 = 粗层 block（每格 2^lod 体素）。空块不会被调用。
@abstract
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void

## 读取单个 chunk/block 的数据。**流中不存在返回空数组** —— 这就是本接口的存在性返回码，
## has_chunk 只是同一事实的 O(1) 快路径（供渲染器扫描等高频场合使用，避免解码与分配）。
@abstract
func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array

## 流中是否已有该 chunk/block 的数据。**纯存储语义**，与"能否生成"无关
## （后者是 VoxelGenerator.is_in_generation_bounds 的事）。
@abstract
func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool

## 移除该 chunk/block 的数据（世界该处已清空，流不得残留）。
@abstract
func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void

## 获取流中所有已保存的 chunk/block key（用于恢复世界索引）。
@abstract
func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]

## 流中已存的 chunk/block 数量。
## 【为什么单独开一个方法】HUD 等读取者每帧只想知道"有多少"，而 get_all_chunk_keys 必须
## 构造一整个 key 数组——每帧白付一次 O(n) 分配。有 O(1) 计数的实现应覆写本方法
## （QVoxelStream / VoxelMemoryStream 已覆写）；默认实现退化为数数组长度，保证正确。
func get_chunk_count(lod: int = 0) -> int:
	return get_all_chunk_keys(lod).size()

## 本流是否承载粗层 LOD 数据（lod >= 1 的 block）。
##
## 【为什么需要这个查询】调用方（渲染器 / VoxelData）此前靠 `is QVoxelStream` 判断，
## 于是"抽象存储层"被迫泄露具体实现类型：新增任何一种带粗层的流都要回头改渲染器。
## 换成虚方法后，判定依据是**能力**而非**类型**，与 has_chunk / load_chunk 的抽象一致。
##
## 语义：
##   true  —— 独立存粗层块：粗层缺席时可直接同步降采样（不等一个流不会给的异步结果），
##            且派生出的粗层数据回写本流持久化。
##   false —— 内存流 / 自定义流：粗层只存在于内存（VoxelData._coarse_buffers），
##            lod >= 1 一律视为流中不存在。
func supports_lod_layer() -> bool:
	return false


## 刷新写入缓存（无写缓存的实现可留空）。
@abstract
func flush() -> void

## 数据存储路径描述（供调试 / HUD 显示）。
@abstract
func get_stream_path() -> String
