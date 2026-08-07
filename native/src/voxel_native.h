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
//   - find_unsupported_around: 支撑图失稳检测（待实现）
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
	// support_cache: pos(Vector3i) -> 下方支撑计数 的快照（惰性读取，仅触及体素）
	// removed: 本次被移除的体素位置数组（Array[Vector3i]）
	// 返回：失稳体素位置集合 Dictionary{pos(Vector3i): true}（GDScript 直接作 Set 用）
	// 设计为惰性加载：只收集候选及邻居涉及的局部 chunk，避免全量拷贝整世界（破坏卡顿根源）
	static Dictionary find_unsupported_around(const Dictionary &buffers, const Dictionary &support_cache,
			const Array &removed);

	// 批量移除后计算支撑缓存增量更新（等价于 VoxelData._support_cache_on_remove_batch 的 C++ 版）
	// support_cache: pos(Vector3i) -> 下方支撑计数 的快照（只读输入，用于判断）
	// buffers: chunk key -> PackedInt32Array 的密集缓冲快照（用于 has_voxel 判断）
	// positions: 被移除的体素位置数组（Array[Vector3i]）
	// 返回增量字典 {removed: Array[Vector3i], updated: {pos: count}}，由 GDScript 侧原地应用。
	// 设计为增量而非返回全量缓存，避免深拷贝 143 万条支撑记录（破坏卡顿的根源）。
	// 注意：buffers 必须已反映移除后的状态（调用方先 remove 再调用本函数）
	static Dictionary update_support_cache_remove(const Dictionary &support_cache, const Dictionary &buffers,
			const Array &positions);
};

} // namespace godot

#endif // VOXEL_NATIVE_H
