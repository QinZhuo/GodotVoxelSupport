#ifndef VOXEL_NATIVE_H
#define VOXEL_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace godot {

// 体素插件原生核心（GDExtension C++）——插件的**硬依赖**：全部热路径都在这里，
// GDScript 侧只做编排（NativeLoader 一次性校验必需方法，缺失即报错，不做 GDScript 兜底）。
//   - greedy_merge_dense:     贪婪网格合并（2D 同材质矩形合并）
//   - generate_chunk_dense:   chunk 网格生成主循环（32³ 体素 × 6 方向可见性 + 贪婪合并）
//   - find_unsupported_around: 支撑失稳检测（列支撑判定，运行期唯一实现）
//   - remove_voxels_bulk:     批量移除体素（大崩塌主线程提速）
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
	// 注意：会就地清零 grid 已合并的格子
	static Dictionary greedy_merge_dense(PackedInt32Array grid, int width, int height);

	// 生成单个 chunk 的网格数据（性能关键路径）
	// halo: 34³ 密集光环缓冲（PackedInt32Array，值=材质ID，0=空）
	// trans_flags: 材质透明标志数组（PackedByteArray，索引=材质ID，1=透明）。由 GDScript 侧
	//              预计算传入，避免 C++ 跨语言读 VoxelMaterial 属性。
	// scale: 体素缩放；chunk: chunk key；use_local_space: 顶点用 chunk 局部坐标；
	// offset: 渲染居中偏移（体素单位）
	// 返回 Dictionary：{solid_verts, solid_normals, solid_uvs, solid_idxs,
	//                   trans_verts, trans_normals, trans_uvs, trans_idxs}
	static Dictionary generate_chunk_dense(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
			float scale, const Vector3i &chunk, bool use_local_space, const Vector3 &offset);

	// LOD1 大块网格：一次性生成 32³ 大格（每大格 = 2³ 体素，世界尺寸 = scale）的大块 mesh。
	// 参考 godot_voxel 大 block 方案：按大块一次生成（大 halo），而非"小块生成后合并"。
	// halo: (32+2)³ 大格光环（中心 32³ + 1 外缘）；block_key: 大块 key（覆盖 32³ 大格）。
	// 返回与 generate_chunk_dense 相同的 Dictionary（solid/trans 顶点）。
	static Dictionary generate_lod1_block_dense(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
			float scale, const Vector3i &block_key, const Vector3 &offset);

	// 构建 chunk 的 34³ halo（中心 32³ + 1 外缘）——LOD0 网格生成 worker 用，
	// 遍历 27 邻居与光环的重叠区。
	static PackedInt32Array build_halo_from_buffers(const Dictionary &buffers, const Vector3i &chunk);

	// 稀疏体素字典 → 网格 arrays（掉落体大块/大范围破坏核心：分 chunk + 原生 dense 面生成 + 合并，全 C++）
	static Dictionary generate_arrays_native(const Dictionary &voxels, const PackedByteArray &trans_flags,
			float scale, const Vector3 &offset);

	// 球体网格（导入 shape=sphere）：每体素一颗 icosphere，按顶点预算自动降采样。
	// subdivisions: icosphere 细分级别(0..2)；sphere_scale: 小球半径/体素边长；
	// vertex_budget: 顶点上限（超出则自动放大采样间隔）。
	// 返回 Dictionary：{solid_verts, solid_normals, solid_uvs, solid_idxs,
	//                   trans_verts, trans_normals, trans_uvs, trans_idxs, step}
	static Dictionary generate_spheres_native(const Dictionary &voxels, const PackedByteArray &trans_flags,
			int subdivisions, float sphere_scale, float scale, int vertex_budget);

	// 从 LOD0 chunk buffers 降采样构建 LOD 大块 34³ halo（lod_shift>=2 通用降采样，文件流粗层缓存用）
	static PackedInt32Array build_lod_block_halo_from_buffers_native(const Dictionary &buffers,
			const Vector3i &block_key, int lod_shift);

	// 金字塔增量降采样：只重算 block 内 [rmin,rmax] 脏大格，未脏大格从 coarse 复用。
	// 与全量降采样规则一致（取第一个非空材质），保证结果一致。编辑后破坏成本 O(脏大格)。
	// coarse: 现有 block 大格数据（32³）；返回完整 block 数据（脏大格已更新）。
	static PackedInt32Array patch_lod_block(const Dictionary &buffers, const Vector3i &block_key,
			int lod_shift, const PackedInt32Array &coarse,
			const Vector3i &rmin, const Vector3i &rmax);

	// 金字塔逐级上推：当前层（lod>=2）从上一层 coarse 数据降采样（而非从 L0 全量）。
	// coarse_buffers: 上一层 block → PackedInt32Array(32³ 大格)。返回完整当前 block 大格数据。
	static PackedInt32Array patch_lod_block_from_lod(const Dictionary &coarse_buffers,
			const Vector3i &block_key, int lod, const PackedInt32Array &coarse,
			const Vector3i &rmin, const Vector3i &rmax);

	// 从独立 LOD 数据块（每 LOD 32³ 大格）构建 34³ halo（直接拷大格，无降采样）：中心 32³ + 6 外缘面
	static PackedInt32Array build_lod_block_halo_from_lod_buffers_native(const Dictionary &buffers,
			const Vector3i &block_key);

	// 支撑失稳检测（基线实现，见 .cpp 注释）：返回 {pos(Vector3i): true}。
	static Dictionary find_unsupported_around(const Dictionary &buffers, const Array &removed);

	// 应力传播（裂纹扩散）：从 removed 出发，6 邻居 BFS。
	// strength_table: 材质连接强度表（PackedFloat32Array，索引=材质ID），GDScript 预取传入。
	// max_steps/force/decay: 应力传播参数（与 VoxelDestructible.stress_* 一致）。
	// 返回 Array[Vector3i]（应力断裂体素）。
	static Array propagate_stress(const Dictionary &buffers, const Array &removed,
			const PackedFloat32Array &strength_table, int max_steps, float force, float decay);

	// 批量收集体素材质 ID（替代 GDScript 逐体素 get_voxel 字典查询）。
	// 与 get_voxel 语义一致：有体素 → 材质 ID（>0），无体素 → -1。
	// 返回 Dictionary{pos(Vector3i): int}。
	static Dictionary collect_materials(const Dictionary &buffers, const Array &positions);

	// 批量移除体素（返回修改后的 chunk buffer + 每 chunk 实际移除数）
	// buffers: chunk key -> PackedInt32Array(32³)
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
	// buffers: chunk key -> PackedInt32Array(32³)
	// chunks: 需要快照的 chunk key 数组（含其邻居）
	// 返回 Dictionary：{chunk_key: PackedInt32Array}。
	// 用 COW 共享（PackedInt32Array 原子 refcount）：worker 只读 const，主线程后续
	// 写 buffers 触发写时拷贝 → 省去逐 chunk duplicate 的 64KB 深拷贝（大场景快照提速）。
	static Dictionary snapshot_chunks_halo(const Dictionary &buffers, const Array &chunks);

	// ---- QVox 块级编解码（原生）----
	// GDScript 版 pick+pack 是逐元素扫描（混合值块约 15ms/块），原生化后约 0.2ms。
	// 选择规则与字节布局以 QVoxSpec / docs/QVOX_FORMAT.md 为准。
	// 返回 {codec:int, payload:PackedByteArray}；EMPTY 时 codec=0、payload 空。
	static Dictionary choose_and_pack(const PackedInt32Array &buf, int n);

	// 按指定 codec 打包（供"codec 已知"的路径与测试使用）。EMPTY / 非法 codec 返回空。
	static PackedByteArray pack_with_codec(int codec, const PackedInt32Array &buf, int n);

	// 一块密集缓冲的值域 (min, max)；空缓冲返回 (0, 0)。
	// 供"整块材质值必须 < entry_count"这类整块校验用：把 32768 次 GDScript 循环降为一次原生扫描。
	static Vector2i voxel_value_range(const PackedInt32Array &buf);

	// 按 codec 解包负载，返回长度 n 的缓冲；负载损坏（长度不符 / 游程和 ≠ n / 索引越界）返回空。
	// 与 pack_with_codec 对称。GDScript 版是逐元素循环：实测 196 块（1MB）要 1047ms，
	// 原生化后是毫秒级——这是"打开大存档"的主要耗时。
	static PackedInt32Array unpack_block(int codec, const PackedByteArray &payload, int n);

	// ---- 体素枚举（原生批量：替代 GDScript 逐体素循环 + 逐体素 Callable / Variant 装箱）----
	// buffers: chunk key -> PackedInt32Array(32³)。以下四个都只读 buffers，不修改。
	//
	// 全部非空体素位置（Array[Vector3i]）。
	static Array collect_all_positions(const Dictionary &buffers);
	// 全部非空体素的 (x, y, z, mat) 四元组扁平数组。
	// 供存档载荷使用：相比"每个体素一个 4 元素 Array"省掉百万级小对象与约一个数量级内存。
	static PackedInt32Array collect_all_flat(const Dictionary &buffers);
	// 内容包围盒，返回 [min:Vector3i, max:Vector3i]；无体素返回空 Array。
	static Array collect_bounds(const Dictionary &buffers);
	// 球内体素位置（判定与 GDScript 版一致：dx²+dy²+dz² <= radius²，float 比较；
	// 候选只扫"球 AABB ∩ chunk"的格子）。
	static Array collect_sphere_positions(const Dictionary &buffers, const Vector3 &center, float radius);
	// 盒内体素位置（闭区间 [min_p, max_p]，体素坐标）。
	static Array collect_box_positions(const Dictionary &buffers, const Vector3i &min_p, const Vector3i &max_p);
	// ---- 破坏内核（统一形状 + 累伤一趟完成）----
	// 一趟内完成"框定 chunk → 读材质 → 比硬度 → 累加 / 判移除"；材质就在遍历到的 chunk 缓冲里，
	// 所以不需要"先收集位置、再收集材质"两趟。
	//   shape：0 = 球（center/radius）｜1 = 盒（闭区间 vmin..vmax）——两者只差一个有符号距离，
	//          新增形状只需再补一个距离函数，其余（噪声/方向偏置/伤害结算）全部复用。
	//   opts（都可选）：
	//     noise     : 0..1，沿边界按 3D 值噪声抖动 → 坑口不规整（0 = 完美形状，零成本）
	//     direction : Vector3，冲击方向（与 bias 配合使用）
	//     bias      : 沿 direction 的拉伸系数 → 锥形/水滴形破坏（"朝里打"）
	//   其余契约同旧 damage_sphere/damage_box：damage_chunks 由调用方写回。
	static Dictionary damage_shape(const Dictionary &buffers, const Dictionary &damage_chunks, int shape,
			const Vector3 &center, float radius, const Vector3i &vmin, const Vector3i &vmax,
			const PackedFloat32Array &hardness_table, float damage, bool use_health, const Dictionary &opts);
	// 把扁平 (x, y, z, mat) 四元组装回 chunk 缓冲，返回 {chunk_key: PackedInt32Array(32³)}（均为新缓冲）。
	// 与 collect_all_flat 成对（收 / 装），供存档载荷重建。
	static Dictionary install_flat_voxels(const PackedInt32Array &flat);

	// ---- QVox 格式：CRC32（读写两端唯一实现） ----
	// 标准 CRC32（IEEE 802.3，反射多项式 0xEDB88320），与 zlib 口径一致。
	// 覆盖 data[start, start+length)，含初值 0xFFFFFFFF 与终值异或。
	//
	// 【为什么放在这里】GDScript 逐字节查表算 1.4MB 要 ~84ms，是 QVox 写盘的最大单项开销
	// （曾尝试 crc32_combine 拼接与 slicing-by-8，在解释器下都不成立）；C++ 下 ~0.5ms。
	// 因此 GDScript 侧不再保留兜底实现，读写校验与子块索引都调这两个方法。
	//
	// start/length 允许 -1：start<0 → 0；length<0 → 到末尾。越界自动裁剪。
	static int64_t crc32(const PackedByteArray &data, int64_t start, int64_t length);

	// 一次算多段：offsets[i] / lengths[i] 逐对给出各段区间，语义等价于把各段顺序
	// 拼接后算一次 CRC32。用于"块前缀(length‖type) ‖ 负载"这类多段场景，
	// 免去 GDScript 侧先拼一段临时 PackedByteArray 再算。
	static int64_t crc32_segments(const PackedByteArray &data, const PackedInt64Array &offsets, const PackedInt64Array &lengths);
};

} // namespace godot

#endif // VOXEL_NATIVE_H
