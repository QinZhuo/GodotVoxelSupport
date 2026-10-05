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
##   QVoxStream        —— .qvox 单文件块流（磁盘，一个文件承载整个世界）
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

## 刷新写入缓存（无写缓存的实现可留空）。
@abstract
func flush() -> void

## 数据存储路径描述（供调试 / HUD 显示）。
@abstract
func get_stream_path() -> String
