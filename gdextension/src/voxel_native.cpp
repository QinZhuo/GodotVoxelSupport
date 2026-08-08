#include "voxel_native.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <array>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace godot;

// ----------------------------------------------------------------------------
// 贪婪网格合并
// ----------------------------------------------------------------------------

Dictionary VoxelNative::greedy_merge_dense(PackedInt32Array p_grid, int width, int height) {
	PackedInt32Array pos_arr;
	PackedInt32Array size_arr;
	PackedInt32Array val_arr;

	if (p_grid.size() < width * height) {
		Dictionary result;
		result["pos"] = pos_arr;
		result["size"] = size_arr;
		result["val"] = val_arr;
		return result;
	}
	int32_t *grid = p_grid.ptrw();

	for (int v = 0; v < height; ++v) {
		int u = 0;
		while (u < width) {
			int c = grid[u + v * width];
			if (c <= 0) {
				u += 1;
				continue;
			}
			int w = 1;
			while (u + w < width && grid[u + w + v * width] == c) {
				w += 1;
			}
			int h = 1;
			bool extend = true;
			while (extend && v + h < height) {
				for (int k = 0; k < w; ++k) {
					if (grid[(u + k) + (v + h) * width] != c) {
						extend = false;
						break;
					}
				}
				if (extend) {
					h += 1;
				}
			}
			pos_arr.append(u);
			pos_arr.append(v);
			size_arr.append(w);
			size_arr.append(h);
			val_arr.append(c);
			for (int y = 0; y < h; ++y) {
				int base = u + (v + y) * width;
				for (int x = 0; x < w; ++x) {
					grid[base + x] = 0;
				}
			}
			u += w;
		}
	}

	Dictionary result;
	result["pos"] = pos_arr;
	result["size"] = size_arr;
	result["val"] = val_arr;
	return result;
}

// ----------------------------------------------------------------------------
// Chunk 网格生成（性能关键路径）
// ----------------------------------------------------------------------------

namespace {

constexpr int CHUNK_SIZE = 16;
constexpr int CHUNK_SLICE = CHUNK_SIZE * CHUNK_SIZE;
constexpr int HALO = 1;
constexpr int HALO_SIZE = CHUNK_SIZE + HALO * 2;

// 网格整数坐标 → 64 位哈希键（顶点去重用；21 位/分量覆盖 ±100 万范围）
inline uint64_t grid_vkey(int x, int y, int z) {
	const uint64_t ux = uint64_t(uint32_t(x));
	const uint64_t uy = uint64_t(uint32_t(y));
	const uint64_t uz = uint64_t(uint32_t(z));
	return (ux << 42) | (uy << 21) | (uz & 0x1FFFFF);
}
inline uint64_t grid_vkey(const Vector3i &p) { return grid_vkey(p.x, p.y, p.z); }

// 6 方向邻居偏移（对应 FaceTool.Normals 顺序：+Y,-Y,-X,+X,+Z,-Z）
constexpr int HALO_DIRS[6] = {
	HALO_SIZE,               // +Y
	-HALO_SIZE,              // -Y
	-1,                      // -X
	1,                       // +X
	HALO_SIZE * HALO_SIZE,   // +Z
	-HALO_SIZE * HALO_SIZE,  // -Z
};

// 每面轴向信息 {perp(切片轴), u(水平轴), v(垂直轴)}（对应 FaceTool.SliceAxis）
struct FaceAxes { int perp, u, v; };
constexpr FaceAxes FACE_AXES[6] = {
	{1, 0, 2},  // +Y Top    perp=Y u=X v=Z
	{1, 0, 2},  // -Y Bottom
	{0, 1, 2},  // -X Left   perp=X u=Y v=Z
	{0, 1, 2},  // +X Right
	{2, 0, 1},  // +Z Front  perp=Z u=X v=Y
	{2, 0, 1},  // -Z Back
};

// 6 面法线（对应 FaceTool.Normals）
constexpr float NORMALS[6][3] = {
	{0, 1, 0}, {0, -1, 0}, {-1, 0, 0}, {1, 0, 0}, {0, 0, 1}, {0, 0, -1},
};

// 6 面顶点（对应 FaceTool.Faces，6 顶点/面 = 2 三角形，顺序与原版一致）
constexpr float FACES[6][6][3] = {
	// Top (+Y)
	{{1, 1, 1}, {0, 1, 1}, {0, 1, 0}, {0, 1, 0}, {1, 1, 0}, {1, 1, 1}},
	// Bottom (-Y)
	{{0, 0, 0}, {0, 0, 1}, {1, 0, 1}, {1, 0, 1}, {1, 0, 0}, {0, 0, 0}},
	// Left (-X)
	{{0, 1, 1}, {0, 0, 1}, {0, 0, 0}, {0, 0, 0}, {0, 1, 0}, {0, 1, 1}},
	// Right (+X)
	{{1, 1, 1}, {1, 1, 0}, {1, 0, 0}, {1, 0, 0}, {1, 0, 1}, {1, 1, 1}},
	// Front (+Z)
	{{0, 1, 1}, {1, 1, 1}, {1, 0, 1}, {1, 0, 1}, {0, 0, 1}, {0, 1, 1}},
	// Back (-Z)
	{{1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 1, 0}, {0, 0, 0}, {1, 0, 0}},
};

inline int axis_val(int x, int y, int z, int axis) {
	return axis == 0 ? x : (axis == 1 ? y : z);
}

inline void set_axis(int &x, int &y, int &z, int axis, int val) {
	if (axis == 0) x = val;
	else if (axis == 1) y = val;
	else z = val;
}

// 单 slice 贪婪合并：输出矩形列表（复用 greedy_merge_dense 逻辑）
void merge_slice(PackedInt32Array &grid, int width, int height,
		std::vector<int> &out_pos, std::vector<int> &out_size, std::vector<int> &out_val) {
	int32_t *g = grid.ptrw();
	for (int v = 0; v < height; ++v) {
		int u = 0;
		while (u < width) {
			int c = g[u + v * width];
			if (c <= 0) { u += 1; continue; }
			int w = 1;
			while (u + w < width && g[u + w + v * width] == c) w += 1;
			int h = 1;
			bool extend = true;
			while (extend && v + h < height) {
				for (int k = 0; k < w; ++k) {
					if (g[(u + k) + (v + h) * width] != c) { extend = false; break; }
				}
				if (extend) h += 1;
			}
			out_pos.push_back(u);
			out_pos.push_back(v);
			out_size.push_back(w);
			out_size.push_back(h);
			out_val.push_back(c);
			for (int y = 0; y < h; ++y) {
				int base = u + (v + y) * width;
				for (int x = 0; x < w; ++x) g[base + x] = 0;
			}
			u += w;
		}
	}
}

} // namespace

Dictionary VoxelNative::generate_chunk_dense(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
		float scale, const Vector3i &chunk, bool use_local_space, const Vector3 &offset) {
	PackedVector3Array solid_verts, solid_normals, trans_verts, trans_normals;
	PackedVector2Array solid_uvs, trans_uvs;
	PackedInt32Array solid_idxs, trans_idxs;

	// 顶点索引化（去重）：以 (网格整数坐标, 法线索引, 材质UV) 为键，
	// 相邻矩形共享角点位置时复用同一顶点，显著减少顶点数（体素表面顶点可降约 2/3）。
	// solid_cache / trans_cache: 键 -> 顶点索引
	std::unordered_map<uint64_t, int> solid_cache;
	std::unordered_map<uint64_t, int> trans_cache;

	if (halo.size() < HALO_SIZE * HALO_SIZE * HALO_SIZE) {
		Dictionary empty;
		empty["solid_verts"] = solid_verts;
		empty["solid_normals"] = solid_normals;
		empty["solid_uvs"] = solid_uvs;
		empty["solid_idxs"] = solid_idxs;
		empty["trans_verts"] = trans_verts;
		empty["trans_normals"] = trans_normals;
		empty["trans_uvs"] = trans_uvs;
		empty["trans_idxs"] = trans_idxs;
		return empty;
	}

	const int32_t *h = halo.ptr();
	const uint8_t *tflags = trans_flags.ptr();
	const int n_mats = trans_flags.size();

	const Vector3i chunk_origin = chunk * CHUNK_SIZE;
	const Vector3 origin_offset = use_local_space ? Vector3(chunk_origin) * scale : Vector3();

	// 6 个面的切片收集器：slices_by_face[face_idx][slice_key] = 16x16 grid（行优先）
	std::array<std::array<PackedInt32Array, CHUNK_SIZE>, 6> slices;

	// 单次遍历 16³：光环下标覆盖 6 邻，全部为数组读取
	for (int z = 0; z < CHUNK_SIZE; ++z) {
		for (int y = 0; y < CHUNK_SIZE; ++y) {
			for (int x = 0; x < CHUNK_SIZE; ++x) {
				const int idx = (x + HALO) + (y + HALO) * HALO_SIZE + (z + HALO) * HALO_SIZE * HALO_SIZE;
				const int v = h[idx];
				if (v <= 0) continue;

				const int mat_id = v;
				const bool is_trans = mat_id < n_mats && tflags[mat_id] != 0;

				for (int face_idx = 0; face_idx < 6; ++face_idx) {
					const int nv = h[idx + HALO_DIRS[face_idx]];

					bool visible = false;
					if (nv <= 0) {
						visible = true;
					} else {
						const int n_mat_id = nv;
						const bool n_trans = n_mat_id < n_mats && tflags[n_mat_id] != 0;
						if (is_trans != n_trans) visible = true;
						else if (is_trans && mat_id != n_mat_id) visible = true;
					}

					if (visible) {
						const FaceAxes &ax = FACE_AXES[face_idx];
						const int slice_key = axis_val(x, y, z, ax.perp);
						const int u = axis_val(x, y, z, ax.u);
						const int vv = axis_val(x, y, z, ax.v);
						auto &grid = slices[face_idx][slice_key];
						if (grid.size() == 0) grid.resize(CHUNK_SLICE);
						grid[u + vv * CHUNK_SIZE] = mat_id;
					}
				}
			}
		}
	}

	// 处理每个面的贪婪合并
	for (int face_idx = 0; face_idx < 6; ++face_idx) {
		const FaceAxes &ax = FACE_AXES[face_idx];
		for (int slice_key = 0; slice_key < CHUNK_SIZE; ++slice_key) {
			auto &grid = slices[face_idx][slice_key];
			if (grid.size() == 0) continue;

			std::vector<int> m_pos, m_size, m_val;
			merge_slice(grid, CHUNK_SIZE, CHUNK_SIZE, m_pos, m_size, m_val);

			const int n_rects = (int)m_val.size();
			for (int i = 0; i < n_rects; ++i) {
				// 重建世界坐标（局部坐标 + chunk_origin 偏移）
				Vector3i pos = chunk_origin;
				pos[ax.perp] += slice_key;
				pos[ax.u] += m_pos[i * 2];
				pos[ax.v] += m_pos[i * 2 + 1];
				Vector3i size(1, 1, 1);
				size[ax.u] = m_size[i * 2];
				size[ax.v] = m_size[i * 2 + 1];

				const int mat_id = m_val[i];
				const bool is_trans = mat_id < n_mats && tflags[mat_id] != 0;
				const Vector3 normal(NORMALS[face_idx][0], NORMALS[face_idx][1], NORMALS[face_idx][2]);
				const float u_uv = (float(mat_id) + 0.5f) / 256.0f;
				const Vector3 sizef(float(size.x), float(size.y), float(size.z));

				for (int p = 0; p < 6; ++p) {
					const Vector3 point(FACES[face_idx][p][0], FACES[face_idx][p][1], FACES[face_idx][p][2]);
					// 网格整数坐标（未乘 scale 的角点位置，用于顶点去重键）
					Vector3i grid_pt(
							pos.x + int(point.x * float(size.x)),
							pos.y + int(point.y * float(size.y)),
							pos.z + int(point.z * float(size.z)));
					const Vector3 world_pos = (Vector3(pos) + point * sizef) * scale - origin_offset + offset * scale;

					if (is_trans) {
						// 去重键：网格坐标 + 法线索引 + 材质ID（同一面同材质才可复用）
						uint64_t key = grid_vkey(grid_pt);
						key = key * 31 + uint64_t(face_idx);
						key = key * 31 + uint64_t(mat_id);
						auto it = trans_cache.find(key);
						if (it != trans_cache.end()) {
							trans_idxs.append(it->second);
						} else {
							const int vi = trans_verts.size();
							trans_verts.append(world_pos);
							trans_normals.append(normal);
							trans_uvs.append(Vector2(u_uv, 0.0f));
							trans_idxs.append(vi);
							trans_cache[key] = vi;
						}
					} else {
						uint64_t key = grid_vkey(grid_pt);
						key = key * 31 + uint64_t(face_idx);
						key = key * 31 + uint64_t(mat_id);
						auto it = solid_cache.find(key);
						if (it != solid_cache.end()) {
							solid_idxs.append(it->second);
						} else {
							const int vi = solid_verts.size();
							solid_verts.append(world_pos);
							solid_normals.append(normal);
							solid_uvs.append(Vector2(u_uv, 0.0f));
							solid_idxs.append(vi);
							solid_cache[key] = vi;
						}
					}
				}
			}
		}
	}

	Dictionary result;
	result["solid_verts"] = solid_verts;
	result["solid_normals"] = solid_normals;
	result["solid_uvs"] = solid_uvs;
	result["solid_idxs"] = solid_idxs;
	result["trans_verts"] = trans_verts;
	result["trans_normals"] = trans_normals;
	result["trans_uvs"] = trans_uvs;
	result["trans_idxs"] = trans_idxs;
	return result;
}

// ----------------------------------------------------------------------------
// 支撑图失稳检测（对应 VoxelData.find_unsupported_around）
// ----------------------------------------------------------------------------

namespace {

constexpr int CHUNK_BITS = 16;  // chunk 边长（体素）

// 体素坐标 -> chunk key（向下取整，正确处理负坐标）
// CHUNK_SIZE=16=2⁴ → 用算术右移替代 std::floor(double/16)，热路径零浮点开销。
// C++ 有符号右移为算术右移（向负无穷），与 std::floor(double(x)/16) 语义一致。
inline Vector3i chunk_of(const Vector3i &pos) {
	return Vector3i(
			pos.x >> 4,
			pos.y >> 4,
			pos.z >> 4);
}

// 体素坐标 -> 哈希键（合并 3 个 int32 为 1 个 uint64，替代 Vector3i 哈希）
inline uint64_t vkey(int x, int y, int z) {
	// 每个分量占 21 位（覆盖 ±1M 范围），符号位保留
	const uint64_t ux = uint64_t(uint32_t(x));
	const uint64_t uy = uint64_t(uint32_t(y));
	const uint64_t uz = uint64_t(uint32_t(z));
	return (ux << 42) | (uy << 21) | (uz & 0x1FFFFF);
}
inline uint64_t vkey(const Vector3i &p) { return vkey(p.x, p.y, p.z); }

// 5 个下方位支撑邻居（LOWER_5：正下 + 4 对角，任意 1 个存在即稳定，保守不连锁）
constexpr int LOWER_5[5][3] = {
	{0, -1, 0}, {-1, -1, 0}, {1, -1, 0}, {0, -1, -1}, {0, -1, 1},
};
// 5 个上方位传播偏移（失稳连锁向上传播）
constexpr int UPPER_5[5][3] = {
	{0, 1, 0}, {-1, 1, 0}, {1, 1, 0}, {0, 1, -1}, {0, 1, 1},
};
// 4 个水平邻居偏移（失稳水平传播，浮空平台外围检测）
constexpr int HORIZONTAL_4[4][3] = {
	{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
};

// 世界坐标 -> chunk 缓冲下标
inline int buf_index(const Vector3i &local) {
	return local.x + local.y * CHUNK_BITS + local.z * CHUNK_BITS * CHUNK_BITS;
}

} // namespace

Dictionary VoxelNative::find_unsupported_around(const Dictionary &buffers, const Array &removed) {
	// 结果：失稳体素集合
	Dictionary unstable;
	if (buffers.is_empty() || removed.is_empty()) {
		return unstable;
	}

	// 惰性构建 chunk 缓冲查找结构：只收集候选体素及其邻居涉及的 chunk。
	// 避免遍历整世界（1183 chunk 全量拷贝是灾难性开销）。
	std::unordered_map<uint64_t, PackedInt32Array> chunk_bufs;
	auto ensure_chunk = [&](const Vector3i &p) {
		const uint64_t kk = vkey(chunk_of(p));
		if (chunk_bufs.find(kk) == chunk_bufs.end()) {
			if (buffers.has(chunk_of(p))) {
				chunk_bufs[kk] = buffers[chunk_of(p)];
			}
		}
	};

	// has_voxel：局部 chunk 内查询（与 GDScript has_voxel 语义一致：值>0 表示存在）
	auto has_voxel = [&](const Vector3i &p) -> bool {
		const Vector3i ck = chunk_of(p);
		const auto it = chunk_bufs.find(vkey(ck));
		if (it == chunk_bufs.end()) {
			return false;
		}
		const Vector3i local = p - ck * CHUNK_BITS;
		if (local.x < 0 || local.y < 0 || local.z < 0 || local.x >= CHUNK_BITS || local.y >= CHUNK_BITS || local.z >= CHUNK_BITS) {
			return false;
		}
		return it->second.ptr()[buf_index(local)] > 0;
	};

	// ---------------------------------------------------------------------------
	// 增量支撑图失稳检测（localized propagation，性能优先，行为与破坏 demo 既有逻辑一致）
	//   体素稳定 ⟺ LOWER_5（正下 + 4 对角下方）中任意 1 个存在且未失稳。
	//   破坏移除 R 后，从 R 的上方位 + 水平候选出发，只沿失稳链传播（UPPER_5 上方 + HORIZONTAL_4 水平），
	//   不遍历整世界/整连通分量 → 连续破坏每帧局部微秒级。
	//   保守判定（对角也算支撑）保证：破坏局部 → 局部塌，不连锁整楼。
	//   候选含水平方向（修复球洞侧壁等"removed 水平邻居悬空"漏检：正下无且无对角 → 掉落）。
	// ---------------------------------------------------------------------------
	// 候选 = removed 的 UPPER_5（上方 5）+ HORIZONTAL_4（水平 4）邻居（存在）
	std::vector<Vector3i> stack;
	std::unordered_set<uint64_t> seed_set;
	for (int i = 0; i < removed.size(); ++i) {
		const Vector3i rp = removed[i];
		ensure_chunk(rp);
		for (int d = 0; d < 5; ++d) {
			const Vector3i nb(rp.x + UPPER_5[d][0], rp.y + UPPER_5[d][1], rp.z + UPPER_5[d][2]);
			ensure_chunk(nb);
			const uint64_t nk = vkey(nb);
			if (has_voxel(nb) && seed_set.find(nk) == seed_set.end()) {
				seed_set.insert(nk);
				stack.push_back(nb);
			}
		}
		for (int d = 0; d < 4; ++d) {
			const Vector3i nb(rp.x + HORIZONTAL_4[d][0], rp.y + HORIZONTAL_4[d][1], rp.z + HORIZONTAL_4[d][2]);
			ensure_chunk(nb);
			const uint64_t nk = vkey(nb);
			if (has_voxel(nb) && seed_set.find(nk) == seed_set.end()) {
				seed_set.insert(nk);
				stack.push_back(nb);
			}
		}
	}

	// 失稳传播（增量）：支撑 = LOWER_5 任意 1 个；removed / unstable 不计支撑；贴地(y==0)稳定
	while (!stack.empty()) {
		const Vector3i cur = stack.back();
		stack.pop_back();
		if (unstable.has(cur)) {
			continue;
		}
		if (cur.y == 0) {
			continue;
		}
		// 有效支撑数 = LOWER_5 中 has_voxel 且不在 unstable 的邻居数
		int effective = 0;
		for (int d = 0; d < 5; ++d) {
			const Vector3i nb(cur.x + LOWER_5[d][0], cur.y + LOWER_5[d][1], cur.z + LOWER_5[d][2]);
			ensure_chunk(nb);
			if (has_voxel(nb) && !unstable.has(nb)) {
				effective += 1;
			}
		}
		if (effective > 0) {
			continue;
		}
		// 失稳
		unstable[cur] = true;
		// 连锁失稳：上方位 5 个 + 水平 4 个
		for (int d = 0; d < 5; ++d) {
			const Vector3i nb(cur.x + UPPER_5[d][0], cur.y + UPPER_5[d][1], cur.z + UPPER_5[d][2]);
			ensure_chunk(nb);
			if (has_voxel(nb) && !unstable.has(nb)) {
				stack.push_back(nb);
			}
		}
		for (int d = 0; d < 4; ++d) {
			const Vector3i nb(cur.x + HORIZONTAL_4[d][0], cur.y + HORIZONTAL_4[d][1], cur.z + HORIZONTAL_4[d][2]);
			ensure_chunk(nb);
			if (has_voxel(nb) && !unstable.has(nb)) {
				stack.push_back(nb);
			}
		}
	}

	return unstable;
}

void VoxelNative::_bind_methods() {
	ClassDB::bind_static_method("VoxelNative", D_METHOD("greedy_merge_dense", "grid", "width", "height"), &VoxelNative::greedy_merge_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_chunk_dense", "halo", "trans_flags", "scale", "chunk", "use_local_space", "offset"), &VoxelNative::generate_chunk_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("find_unsupported_around", "buffers", "removed"), &VoxelNative::find_unsupported_around);
}
