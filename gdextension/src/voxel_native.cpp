#include "voxel_native.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <array>
#include <cstdint>
#include <map>
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

constexpr int CHUNK_SIZE = 32;
constexpr int CHUNK_SHIFT = 5;   // 2^5 = 32（chunk_of 算术右移）
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

// Generic dense volume mesh generation: size = edge length (grid units),
// halo = (size+2)^3 (center + 1 shell). LOD0 (16) and LOD1 big-block (32) share this core.
Dictionary generate_dense_impl(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
		float scale, const Vector3i &chunk_origin, bool use_local_space, const Vector3 &offset, int size) {
	PackedVector3Array solid_verts, solid_normals, trans_verts, trans_normals;
	PackedVector2Array solid_uvs, trans_uvs;
	PackedInt32Array solid_idxs, trans_idxs;
	std::unordered_map<uint64_t, int> solid_cache;
	std::unordered_map<uint64_t, int> trans_cache;
	const int size_slice = size * size;
	const int halo_size = size + 2;
	const int hdirs[6] = {
		halo_size, -halo_size, -1, 1,
		halo_size * halo_size, -halo_size * halo_size,
	};
	if (halo.size() < halo_size * halo_size * halo_size) {
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
	const Vector3 origin_offset = use_local_space ? Vector3(chunk_origin) * scale : Vector3();
	std::vector<std::vector<PackedInt32Array>> slices(6, std::vector<PackedInt32Array>(size));
	for (int z = 0; z < size; ++z) {
		for (int y = 0; y < size; ++y) {
			for (int x = 0; x < size; ++x) {
				const int idx = (x + 1) + (y + 1) * halo_size + (z + 1) * halo_size * halo_size;
				const int v = h[idx];
				if (v <= 0) continue;
				const int mat_id = v;
				const bool is_trans = mat_id < n_mats && tflags[mat_id] != 0;
				for (int face_idx = 0; face_idx < 6; ++face_idx) {
					const int nv = h[idx + hdirs[face_idx]];
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
						if (grid.size() == 0) grid.resize(size_slice);
						grid[u + vv * size] = mat_id;
					}
				}
			}
		}
	}
	for (int face_idx = 0; face_idx < 6; ++face_idx) {
		const FaceAxes &ax = FACE_AXES[face_idx];
		for (int slice_key = 0; slice_key < size; ++slice_key) {
			auto &grid = slices[face_idx][slice_key];
			if (grid.size() == 0) continue;
			std::vector<int> m_pos, m_size, m_val;
			merge_slice(grid, size, size, m_pos, m_size, m_val);
			const int n_rects = (int)m_val.size();
			for (int i = 0; i < n_rects; ++i) {
				Vector3i pos = chunk_origin;
				pos[ax.perp] += slice_key;
				pos[ax.u] += m_pos[i * 2];
				pos[ax.v] += m_pos[i * 2 + 1];
				Vector3i sz(1, 1, 1);
				sz[ax.u] = m_size[i * 2];
				sz[ax.v] = m_size[i * 2 + 1];
				const int mat_id = m_val[i];
				const bool is_trans = mat_id < n_mats && tflags[mat_id] != 0;
				const Vector3 normal(NORMALS[face_idx][0], NORMALS[face_idx][1], NORMALS[face_idx][2]);
				const float u_uv = (float(mat_id) + 0.5f) / 256.0f;
				const Vector3 sizef(float(sz.x), float(sz.y), float(sz.z));
				for (int p = 0; p < 6; ++p) {
					const Vector3 point(FACES[face_idx][p][0], FACES[face_idx][p][1], FACES[face_idx][p][2]);
					Vector3i grid_pt(
							pos.x + int(point.x * float(sz.x)),
							pos.y + int(point.y * float(sz.y)),
							pos.z + int(point.z * float(sz.z)));
					const Vector3 world_pos = (Vector3(pos) + point * sizef) * scale - origin_offset + offset * scale;
					if (is_trans) {
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

} // namespace

Dictionary VoxelNative::generate_chunk_dense(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
		float scale, const Vector3i &chunk, bool use_local_space, const Vector3 &offset) {
	// LOD0: 16x16x16, reuse generic dense generator
	return generate_dense_impl(halo, trans_flags, scale, chunk * CHUNK_SIZE, use_local_space, offset, CHUNK_SIZE);
}

// LOD1 big block: generate a 32x32x32 voxel-grid mesh in one pass (godot_voxel style big block).
Dictionary VoxelNative::generate_lod1_block_dense(const PackedInt32Array &halo, const PackedByteArray &trans_flags,
		float scale, const Vector3i &block_key, const Vector3 &offset) {
	constexpr int LOD1_BLOCK_SIZE = 32;
	return generate_dense_impl(halo, trans_flags, scale, block_key * LOD1_BLOCK_SIZE, true, offset, LOD1_BLOCK_SIZE);
}

PackedInt32Array VoxelNative::build_halo_from_buffers(const Dictionary &buffers, const Vector3i &chunk) {
	// 构建 18³ halo（中心 16³ + 1 外缘）：遍历 27 邻居 chunk 与光环的重叠区，数组下标读取。
	// 下沉 C++ 替代 GDScript 逐体素循环（worker 端 halo 构建吞吐提升）。
	PackedInt32Array halo;
	halo.resize(HALO_SIZE * HALO_SIZE * HALO_SIZE);
	const Vector3i origin = chunk * CHUNK_SIZE;
	for (int nz = 0; nz < 3; ++nz) {
		for (int ny = 0; ny < 3; ++ny) {
			for (int nx = 0; nx < 3; ++nx) {
				const Vector3i nck(chunk.x + nx - HALO, chunk.y + ny - HALO, chunk.z + nz - HALO);
				if (!buffers.has(nck)) {
					continue;
				}
				PackedInt32Array buf = buffers[nck];
				if (buf.size() < CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) {
					continue;
				}
				const int32_t *b = buf.ptr();
				const Vector3i n_origin = nck * CHUNK_SIZE;
				const int lo_x = std::max(origin.x - HALO, n_origin.x);
				const int lo_y = std::max(origin.y - HALO, n_origin.y);
				const int lo_z = std::max(origin.z - HALO, n_origin.z);
				const int hi_x = std::min(origin.x + CHUNK_SIZE + HALO, n_origin.x + CHUNK_SIZE) - 1;
				const int hi_y = std::min(origin.y + CHUNK_SIZE + HALO, n_origin.y + CHUNK_SIZE) - 1;
				const int hi_z = std::min(origin.z + CHUNK_SIZE + HALO, n_origin.z + CHUNK_SIZE) - 1;
				if (lo_x > hi_x || lo_y > hi_y || lo_z > hi_z) {
					continue;
				}
				for (int z = lo_z; z <= hi_z; ++z) {
					for (int y = lo_y; y <= hi_y; ++y) {
						for (int x = lo_x; x <= hi_x; ++x) {
							const int hx = x - origin.x + HALO;
							const int hy = y - origin.y + HALO;
							const int hz = z - origin.z + HALO;
							const int local = (x - n_origin.x) + (y - n_origin.y) * CHUNK_SIZE + (z - n_origin.z) * CHUNK_SIZE * CHUNK_SIZE;
							halo[hx + hy * HALO_SIZE + hz * HALO_SIZE * HALO_SIZE] = b[local];
						}
					}
				}
			}
		}
	}
	return halo;
}

// 稀疏体素字典 → 18³ dense halo（掉落体/大破坏的 _halo_from_dict 下沉）
PackedInt32Array VoxelNative::build_halo_from_voxels(const Dictionary &voxels, const Vector3i &chunk) {
	PackedInt32Array halo;
	halo.resize(HALO_SIZE * HALO_SIZE * HALO_SIZE);
	const Vector3i origin = chunk * CHUNK_SIZE;
	for (int z = 0; z < HALO_SIZE; ++z) {
		for (int y = 0; y < HALO_SIZE; ++y) {
			for (int x = 0; x < HALO_SIZE; ++x) {
				const Vector3i p(origin.x + x - HALO, origin.y + y - HALO, origin.z + z - HALO);
				const Variant v = voxels.get(p, 0);
				if (v.get_type() == Variant::INT) {
					const int64_t m = v;
					if (m > 0) {
						halo[x + y * HALO_SIZE + z * HALO_SIZE * HALO_SIZE] = (int32_t)m;
					}
				}
			}
		}
	}
	return halo;
}

namespace {
// 合并原生 dense arrays 到全局数组（顶点加 base 索引偏移）
void append_arrays_native(PackedVector3Array &verts, PackedVector3Array &normals, PackedVector2Array &uvs,
		PackedInt32Array &idxs, const Dictionary &arr, const char *prefix, int base) {
	const PackedVector3Array v = arr[String(prefix) + "_verts"];
	if (v.is_empty()) {
		return;
	}
	for (int i = 0; i < v.size(); ++i) {
		verts.append(v[i]);
	}
	normals.append_array(arr[String(prefix) + "_normals"]);
	uvs.append_array(arr[String(prefix) + "_uvs"]);
	const PackedInt32Array ind = arr[String(prefix) + "_idxs"];
	for (int i = 0; i < ind.size(); ++i) {
		idxs.append(ind[i] + base);
	}
}
} // namespace

// 稀疏体素字典 → 网格 arrays（掉落体大块/大范围破坏核心：分 chunk + 原生 dense 面生成 + 合并，全 C++）
Dictionary VoxelNative::generate_arrays_native(const Dictionary &voxels, const PackedByteArray &trans_flags,
		float scale, const Vector3 &offset) {
	// 1. 分 chunk：体素按 chunk key 分组；体素材质查表
	std::unordered_map<uint64_t, std::vector<Vector3i>> chunks;
	std::unordered_map<uint64_t, int32_t> mat_map;
	{
		const Array keys = voxels.keys();
		for (int i = 0; i < keys.size(); ++i) {
			const Vector3i p = keys[i];
			const int64_t m = voxels[p];
			if (m <= 0) {
				continue;
			}
			const Vector3i ck(p.x >> CHUNK_SHIFT, p.y >> CHUNK_SHIFT, p.z >> CHUNK_SHIFT);
			chunks[grid_vkey(ck)].push_back(p);
			mat_map[grid_vkey(p)] = (int32_t)m;
		}
	}
	PackedVector3Array sv, sn, tv, tn;
	PackedVector2Array su, tu;
	PackedInt32Array si, ti;
	int solid_base = 0;
	int trans_base = 0;
	for (auto &it : chunks) {
		auto &voxs = it.second;
		if (voxs.empty()) {
			continue;
		}
		const Vector3i ck(voxs[0].x >> CHUNK_SHIFT, voxs[0].y >> CHUNK_SHIFT, voxs[0].z >> CHUNK_SHIFT);
		// 2. 构建 18³ halo（含邻居，查体素表）
		PackedInt32Array halo;
		halo.resize(HALO_SIZE * HALO_SIZE * HALO_SIZE);
		const Vector3i origin = ck * CHUNK_SIZE;
		for (int z = 0; z < HALO_SIZE; ++z) {
			for (int y = 0; y < HALO_SIZE; ++y) {
				for (int x = 0; x < HALO_SIZE; ++x) {
					const Vector3i p(origin.x + x - HALO, origin.y + y - HALO, origin.z + z - HALO);
					auto mit = mat_map.find(grid_vkey(p));
					if (mit != mat_map.end() && mit->second > 0) {
						halo[x + y * HALO_SIZE + z * HALO_SIZE * HALO_SIZE] = mit->second;
					}
				}
			}
		}
		// 3. 原生 dense 面生成（world 坐标）+ 合并
		const Dictionary arr = generate_dense_impl(halo, trans_flags, scale, origin, false, offset, CHUNK_SIZE);
		append_arrays_native(sv, sn, su, si, arr, "solid", solid_base);
		append_arrays_native(tv, tn, tu, ti, arr, "trans", trans_base);
		solid_base = sv.size();
		trans_base = tv.size();
	}
	Dictionary result;
	if (!si.is_empty() || !ti.is_empty()) {
		result["solid_verts"] = sv;
		result["solid_normals"] = sn;
		result["solid_uvs"] = su;
		result["solid_idxs"] = si;
		result["trans_verts"] = tv;
		result["trans_normals"] = tn;
		result["trans_uvs"] = tu;
		result["trans_idxs"] = ti;
	}
	return result;
}

PackedInt32Array VoxelNative::build_lod1_block_halo_from_buffers(const Dictionary &buffers, const Vector3i &block_key) {
	// 构建 LOD1 大块(32³ 大格)的 34³ halo：中心 32³ 大格（每格 = 2³ 体素，从 2×2×2 chunk 降采样）
	// + 6 外缘面（相邻大块边界 1 大格层）。CHUNK_SIZE 自适应：
	//   CHUNK_SIZE=16 → block 覆盖 4×4×4 chunk；CHUNK_SIZE=32 → 2×2×2 chunk（体素 64³ 不变）。
	constexpr int BS = 32;       // 大块大格边长
	constexpr int HS = BS + 2;   // halo 边长
	constexpr int BLOCK_VOXELS = BS * 2;  // 大块体素边长（恒 64）
	constexpr int SUB_PER_CHUNK = CHUNK_SIZE / 2;           // 每 chunk 大格数（16@32）
	constexpr int CHUNKS_PER_BLOCK = BS / SUB_PER_CHUNK;    // block 覆盖 chunk 数（2@32）
	PackedInt32Array halo;
	halo.resize(HS * HS * HS);
	// 中心 32³
	const Vector3i base_chunk = block_key * CHUNKS_PER_BLOCK;
	for (int cz = 0; cz < CHUNKS_PER_BLOCK; ++cz) {
		for (int cy = 0; cy < CHUNKS_PER_BLOCK; ++cy) {
			for (int cx = 0; cx < CHUNKS_PER_BLOCK; ++cx) {
				const Vector3i ck(base_chunk.x + cx, base_chunk.y + cy, base_chunk.z + cz);
				if (!buffers.has(ck)) continue;
				PackedInt32Array buf = buffers[ck];
				if (buf.size() < CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) continue;
				const int32_t *b = buf.ptr();
				for (int lz8 = 0; lz8 < SUB_PER_CHUNK; ++lz8) {
					for (int ly8 = 0; ly8 < SUB_PER_CHUNK; ++ly8) {
						for (int lx8 = 0; lx8 < SUB_PER_CHUNK; ++lx8) {
							const int lx = cx * SUB_PER_CHUNK + lx8;
							const int ly = cy * SUB_PER_CHUNK + ly8;
							const int lz = cz * SUB_PER_CHUNK + lz8;
							int mat = 0;
							for (int dz = 0; dz < 2; ++dz) {
								for (int dy = 0; dy < 2; ++dy) {
									for (int dx = 0; dx < 2; ++dx) {
										const int m = b[(lx8*2+dx) + (ly8*2+dy)*CHUNK_SIZE + (lz8*2+dz)*CHUNK_SIZE*CHUNK_SIZE];
										if (m > 0) { mat = m; break; }
									}
									if (mat > 0) break;
								}
								if (mat > 0) break;
							}
							halo[(1+lx) + (1+ly)*HS + (1+lz)*HS*HS] = mat;
						}
					}
				}
			}
		}
	}
	// 6 外缘面：相邻大块边界 1 大格层（降采样 2³ 体素）
	const Vector3i dirs[6] = {
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1),
	};
	for (int di = 0; di < 6; ++di) {
		const Vector3i d = dirs[di];
		const Vector3i nbk = block_key + d;
		const int face = (d.x != 0) ? 0 : ((d.y != 0) ? 1 : 2);
		const int fix_grid = (d[face] > 0) ? 0 : (BS - 1);
		const int halo_pos = (d[face] < 0) ? 0 : (HS - 1);
		for (int lv = 0; lv < BS; ++lv) {
			for (int lu = 0; lu < BS; ++lu) {
				int mat = 0;
				for (int dv = 0; dv < 2; ++dv) {
					for (int du = 0; du < 2; ++du) {
						for (int df = 0; df < 2; ++df) {
							const int vx = nbk.x*BLOCK_VOXELS + ((face == 0) ? (fix_grid*2+df) : (lu*2+du));
							const int vy = nbk.y*BLOCK_VOXELS + ((face == 1) ? (fix_grid*2+df) : (lv*2+dv));
							const int vz = nbk.z*BLOCK_VOXELS + ((face == 2) ? (fix_grid*2+df) : (lv*2+dv));
							const Vector3i ck(vx>>CHUNK_SHIFT, vy>>CHUNK_SHIFT, vz>>CHUNK_SHIFT);
							if (!buffers.has(ck)) continue;
							PackedInt32Array buf = buffers[ck];
							if (buf.size() < CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) continue;
							const int32_t *b = buf.ptr();
							const int local = (vx - ck.x*CHUNK_SIZE) + (vy - ck.y*CHUNK_SIZE)*CHUNK_SIZE + (vz - ck.z*CHUNK_SIZE)*CHUNK_SIZE*CHUNK_SIZE;
							const int m = b[local];
							if (m > 0) { mat = m; break; }
						}
						if (mat > 0) break;
					}
					if (mat > 0) break;
				}
				int hx, hy, hz;
				if (face == 0) { hx = halo_pos; hy = 1+lu; hz = 1+lv; }
				else if (face == 1) { hx = 1+lu; hy = halo_pos; hz = 1+lv; }
				else { hx = 1+lu; hy = 1+lv; hz = halo_pos; }
				halo[hx + hy*HS + hz*HS*HS] = mat;
			}
		}
	}
	return halo;
}

// 通用降采样：从 LOD0 chunk buffers 构建 LOD 大块 34³ halo（任意 lod_shift）。
// lod_shift=1 → cell=2，与 build_lod1_block_halo_from_buffers 等价；更高层每大格 = 2^lod_shift 体素。
PackedInt32Array VoxelNative::build_lod_block_halo_from_buffers_native(const Dictionary &buffers, const Vector3i &block_key, int lod_shift) {
	constexpr int BS = 32;       // 大块大格边长
	constexpr int HS = BS + 2;   // halo 边长
	const int cell = 1 << lod_shift;                       // 每大格体素
	const int sub_per_chunk = CHUNK_SIZE / cell;           // 每 chunk 大格数
	const int chunks_per_block = BS / sub_per_chunk;       // block 覆盖 chunk 数
	const int block_voxels = BS * cell;                    // 大块体素边长
	PackedInt32Array halo;
	halo.resize(HS * HS * HS);
	// 中心 32³ 大格降采样
	const Vector3i base_chunk = block_key * chunks_per_block;
	for (int cz = 0; cz < chunks_per_block; ++cz) {
		for (int cy = 0; cy < chunks_per_block; ++cy) {
			for (int cx = 0; cx < chunks_per_block; ++cx) {
				const Vector3i ck(base_chunk.x + cx, base_chunk.y + cy, base_chunk.z + cz);
				if (!buffers.has(ck)) continue;
				const PackedInt32Array buf = buffers[ck];
				if (buf.size() < CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) continue;
				const int32_t *b = buf.ptr();
				for (int lz8 = 0; lz8 < sub_per_chunk; ++lz8) {
					for (int ly8 = 0; ly8 < sub_per_chunk; ++ly8) {
						for (int lx8 = 0; lx8 < sub_per_chunk; ++lx8) {
							const int lx = cx * sub_per_chunk + lx8;
							const int ly = cy * sub_per_chunk + ly8;
							const int lz = cz * sub_per_chunk + lz8;
							int mat = 0;
							for (int dz = 0; dz < cell && mat == 0; ++dz) {
								for (int dy = 0; dy < cell && mat == 0; ++dy) {
									for (int dx = 0; dx < cell; ++dx) {
										const int m = b[(lx8*cell+dx) + (ly8*cell+dy)*CHUNK_SIZE + (lz8*cell+dz)*CHUNK_SIZE*CHUNK_SIZE];
										if (m > 0) { mat = m; break; }
									}
								}
							}
							halo[(1+lx) + (1+ly)*HS + (1+lz)*HS*HS] = mat;
						}
					}
				}
			}
		}
	}
	// 6 外缘面：相邻大块边界 1 大格层（降采样 cell³ 体素）
	const Vector3i dirs[6] = {
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1),
	};
	for (int di = 0; di < 6; ++di) {
		const Vector3i d = dirs[di];
		const Vector3i nbk = block_key + d;
		const int face = (d.x != 0) ? 0 : ((d.y != 0) ? 1 : 2);
		const int fix_grid = (d[face] > 0) ? 0 : (BS - 1);
		const int halo_pos = (d[face] < 0) ? 0 : (HS - 1);
		for (int lv = 0; lv < BS; ++lv) {
			for (int lu = 0; lu < BS; ++lu) {
				int mat = 0;
				for (int dv = 0; dv < cell && mat == 0; ++dv) {
					for (int du = 0; du < cell && mat == 0; ++du) {
						for (int df = 0; df < cell; ++df) {
							const int vx = nbk.x*block_voxels + ((face == 0) ? (fix_grid*cell+df) : (lu*cell+du));
							const int vy = nbk.y*block_voxels + ((face == 1) ? (fix_grid*cell+df) : (lv*cell+dv));
							const int vz = nbk.z*block_voxels + ((face == 2) ? (fix_grid*cell+df) : (lv*cell+dv));
							const Vector3i ck(vx>>CHUNK_SHIFT, vy>>CHUNK_SHIFT, vz>>CHUNK_SHIFT);
							if (!buffers.has(ck)) continue;
							const PackedInt32Array buf = buffers[ck];
							if (buf.size() < CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) continue;
							const int32_t *b = buf.ptr();
							const int local = (vx - ck.x*CHUNK_SIZE) + (vy - ck.y*CHUNK_SIZE)*CHUNK_SIZE + (vz - ck.z*CHUNK_SIZE)*CHUNK_SIZE*CHUNK_SIZE;
							const int m = b[local];
							if (m > 0) { mat = m; break; }
						}
					}
				}
				int hx, hy, hz;
				if (face == 0) { hx = halo_pos; hy = 1+lu; hz = 1+lv; }
				else if (face == 1) { hx = 1+lu; hy = halo_pos; hz = 1+lv; }
				else { hx = 1+lu; hy = 1+lv; hz = halo_pos; }
				halo[hx + hy*HS + hz*HS*HS] = mat;
			}
		}
	}
	return halo;
}

// 从独立 LOD 数据块（每 LOD 32³ 大格，值 = 材质ID）构建 34³ halo（直接拷大格，无降采样）：
// 中心 32³ = block 自身；6 外缘面 = 相邻 block 边界 1 大格层（跨界可见性）。
// 对应 GDScript VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers（Voxel Tools 式独立数据层网格入口）。
PackedInt32Array VoxelNative::build_lod_block_halo_from_lod_buffers_native(const Dictionary &buffers, const Vector3i &block_key) {
	constexpr int BS = 32;       // 大块大格边长
	constexpr int HS = BS + 2;   // halo 边长
	constexpr int G3 = BS * BS * BS;
	constexpr int SLICE = BS * BS;
	PackedInt32Array halo;
	halo.resize(HS * HS * HS);
	// 中心 32³ = block 自身大格
	if (buffers.has(block_key)) {
		const PackedInt32Array self_buf = buffers[block_key];
		if (self_buf.size() >= G3) {
			const int32_t *b = self_buf.ptr();
			for (int lz = 0; lz < BS; ++lz) {
				for (int ly = 0; ly < BS; ++ly) {
					for (int lx = 0; lx < BS; ++lx) {
						halo[(1+lx) + (1+ly)*HS + (1+lz)*HS*HS] = b[lx + ly*BS + lz*SLICE];
					}
				}
			}
		}
	}
	// 6 外缘面：相邻 block 边界 1 大格层（直接拷邻居大格，无降采样）
	const Vector3i dirs[6] = {
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1),
	};
	for (int di = 0; di < 6; ++di) {
		const Vector3i d = dirs[di];
		const Vector3i nbk = block_key + d;
		const int face = (d.x != 0) ? 0 : ((d.y != 0) ? 1 : 2);
		const int side = (d[face] > 0) ? 1 : 0;
		const int fix = (side == 1) ? 0 : (BS - 1);
		const int halo_pos = (d[face] < 0) ? 0 : (HS - 1);
		PackedInt32Array nb;
		bool has_nb = false;
		if (buffers.has(nbk)) {
			nb = buffers[nbk];
			has_nb = nb.size() >= G3;
		}
		const int32_t *nb_ptr = has_nb ? nb.ptr() : nullptr;
		for (int lv = 0; lv < BS; ++lv) {
			for (int lu = 0; lu < BS; ++lu) {
				int mat = 0;
				if (has_nb) {
					int ni = 0;
					if (face == 0) ni = fix + lu*BS + lv*SLICE;
					else if (face == 1) ni = lu + fix*BS + lv*SLICE;
					else ni = lu + lv*BS + fix*SLICE;
					mat = nb_ptr[ni];
				}
				int hx, hy, hz;
				if (face == 0) { hx = halo_pos; hy = 1+lu; hz = 1+lv; }
				else if (face == 1) { hx = 1+lu; hy = halo_pos; hz = 1+lv; }
				else { hx = 1+lu; hy = 1+lv; hz = halo_pos; }
				halo[hx + hy*HS + hz*HS*HS] = mat;
			}
		}
	}
	return halo;
}

// ----------------------------------------------------------------------------
// 支撑图失稳检测（对应 VoxelData.find_unsupported_around）
// ----------------------------------------------------------------------------

namespace {

constexpr int CHUNK_BITS = 32;  // chunk 边长（体素）

// 体素坐标 -> chunk key（向下取整，正确处理负坐标）
// CHUNK_SIZE=32=2⁵ → 用算术右移替代 std::floor(double/32)，热路径零浮点开销。
// C++ 有符号右移为算术右移（向负无穷），与 std::floor(double(x)/32) 语义一致。
inline Vector3i chunk_of(const Vector3i &pos) {
	return Vector3i(
			pos.x >> 5,
			pos.y >> 5,
			pos.z >> 5);
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

// 6 方向邻居（连通分组 / 批量移除分组共用）
constexpr int NEIGHBORS_6[6][3] = {
	{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
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

Dictionary VoxelNative::remove_voxels_bulk(const Dictionary &buffers, const Array &positions) {
	// 批量移除体素：按 chunk 分组，把修改后的 PackedInt32Array 放回结果，供 GDScript 覆盖。
	// 大崩塌（每帧 4096+ 体素）时替代 GDScript 逐体素循环，主线程提速。
	Dictionary result;
	Dictionary modified_buffers;
	Dictionary chunk_removed;
	Dictionary boundary;  // ck(Vector3i) -> 位掩码（bit0=+x,1=-x,2=+y,3=-y,4=+z,5=-z），供 GDScript 标记脏 chunk + 边界邻居
	int removed = 0;
	if (positions.is_empty()) {
		result["removed"] = 0;
		result["chunk_removed"] = chunk_removed;
		result["buffers"] = modified_buffers;
		result["boundary"] = boundary;
		return result;
	}
	// 按 chunk 分组（local_index）+ 计算每 chunk 边界触及掩码
	std::map<Vector3i, std::vector<int>> by_chunk;
	std::map<Vector3i, int> bm;
	for (int i = 0; i < positions.size(); ++i) {
		const Vector3i p = positions[i];
		const Vector3i ck = chunk_of(p);
		const Vector3i local = p - ck * CHUNK_BITS;
		const int idx = local.x + local.y * CHUNK_BITS + local.z * CHUNK_BITS * CHUNK_BITS;
		by_chunk[ck].push_back(idx);
		int b = 0;
		if (local.x == 0) { b |= 2; } else if (local.x == CHUNK_BITS - 1) { b |= 1; }
		if (local.y == 0) { b |= 8; } else if (local.y == CHUNK_BITS - 1) { b |= 4; }
		if (local.z == 0) { b |= 32; } else if (local.z == CHUNK_BITS - 1) { b |= 16; }
		bm[ck] |= b;
	}
	for (auto &kv : by_chunk) {
		const Vector3i ck = kv.first;
		if (!buffers.has(ck)) {
			continue;
		}
		PackedInt32Array buf = buffers[ck];
		if (buf.size() < CHUNK_BITS * CHUNK_BITS * CHUNK_BITS) {
			continue;
		}
		int32_t *ptr = buf.ptrw();
		int cnt = 0;
		for (int idx : kv.second) {
			if (ptr[idx] > 0) {
				ptr[idx] = 0;
				cnt += 1;
			}
		}
		if (cnt > 0) {
			modified_buffers[ck] = buf;
			chunk_removed[ck] = cnt;
			removed += cnt;
		}
	}
	for (auto &kv : bm) {
		boundary[kv.first] = kv.second;
	}
	result["removed"] = removed;
	result["chunk_removed"] = chunk_removed;
	result["buffers"] = modified_buffers;
	result["boundary"] = boundary;
	return result;
}

Dictionary VoxelNative::set_voxels_bulk(const Dictionary &buffers, const Array &positions, int material_id) {
	// 批量设置体素为同一材质（对称 remove_voxels_bulk）：按 chunk 分组直接改 PackedInt32Array。
	// 旧值 0（空）→ material_id 计入新增数；旧值非 0 → 原地替换不增计数。
	// 大体积批量写入（水模拟/世界构建）替代 GDScript 逐体素字典写，主线程提速。
	Dictionary result;
	Dictionary modified_buffers;
	Dictionary chunk_set;
	Dictionary boundary;
	int added = 0;
	if (positions.is_empty() || material_id <= 0) {
		result["added"] = 0;
		result["chunk_set"] = chunk_set;
		result["buffers"] = modified_buffers;
		result["boundary"] = boundary;
		return result;
	}
	// 按 chunk 分组（local_index）+ 计算每 chunk 边界触及掩码。
	// 用 unordered_map<uint64_t>（vkey 打包）替代 std::map<Vector3i>：超大批量（数百万
	// positions）下 map 平衡树插入 O(N log C) 是主瓶颈，哈希表摊还 O(N)。
	std::unordered_map<uint64_t, std::vector<int>> by_chunk;
	std::unordered_map<uint64_t, Vector3i> ck_of_key;  // 完整 ck 保留（vkey 打包有损，不可解码回负坐标）
	std::unordered_map<uint64_t, int> bm;
	by_chunk.reserve(positions.size() / 8);
	for (int i = 0; i < positions.size(); ++i) {
		const Vector3i p = positions[i];
		const Vector3i ck = chunk_of(p);
		const uint64_t kk = vkey(ck);
		const Vector3i local = p - ck * CHUNK_BITS;
		const int idx = local.x + local.y * CHUNK_BITS + local.z * CHUNK_BITS * CHUNK_BITS;
		auto it = by_chunk.find(kk);
		if (it == by_chunk.end()) {
			it = by_chunk.emplace(kk, std::vector<int>()).first;
		}
		it->second.push_back(idx);
		ck_of_key[kk] = ck;
		int b = 0;
		if (local.x == 0) { b |= 2; } else if (local.x == CHUNK_BITS - 1) { b |= 1; }
		if (local.y == 0) { b |= 8; } else if (local.y == CHUNK_BITS - 1) { b |= 4; }
		if (local.z == 0) { b |= 32; } else if (local.z == CHUNK_BITS - 1) { b |= 16; }
		bm[kk] |= b;
	}
	for (auto &kv : by_chunk) {
		const Vector3i ck = ck_of_key[kv.first];
		PackedInt32Array buf;
		if (buffers.has(ck)) {
			buf = buffers[ck];
		} else {
			// 目标 chunk 不在内存（全新/未加载）：创建全 0 空 buffer 就地写入。
			// 注意：流式下磁盘已有数据的 chunk 需由 GDScript 先 preload（collect_chunks），
			// 否则此处建空 buffer 会覆盖磁盘旧数据。
			buf = PackedInt32Array();
			buf.resize(CHUNK_BITS * CHUNK_BITS * CHUNK_BITS);
		}
		if (buf.size() < CHUNK_BITS * CHUNK_BITS * CHUNK_BITS) {
			continue;
		}
		int32_t *ptr = buf.ptrw();
		int cnt = 0;
		bool changed = false;
		for (int idx : kv.second) {
			if (ptr[idx] <= 0) {
				cnt += 1;
			}
			if (ptr[idx] != material_id) {
				ptr[idx] = material_id;
				changed = true;
			}
		}
		if (changed) {
			modified_buffers[ck] = buf;
			chunk_set[ck] = cnt;  // 纯替换（旧值非 0）时 cnt=0，GDScript 仅覆盖 buffer、计数不变
			added += cnt;
			auto it = bm.find(kv.first);
			if (it != bm.end()) {
				boundary[ck] = it->second;
			}
		}
	}
	result["added"] = added;
	result["chunk_set"] = chunk_set;
	result["buffers"] = modified_buffers;
	result["boundary"] = boundary;
	return result;
}

Array VoxelNative::collect_chunks(const Array &positions) {
	// 收集 positions 涉及的 chunk key（去重）。供流式模式 preload：避免 GDScript
	// 逐体素计算 chunk 的主线程字典开销——遍历在原生，GDScript 只拿到去重后的 chunk 列表。
	Array result;
	std::map<Vector3i, int> seen;
	for (int i = 0; i < positions.size(); ++i) {
		const Vector3i ck = chunk_of(positions[i]);
		if (!seen.count(ck)) {
			seen[ck] = 1;
			result.append(ck);
		}
	}
	return result;
}

Array VoxelNative::partition_connected(const Array &positions) {
	// 连通分组：positions 按 6 方向连通性分组（与 VoxelData.partition_connected 一致）。
	// 只依据 positions 集合内连通（不查世界体素），供大崩塌掉落体分组使用。
	// BFS 阶段用 std::vector 收集（避免逐体素跨语言 Array.append），最后一次性构建。
	Array result;
	if (positions.is_empty()) {
		return result;
	}
	std::unordered_set<uint64_t> all;
	for (int i = 0; i < positions.size(); ++i) {
		all.insert(vkey(positions[i]));
	}
	std::unordered_set<uint64_t> visited;
	std::vector<Vector3i> stack;
	std::vector<std::vector<Vector3i>> groups;
	for (int i = 0; i < positions.size(); ++i) {
		const Vector3i seed = positions[i];
		const uint64_t skey = vkey(seed);
		if (visited.count(skey)) {
			continue;
		}
		std::vector<Vector3i> group;
		stack.clear();
		stack.push_back(seed);
		visited.insert(skey);
		while (!stack.empty()) {
			const Vector3i cur = stack.back();
			stack.pop_back();
			group.push_back(cur);
			for (int d = 0; d < 6; ++d) {
				const Vector3i nb(cur.x + NEIGHBORS_6[d][0], cur.y + NEIGHBORS_6[d][1], cur.z + NEIGHBORS_6[d][2]);
				const uint64_t nk = vkey(nb);
				if (all.count(nk) && !visited.count(nk)) {
					visited.insert(nk);
					stack.push_back(nb);
				}
			}
		}
		groups.push_back(group);
	}
	for (auto &g : groups) {
		Array group_arr;
		for (auto &p : g) {
			group_arr.append(p);
		}
		result.append(group_arr);
	}
	return result;
}

Dictionary VoxelNative::snapshot_chunks_halo(const Dictionary &buffers, const Array &chunks) {
	// 快照受影响区域（chunks + 27 邻居）。用 COW 共享而非逐 buffer duplicate：
	// PackedInt32Array 是原子引用计数，worker 只读 const（ptr），主线程后续写 buffers
	// 时触发写时拷贝 → 省去 758 次 64KB 深拷贝（大场景快照主线程提速）。
	Dictionary needed;
	for (int i = 0; i < chunks.size(); ++i) {
		const Vector3i ck = chunks[i];
		for (int nz = -1; nz <= 1; ++nz) {
			for (int ny = -1; ny <= 1; ++ny) {
				for (int nx = -1; nx <= 1; ++nx) {
					const Vector3i nck(ck.x + nx, ck.y + ny, ck.z + nz);
					if (!needed.has(nck) && buffers.has(nck)) {
						needed[nck] = buffers[nck];
					}
				}
			}
		}
	}
	return needed;
}

void VoxelNative::_bind_methods() {
	ClassDB::bind_static_method("VoxelNative", D_METHOD("greedy_merge_dense", "grid", "width", "height"), &VoxelNative::greedy_merge_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_chunk_dense", "halo", "trans_flags", "scale", "chunk", "use_local_space", "offset"), &VoxelNative::generate_chunk_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_lod1_block_dense", "halo", "trans_flags", "scale", "block_key", "offset"), &VoxelNative::generate_lod1_block_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_halo_from_buffers", "buffers", "chunk"), &VoxelNative::build_halo_from_buffers);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_halo_from_voxels", "voxels", "chunk"), &VoxelNative::build_halo_from_voxels);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_arrays_native", "voxels", "trans_flags", "scale", "offset"), &VoxelNative::generate_arrays_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_lod1_block_halo_from_buffers", "buffers", "block_key"), &VoxelNative::build_lod1_block_halo_from_buffers);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_lod_block_halo_from_buffers_native", "buffers", "block_key", "lod_shift"), &VoxelNative::build_lod_block_halo_from_buffers_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_lod_block_halo_from_lod_buffers_native", "buffers", "block_key"), &VoxelNative::build_lod_block_halo_from_lod_buffers_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("find_unsupported_around", "buffers", "removed"), &VoxelNative::find_unsupported_around);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("remove_voxels_bulk", "buffers", "positions"), &VoxelNative::remove_voxels_bulk);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("set_voxels_bulk", "buffers", "positions", "material_id"), &VoxelNative::set_voxels_bulk);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_chunks", "positions"), &VoxelNative::collect_chunks);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("partition_connected", "positions"), &VoxelNative::partition_connected);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("snapshot_chunks_halo", "buffers", "chunks"), &VoxelNative::snapshot_chunks_halo);
}
