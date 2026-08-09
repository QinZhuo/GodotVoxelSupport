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
