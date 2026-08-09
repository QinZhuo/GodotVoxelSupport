#ifndef VOXEL_NATIVE_H
#define VOXEL_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

// 体素插件原生核心（GDExtension C++ 热路径）
// GDScript 侧通过 VoxelNative 调用，替代部分 GDScript 慢实现：
//   - greedy_merge_dense:     贪婪网格合并（已完成，~11.5x）
//   - generate_chunk_dense:   chunk 网格生成主循环（16³ 体素 × 6 方向可见性 + 贪婪合并）
//   - find_unsupported_around: 支撑图失稳检测（已完成）
//   - remove_voxels_bulk:     批量移除体素（大崩塌主线程提速，GDScript 逐体素循环替代）
//   - partition_connected:    连通分组（大崩塌掉落体分组提速）
class VoxelNative : public RefCounted {
	GDCLASS(VoxelNative, RefCounted)

protected:
	static void _bind_methods();

public:
	// 贪婪网格合并：对 2D 密集网格做同材质矩形合并
	// grid: 行优先 PackedInt32Array，0=空，否则=材质ID
	// width/height: 网格宽高
	// 返回 Dictionary：{pos: PackedInt32Array, size: PackedInt32Array, val: PackedInt32Array}
	//   pos[i*2]=u, pos[i*2+1]=v; size[i*2]=w, size[i*2+1]=h; val[i]=材质ID
	// 注意：与 GDScript 版行为一致，会就地清零 grid 已合并的格子
	static Dictionary greedy_merge_dense(PackedInt32Array grid, int width, int height);

	// 生成单个 chunk 的网格数据（性能关键路径，等价于 GDScript _generate_chunk_dense_into）
	// halo: 18³ 密集光环缓冲（PackedInt32Array，值=材质ID，0=空）
	// trans_flags: 材质透明标志数组（PackedByteArray，索引=材质ID，1=透明）。由 GDScript 侧
	//              预计算传入，避免 C++ 跨语言读 VoxelMaterial 属性。
	// scale: 体素缩放；chunk: chunk key；use_local_space: 顶点用 chunk 局部坐标；
	// offset: 渲染居中偏移（体素单位）
	// 返回 Dictionary：{solid_verts, solid_normals, solid_uvs, solid_idxs,
	//                   trans_verts, trans_normals, trans_uvs, trans_idxs}
	static Dictionary generate_chunk_dense(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
			float scale, const Vector3i &chunk, bool use_local_space, const Vector3 &offset);

	// 支撑图失稳检测（等价于 VoxelData.find_unsupported_around）
	// buffers: chunk key -> PackedInt32Array(16³) 的密集缓冲快照（VoxelData._chunk_buffers 的深拷贝）
	// removed: 本次被移除的体素位置数组（Array[Vector3i]）
	// 返回：失稳体素位置集合 Dictionary{pos(Vector3i): true}（GDScript 直接作 Set 用）
	// 实时局部传播（无预计算缓存）：有效支撑 = LOWER_5 中 has_voxel 且不在 unstable 的邻居数，
	// 只访问破坏点附近体素。设计为惰性加载：只收集候选及邻居涉及的局部 chunk，避免全量拷贝整世界。
	static Dictionary find_unsupported_around(const Dictionary &buffers, const Array &removed);

	// 批量移除体素（返回修改后的 chunk buffer + 每 chunk 实际移除数）
	// buffers: chunk key -> PackedInt32Array(16³)
	// positions: 待移除位置数组（Array[Vector3i]）
	// 返回 Dictionary：{removed: int 总移除数, chunk_removed: {chunk_key: count},
	//                   buffers: {chunk_key: PackedInt32Array(修改后)} }
	//   GDScript 用返回的 buffers 覆盖 _chunk_buffers，并据此更新计数/dirty
	static Dictionary remove_voxels_bulk(const Dictionary &buffers, const Array &positions);

	// 批量设置体素为同一材质（与 remove_voxels_bulk 对称，替代 set_voxels 的逐体素 GDScript 字典写）。
	// 覆盖语义与 set_voxel 一致：旧值 0（空）→ material_id 计入新增数；旧值非 0 → 原地替换不增计数。
	// material_id: 目标材质 ID（>0）
	// 返回 Dictionary：{added: int 总新增数（0→非0）, chunk_set: {chunk_key: added},
	//                   buffers: {chunk_key: PackedInt32Array(修改后)}, boundary: {chunk_key: 位掩码}}
	//   注：chunk 不在 buffers 中（未加载/不存在）时跳过，GDScript 侧需先 preload/建空 buffer。
	static Dictionary set_voxels_bulk(const Dictionary &buffers, const Array &positions, int material_id);

	// 收集 positions 涉及的 chunk key（去重）。供流式模式 preload 使用：
	// 避免 GDScript 逐体素计算 chunk 的字典开销（遍历在原生，返回去重 chunk 列表）。
	static Array collect_chunks(const Array &positions);

	// 连通分组：positions 按 6 方向连通性分组（与 VoxelData.partition_connected 一致）
	// positions: Array[Vector3i]
	// 返回 Array[Array[Vector3i]]，每组内两两 6 方向连通
	static Array partition_connected(const Array &positions);

	// 快照受影响区域的 chunk 缓冲（chunks + 27 邻居）。
	// buffers: chunk key -> PackedInt32Array(16³)
	// chunks: 需要快照的 chunk key 数组（含其邻居）
	// 返回 Dictionary：{chunk_key: PackedInt32Array}。
	// 用 COW 共享（PackedInt32Array 原子 refcount）：worker 只读 const，主线程后续
	// 写 buffers 触发写时拷贝 → 省去逐 chunk duplicate 的 64KB 深拷贝（大场景快照提速）。
	static Dictionary snapshot_chunks_halo(const Dictionary &buffers, const Array &chunks);
};

} // namespace godot

#endif // VOXEL_NATIVE_H
