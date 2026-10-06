#include "voxel_native.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <array>
#include <cmath>
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

// 网格整数坐标 → 64 位哈希键（用于 chunk 去重 / 材质映射等，
// 21 位/分量，覆盖 ±100 万范围）。
//
// 【坑】旧实现只对 z 做 `& 0x1FFFFF`，x / y 直接 `uint32_t(x) << 42` / `<< 21`：
//   - x 占 bit42..63，但 uint32 左移 42 只保留低 22 位（高 10 位被丢弃）；
//   - y 占 bit21..52，与 x 的区域在 bit42..52 **重叠 11 位**，`|` 会互相污染；
//   结果：负坐标（二补数高位全 1）极易撞键。实测 chunk 坐标 x∈[-1000,1000] 时，
//   相邻 chunk (-1000,-3,-3) 与 (-999,-3,-3) 等 41979 组直接碰撞 →
//   chunks / mat_map / chunk_bufs 互相覆盖，表现为"chunk 网格错乱、材质串味"。
//   （另一类偶发：x≥2^22 时高位被截断，vkey(0,0,0)==vkey(2^22,0,0)。）
//
// 【修法】三个分量都先 `& 0x1FFFFF` 截到 21 位，再放到互不重叠的位段：
//   x → bit42..62，y → bit21..41，z → bit0..20（共 63 位，最高位不用）。
//   21 位二补数覆盖 [-1048576, 1048575]，对 chunk 坐标（±3 万）绰绰有余，
//   且**同一有符号值总有同一位型**，同一坐标必得同一键、不同坐标在位段内必不同。
inline uint64_t grid_vkey(int x, int y, int z) {
	const uint64_t ux = uint64_t(uint32_t(x) & 0x1FFFFFu);
	const uint64_t uy = uint64_t(uint32_t(y) & 0x1FFFFFu);
	const uint64_t uz = uint64_t(uint32_t(z) & 0x1FFFFFu);
	return (ux << 42) | (uy << 21) | uz;
}
inline uint64_t grid_vkey(const Vector3i &p) { return grid_vkey(p.x, p.y, p.z); }

// 顶点去重键 = (网格角点, 面序号, 材质ID)。
// 【坑】早期实现用 `key = key * 31 + x` 逐级叠加：grid_vkey 已占满 63 位，
// 再乘 31 会**溢出 uint64 并回绕**，把高位信息丢掉 → 不同 (角点,面,材质) 撞成
// 同一键，一个顶点的 UV/法线被另一材质的三角形复用。渲染表现是同一三角形上
// 出现两个不同材质 ID 的 UV（u 在两 texel 间插值）——即"彩虹条纹/同心方格"。
//
// 现改为**精确复合键**（零碰撞）：角点各轴 21 位 + 面 3 位 + 材质 8 位 = 74 位，
// 超过 64 位，故用一个结构体键配 std::map 做精确比较（不用哈希，杜绝碰撞）。
struct VertexKey {
	int32_t x, y, z;
	int32_t face;
	int32_t mat;
	bool operator<(const VertexKey &o) const {
		if (x != o.x) return x < o.x;
		if (y != o.y) return y < o.y;
		if (z != o.z) return z < o.z;
		if (face != o.face) return face < o.face;
		return mat < o.mat;
	}
};

// 6 方向邻居偏移（面顺序权威定义：+Y, -Y, -X, +X, +Z, -Z）
constexpr int HALO_DIRS[6] = {
	HALO_SIZE,               // +Y
	-HALO_SIZE,              // -Y
	-1,                      // -X
	1,                       // +X
	HALO_SIZE * HALO_SIZE,   // +Z
	-HALO_SIZE * HALO_SIZE,  // -Z
};

// 每面轴向信息 {perp(切片轴), u(水平轴), v(垂直轴)}（面顺序同上）
struct FaceAxes { int perp, u, v; };
constexpr FaceAxes FACE_AXES[6] = {
	{1, 0, 2},  // +Y Top    perp=Y u=X v=Z
	{1, 0, 2},  // -Y Bottom
	{0, 1, 2},  // -X Left   perp=X u=Y v=Z
	{0, 1, 2},  // +X Right
	{2, 0, 1},  // +Z Front  perp=Z u=X v=Y
	{2, 0, 1},  // -Z Back
};

// 6 面法线（面顺序同上）
constexpr float NORMALS[6][3] = {
	{0, 1, 0}, {0, -1, 0}, {-1, 0, 0}, {1, 0, 0}, {0, 0, 1}, {0, 0, -1},
};

// 6 面顶点（6 顶点/面 = 2 三角形，顺时针缠绕，Godot 正面）
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
	std::map<VertexKey, int> solid_cache;
	std::map<VertexKey, int> trans_cache;
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
				// 【防空腔 + 防 z-fight】block 边界侧面由一侧负责：
				//   负方向边界（-x/-y/-z，perp_val==0）本块强制生成；
				//   正方向边界（+x/+y/+z，perp_val==size-1）仅 halo 外缘为空（世界边缘）
				//   才生成，否则由坐标更大的相邻块负责其负方向边界。
				// 既避免"接缝处双方都不生成 → 地面块侧面开口空腔（远处平视空洞）"，
				// 又避免"双方都生成 → 重叠面 z-fight（远距条纹闪烁）"。
				const FaceAxes &fax0 = FACE_AXES[face_idx];
				const int perp_val0 = axis_val(x, y, z, fax0.perp);
				const float nperp = NORMALS[face_idx][fax0.perp];
				if (nperp < 0.0f && perp_val0 == 0) {
					visible = true;
				} else if (nperp > 0.0f && perp_val0 == size - 1) {
					visible = (nv <= 0);
				} else if (nv <= 0) {
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
						VertexKey key{ grid_pt.x, grid_pt.y, grid_pt.z, face_idx, mat_id };
						auto it = trans_cache.find(key);
						if (it != trans_cache.end()) {
							trans_idxs.append(it->second);
						} else {
							const int vi = trans_verts.size();
							trans_verts.append(world_pos);
							trans_normals.append(normal);
							trans_uvs.append(Vector2(u_uv, 0.5f));
							trans_idxs.append(vi);
							trans_cache[key] = vi;
						}
					} else {
						VertexKey key{ grid_pt.x, grid_pt.y, grid_pt.z, face_idx, mat_id };
						auto it = solid_cache.find(key);
						if (it != solid_cache.end()) {
							solid_idxs.append(it->second);
						} else {
							const int vi = solid_verts.size();
							solid_verts.append(world_pos);
							solid_normals.append(normal);
							solid_uvs.append(Vector2(u_uv, 0.5f));
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
	// 构建 34³ halo（中心 32³ + 1 外缘）：遍历 27 邻居 chunk 与光环的重叠区，数组下标读取。
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
		// 2. 构建 34³ halo（含邻居，查体素表）
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

namespace {
// 单位 icosphere 模板：正二十面体 → 逐次细分(每三角形拆 4) → 中点投影回单位球面。
// 相比 UV 球：三角形面积均匀、无极点奇点，适合风格化小球渲染。
// 最后把逆时针缠绕翻转为 (a, c, b)：Godot 正面为顺时针，否则球体外壁被背面剔除。
void build_icosphere(int subdivisions, std::vector<Vector3> &out_verts, std::vector<int> &out_indices) {
	const double t = (1.0 + std::sqrt(5.0)) / 2.0;
	std::vector<Vector3> verts = {
		Vector3(-1.0f, float(t), 0.0f), Vector3(1.0f, float(t), 0.0f),
		Vector3(-1.0f, float(-t), 0.0f), Vector3(1.0f, float(-t), 0.0f),
		Vector3(0.0f, -1.0f, float(t)), Vector3(0.0f, 1.0f, float(t)),
		Vector3(0.0f, -1.0f, float(-t)), Vector3(0.0f, 1.0f, float(-t)),
		Vector3(float(t), 0.0f, -1.0f), Vector3(float(t), 0.0f, 1.0f),
		Vector3(float(-t), 0.0f, -1.0f), Vector3(float(-t), 0.0f, 1.0f),
	};
	for (Vector3 &v : verts) {
		v = v.normalized();
	}
	// 20 个面（逆时针，从外部看）
	std::vector<int> indices = {
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	};
	for (int sub = 0; sub < subdivisions; ++sub) {
		std::unordered_map<uint64_t, int> mid_cache;
		std::vector<int> new_indices;
		new_indices.reserve(indices.size() * 4);
		auto edge_mid = [&](int a, int b) -> int {
			const uint64_t key = a < b ? (uint64_t(a) * 4194304ull + uint64_t(b))
					: (uint64_t(b) * 4194304ull + uint64_t(a));
			auto it = mid_cache.find(key);
			if (it != mid_cache.end()) {
				return it->second;
			}
			verts.push_back(((verts[a] + verts[b]) * 0.5f).normalized());
			const int idx = (int)verts.size() - 1;
			mid_cache[key] = idx;
			return idx;
		};
		for (size_t i = 0; i < indices.size(); i += 3) {
			const int a = indices[i];
			const int b = indices[i + 1];
			const int c = indices[i + 2];
			const int ab = edge_mid(a, b);
			const int bc = edge_mid(b, c);
			const int ca = edge_mid(c, a);
			new_indices.push_back(a); new_indices.push_back(ab); new_indices.push_back(ca);
			new_indices.push_back(b); new_indices.push_back(bc); new_indices.push_back(ab);
			new_indices.push_back(c); new_indices.push_back(ca); new_indices.push_back(bc);
			new_indices.push_back(ab); new_indices.push_back(bc); new_indices.push_back(ca);
		}
		indices = new_indices;
	}
	for (size_t i = 0; i < indices.size(); i += 3) {
		const int tmp = indices[i + 1];
		indices[i + 1] = indices[i + 2];
		indices[i + 2] = tmp;
	}
	out_verts = verts;
	out_indices = indices;
}

// 向下取整除法（与 GDScript 整数除法的截断语义对齐）
inline int grid_floor_div(int v, int d) {
	const int q = v / d;
	return q * d > v ? q - 1 : q;
}
} // namespace

// 球体网格（导入 shape=sphere）：每体素一颗 icosphere，按顶点预算自动降采样。
// 语义与旧 GDScript 导入实现一致：
//   - 先用包围盒表面积估算采样间隔 step，再按实际外露格子数兜底放大（step 上限 32）
//   - 只保留至少有一格外露的格子（被实心邻居完全包裹的格子不可见）
//   - 结果按 实体 / 透明 分桶；UV 采样纹素中心 (mat_id+0.5)/256, v=0.5
// 返回 Dictionary：{solid_verts, solid_normals, solid_uvs, solid_idxs,
//                   trans_verts, trans_normals, trans_uvs, trans_idxs, step}
Dictionary VoxelNative::generate_spheres_native(const Dictionary &voxels, const PackedByteArray &trans_flags,
		int subdivisions, float sphere_scale, float scale, int vertex_budget) {
	const uint8_t *tflags = trans_flags.ptr();
	const int n_mats = trans_flags.size();
	const int subs = subdivisions < 0 ? 0 : (subdivisions > 2 ? 2 : subdivisions);
	const double budget = vertex_budget > 0 ? double(vertex_budget) : 1.0;

	// 1. 收集有效体素(>0) 与包围盒
	const Array keys = voxels.keys();
	Vector3i pos_min(0, 0, 0);
	Vector3i pos_max(0, 0, 0);
	bool has_voxel = false;
	for (int i = 0; i < keys.size(); ++i) {
		const Vector3i p = keys[i];
		if (int64_t(voxels[p]) <= 0) {
			continue;
		}
		if (!has_voxel) {
			has_voxel = true;
			pos_min = p;
			pos_max = p;
		} else {
			pos_min.x = std::min(pos_min.x, p.x);
			pos_min.y = std::min(pos_min.y, p.y);
			pos_min.z = std::min(pos_min.z, p.z);
			pos_max.x = std::max(pos_max.x, p.x);
			pos_max.y = std::max(pos_max.y, p.y);
			pos_max.z = std::max(pos_max.z, p.z);
		}
	}

	std::vector<Vector3> unit_verts;
	std::vector<int> unit_indices;
	build_icosphere(subs, unit_verts, unit_indices);
	const int verts_per_sphere = (int)unit_verts.size();

	// 2. 采样间隔 step：先按包围盒表面积估算，避免反复全量扫描
	int step = 1;
	if (has_voxel) {
		const Vector3i dims = pos_max - pos_min + Vector3i(1, 1, 1);
		const double surface_est = 2.0 * (double(dims.x) * dims.y + double(dims.y) * dims.z + double(dims.z) * dims.x);
		const int need = (int)std::ceil(std::sqrt(surface_est * verts_per_sphere / budget));
		while (step < need && step < 32) {
			step *= 2;
		}
	}

	// 3. 降采样为格子（格内取"第一个"非空材质，与 LOD 降采样规则一致）→ 只保留外露格子
	auto select_cells = [&](int st) {
		// 按 keys 原始顺序遍历，保证"第一个非空材质"的取法确定
		std::unordered_map<uint64_t, std::pair<Vector3i, int32_t>> cells;
		for (int i = 0; i < keys.size(); ++i) {
			const Vector3i p = keys[i];
			const int64_t m = int64_t(voxels[p]);
			if (m <= 0) {
				continue;
			}
			const Vector3i ck(grid_floor_div(p.x, st), grid_floor_div(p.y, st), grid_floor_div(p.z, st));
			const uint64_t k = grid_vkey(ck);
			if (cells.find(k) == cells.end()) {
				cells[k] = std::make_pair(ck, (int32_t)m);
			}
		}
		std::unordered_map<uint64_t, std::pair<Vector3i, int32_t>> picked;
		for (auto &kv : cells) {
			const Vector3i &c = kv.second.first;
			const int32_t id = kv.second.second;
			const Vector3i npos[6] = {
				Vector3i(c.x, c.y + 1, c.z), Vector3i(c.x, c.y - 1, c.z),
				Vector3i(c.x - 1, c.y, c.z), Vector3i(c.x + 1, c.y, c.z),
				Vector3i(c.x, c.y, c.z + 1), Vector3i(c.x, c.y, c.z - 1),
			};
			bool keep = false;
			for (int d = 0; d < 6; ++d) {
				auto it = cells.find(grid_vkey(npos[d]));
				if (it == cells.end()) {
					keep = true;
					break;
				}
				const int32_t n_id = it->second.second;
				const bool m_trans = id < n_mats && tflags[id] != 0;
				const bool n_trans = n_id < n_mats && tflags[n_id] != 0;
				if (m_trans != n_trans || (m_trans && id != n_id)) {
					keep = true;
					break;
				}
			}
			if (keep) {
				picked[kv.first] = kv.second;
			}
		}
		return picked;
	};

	auto picked = select_cells(step);
	while ((int)picked.size() * verts_per_sphere > vertex_budget && step < 32) {
		step *= 2;
		picked = select_cells(step);
	}
	if (step > 1) {
		UtilityFunctions::print("voxel sphere: auto step ", step, " (spheres=", (int)picked.size(),
				", budget=", vertex_budget, " verts)");
	}

	// 4. 展开球体：每格子一颗小球，按 实体/透明 分桶
	const float step_f = float(step);
	const float radius = 0.5f * sphere_scale * step_f * scale;
	// 球心落在格子中心：格子覆盖体素 [key*step, key*step+step)，中心 = (key + 0.5) * step
	const Vector3 cell_origin(step_f * 0.5f, step_f * 0.5f, step_f * 0.5f);
	const int nv = verts_per_sphere;
	const int ni = (int)unit_indices.size();

	PackedVector3Array sv, sn, tv, tn;
	PackedVector2Array su, tu;
	PackedInt32Array si, ti;
	auto emit = [&](const std::pair<Vector3i, int32_t> &cell, bool is_trans) {
		PackedVector3Array &vs = is_trans ? tv : sv;
		PackedVector3Array &ns = is_trans ? tn : sn;
		PackedVector2Array &us = is_trans ? tu : su;
		PackedInt32Array &is = is_trans ? ti : si;
		const Vector3 center = (cell_origin + Vector3(cell.first) * step_f) * scale;
		const float u = (float(cell.second) + 0.5f) / 256.0f;
		const int vbase = vs.size();
		for (int k = 0; k < nv; ++k) {
			vs.append(center + unit_verts[k] * radius);
			ns.append(unit_verts[k]);
			us.append(Vector2(u, 0.5f));
		}
		for (int k = 0; k < ni; ++k) {
			is.append(unit_indices[k] + vbase);
		}
	};
	for (auto &kv : picked) {
		const int32_t id = kv.second.second;
		emit(kv.second, id < n_mats && tflags[id] != 0);
	}

	Dictionary result;
	result["solid_verts"] = sv;
	result["solid_normals"] = sn;
	result["solid_uvs"] = su;
	result["solid_idxs"] = si;
	result["trans_verts"] = tv;
	result["trans_normals"] = tn;
	result["trans_uvs"] = tu;
	result["trans_idxs"] = ti;
	result["step"] = step;
	return result;
}

namespace {
// LOD 大格降采样：在 [base, base+cell)³ 内按 (z, y, x) 序取**第一个非空材质**（0 = 空）。
//
// 【为什么抽出来】这条规则原先在四处各手写了一遍 —— LOD halo 的中心 32³、halo 的 6 外缘面、
// patch_lod_block（脏大格增量）、patch_lod_block_from_lod（金字塔逐级上推）。
// 更麻烦的是遍历序并不一致：外缘面那处因为按面重新映射了轴，实际遍历序是 (z,x,y) 与 (y,x,z)，
// 与其余三处的 (z,y,x) 不同 —— 同一个概念的操作有三套"谁先撞上就选谁"的顺序，
// 一格跨多种材质时哪个材质代表这一格就成了偶然。此处统一为 (z,y,x)：既是多数派，
// 也与"逐级上推结果 == 全量降采样结果"这一既定语义一致（见 patch_lod_block_from_lod 注释）。
//
// get_voxel(wx, wy, wz) 由调用方提供：可直接索引 chunk 缓冲（同块内），
// 也可跨块惰性查表（外缘面 / 增量 patch）。
template <typename GetVoxel>
inline int32_t downsample_cell(const GetVoxel &get_voxel, int bx, int by, int bz, int cell) {
	for (int dz = 0; dz < cell; ++dz) {
		for (int dy = 0; dy < cell; ++dy) {
			for (int dx = 0; dx < cell; ++dx) {
				const int32_t m = get_voxel(bx + dx, by + dy, bz + dz);
				if (m > 0) {
					return m;
				}
			}
		}
	}
	return 0;
}
} // namespace

// 通用降采样：从 LOD0 chunk buffers 构建 LOD 大块 34³ halo（任意 lod_shift）。
// lod_shift=1 → cell=2（原 LOD1）；更高层每大格 = 2^lod_shift 体素。
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
				auto getv = [b](int x, int y, int z) -> int32_t {
					return b[x + y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE];
				};
				for (int lz8 = 0; lz8 < sub_per_chunk; ++lz8) {
					for (int ly8 = 0; ly8 < sub_per_chunk; ++ly8) {
						for (int lx8 = 0; lx8 < sub_per_chunk; ++lx8) {
							const int lx = cx * sub_per_chunk + lx8;
							const int ly = cy * sub_per_chunk + ly8;
							const int lz = cz * sub_per_chunk + lz8;
							halo[(1+lx) + (1+ly)*HS + (1+lz)*HS*HS] =
									downsample_cell(getv, lx8 * cell, ly8 * cell, lz8 * cell, cell);
						}
					}
				}
			}
		}
	}
	// 6 外缘面：相邻大块边界 1 大格层（降采样 cell³ 体素）。
	// 采样立方体的固定轴由 fix_grid 决定、面内两轴由 (lu, lv) 决定；
	// 交给 downsample_cell 后，三轴遍历序统一为 (z, y, x)。
	const Vector3i dirs[6] = {
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1),
	};
	// 跨 block/chunk 的体素读取：只有外缘一圈越界，故按需惰性解析 chunk
	auto getv_nb = [&buffers](int wx, int wy, int wz) -> int32_t {
		const Vector3i nck(wx >> CHUNK_SHIFT, wy >> CHUNK_SHIFT, wz >> CHUNK_SHIFT);
		if (!buffers.has(nck)) {
			return 0;
		}
		const PackedInt32Array nbuf = buffers[nck];
		if (nbuf.size() < CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) {
			return 0;
		}
		const int lx = wx - nck.x * CHUNK_SIZE;
		const int ly = wy - nck.y * CHUNK_SIZE;
		const int lz = wz - nck.z * CHUNK_SIZE;
		return nbuf.ptr()[lx + ly * CHUNK_SIZE + lz * CHUNK_SIZE * CHUNK_SIZE];
	};
	for (int di = 0; di < 6; ++di) {
		const Vector3i d = dirs[di];
		const Vector3i nbk = block_key + d;
		const int face = (d.x != 0) ? 0 : ((d.y != 0) ? 1 : 2);
		const int fix_grid = (d[face] > 0) ? 0 : (BS - 1);
		const int halo_pos = (d[face] < 0) ? 0 : (HS - 1);
		for (int lv = 0; lv < BS; ++lv) {
			for (int lu = 0; lu < BS; ++lu) {
				// 采样立方体左下角（世界体素坐标）：固定轴取 fix_grid 那一大格，
				// 面内两轴 face=0(x)→(y,z)、face=1(y)→(x,z)、face=2(z)→(x,y) 分别用 (lu, lv)。
				int bx, by, bz;
				if (face == 0) {
					bx = nbk.x * block_voxels + fix_grid * cell;
					by = nbk.y * block_voxels + lu * cell;
					bz = nbk.z * block_voxels + lv * cell;
				} else if (face == 1) {
					bx = nbk.x * block_voxels + lu * cell;
					by = nbk.y * block_voxels + fix_grid * cell;
					bz = nbk.z * block_voxels + lv * cell;
				} else {
					bx = nbk.x * block_voxels + lu * cell;
					by = nbk.y * block_voxels + lv * cell;
					bz = nbk.z * block_voxels + fix_grid * cell;
				}
				const int mat = downsample_cell(getv_nb, bx, by, bz, cell);
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
//
// 【坑】旧实现只对 z 做 `& 0x1FFFFF`，x / y 未截断：x 左移 42 只保留低 22 位、
//   y 左移 21 占 bit21..52 与 x 的 bit42..63 **重叠 11 位**，`|` 互相污染。
//   负坐标（二补数高位全 1）大面积撞键 → by_chunk / ck_of_key / removed_set
//   等哈希表把不同 chunk/体素当成同一个。修法与 grid_vkey 一致：三分量各截 21 位、
//   放互不重叠位段（x→42..62, y→21..41, z→0..20）。
inline uint64_t vkey(int x, int y, int z) {
	// 每个分量占 21 位（覆盖 ±1M 范围），符号由二补数低 21 位保留
	const uint64_t ux = uint64_t(uint32_t(x) & 0x1FFFFFu);
	const uint64_t uy = uint64_t(uint32_t(y) & 0x1FFFFFu);
	const uint64_t uz = uint64_t(uint32_t(z) & 0x1FFFFFu);
	return (ux << 42) | (uy << 21) | uz;
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

// 应力传播（裂纹扩散）：从 removed 出发，6 邻居 BFS。
// 邻居体素材质 connection_strength < 当前 force → 断裂（加入下一层继续传播）。
// strength_table: PackedFloat32Array（索引=材质ID），由 GDScript 预取，
//   消除原 GDScript 版逐邻居的 has_voxel/get_voxel 字典查询 + as 对象转换（破坏瞬间主线程热点）。
// 复用 find_unsupported_around 的 chunk 惰性加载 + buffer 直读模式（C++ 指针访问，零 GDScript 开销）。
// 返回 Array[Vector3i]（应力断裂的体素位置）。
Array VoxelNative::propagate_stress(const Dictionary &buffers, const Array &removed,
		const PackedFloat32Array &strength_table, int max_steps, float force, float decay) {
	Array result;
	if (buffers.is_empty() || removed.is_empty()) {
		return result;
	}
	// 惰性构建 chunk 缓冲查找结构（只收集传播涉及的 chunk，避免全量拷贝）
	std::unordered_map<uint64_t, PackedInt32Array> chunk_bufs;
	auto ensure_chunk = [&](const Vector3i &p) {
		const uint64_t kk = vkey(chunk_of(p));
		if (chunk_bufs.find(kk) == chunk_bufs.end()) {
			if (buffers.has(chunk_of(p))) {
				chunk_bufs[kk] = buffers[chunk_of(p)];
			}
		}
	};
	// 读体素材质 ID（>0 表示存在），chunk 缓冲直读
	auto get_mat = [&](const Vector3i &p) -> int32_t {
		const Vector3i ck = chunk_of(p);
		const auto it = chunk_bufs.find(vkey(ck));
		if (it == chunk_bufs.end()) {
			return 0;
		}
		const Vector3i local = p - ck * CHUNK_BITS;
		if (local.x < 0 || local.y < 0 || local.z < 0 || local.x >= CHUNK_BITS || local.y >= CHUNK_BITS || local.z >= CHUNK_BITS) {
			return 0;
		}
		return it->second.ptr()[buf_index(local)];
	};
	// removed 集合（时间戳集合作 visited，快速查重）
	std::unordered_set<uint64_t> removed_set;
	std::vector<Vector3i> current_layer;
	for (int i = 0; i < removed.size(); ++i) {
		const Vector3i rp = removed[i];
		removed_set.insert(vkey(rp));
		ensure_chunk(rp);
		current_layer.push_back(rp);
	}
	float current_force = force;
	for (int step = 0; step < max_steps; ++step) {
		if (current_layer.empty()) {
			break;
		}
		current_force *= (1.0f - decay);
		if (current_force <= 0.0f) {
			break;
		}
		std::vector<Vector3i> next_layer;
		for (const Vector3i &p : current_layer) {
			for (int d = 0; d < 6; ++d) {
				const Vector3i nb(p.x + NEIGHBORS_6[d][0], p.y + NEIGHBORS_6[d][1], p.z + NEIGHBORS_6[d][2]);
				const uint64_t nk = vkey(nb);
				if (removed_set.find(nk) != removed_set.end()) {
					continue;
				}
				ensure_chunk(nb);
				const int32_t mat = get_mat(nb);
				if (mat <= 0) {
					continue;
				}
				float strength = 10.0f;
				if (mat < strength_table.size()) {
					strength = strength_table[mat];
				}
				if (current_force > strength) {
					removed_set.insert(nk);
					result.append(nb);
					next_layer.push_back(nb);
				}
			}
		}
		current_layer = std::move(next_layer);
	}
	return result;
}

// 批量收集体素材质 ID（替代 GDScript 逐体素 get_voxel 字典查询，破坏管线热点）。
// 与 GDScript get_voxel 语义一致：有体素 → 材质 ID（>0），无体素 → -1。
// 返回 Dictionary{pos(Vector3i): int}。
Dictionary VoxelNative::collect_materials(const Dictionary &buffers, const Array &positions) {
	Dictionary result;
	if (buffers.is_empty() || positions.is_empty()) {
		return result;
	}
	std::unordered_map<uint64_t, PackedInt32Array> chunk_bufs;
	auto ensure_chunk = [&](const Vector3i &p) {
		const uint64_t kk = vkey(chunk_of(p));
		if (chunk_bufs.find(kk) == chunk_bufs.end()) {
			if (buffers.has(chunk_of(p))) {
				chunk_bufs[kk] = buffers[chunk_of(p)];
			}
		}
	};
	auto get_mat = [&](const Vector3i &p) -> int32_t {
		const Vector3i ck = chunk_of(p);
		const auto it = chunk_bufs.find(vkey(ck));
		if (it == chunk_bufs.end()) {
			return 0;
		}
		const Vector3i local = p - ck * CHUNK_BITS;
		if (local.x < 0 || local.y < 0 || local.z < 0 || local.x >= CHUNK_BITS || local.y >= CHUNK_BITS || local.z >= CHUNK_BITS) {
			return 0;
		}
		return it->second.ptr()[buf_index(local)];
	};
	for (int i = 0; i < positions.size(); ++i) {
		const Vector3i p = positions[i];
		ensure_chunk(p);
		const int32_t m = get_mat(p);
		result[p] = (m > 0) ? m : -1;
	}
	return result;
}

PackedInt32Array VoxelNative::collect_materials_flat(const Dictionary &buffers, const Array &positions) {
	const int n = positions.size();
	PackedInt32Array out;
	out.resize(n);
	if (n == 0) {
		return out;
	}
	int32_t *w = out.ptrw();
	const int volume = CHUNK_BITS * CHUNK_BITS * CHUNK_BITS;
	// 位置通常按 chunk 成组出现：缓存当前 chunk 的缓冲，把逐体素哈希降为逐 chunk 一次
	Vector3i cur_ck;
	bool cur_valid = false;
	PackedInt32Array cur_buf;
	const int32_t *cur_ptr = nullptr;
	for (int i = 0; i < n; ++i) {
		const Vector3i p = positions[i];
		const Vector3i ck = chunk_of(p);
		if (!cur_valid || ck != cur_ck) {
			cur_ck = ck;
			cur_valid = true;
			cur_buf = PackedInt32Array();
			cur_ptr = nullptr;
			if (buffers.has(ck)) {
				cur_buf = buffers[ck];
				if (cur_buf.size() >= volume) {
					cur_ptr = cur_buf.ptr();
				}
			}
		}
		if (cur_ptr == nullptr) {
			w[i] = -1;
			continue;
		}
		const int32_t m = cur_ptr[buf_index(p - ck * CHUNK_BITS)];
		w[i] = (m > 0) ? m : -1;
	}
	return out;
}

Dictionary VoxelNative::apply_damage(const Dictionary &damage_chunks, const Array &positions,
		const PackedInt32Array &materials, const PackedFloat32Array &hardness_table,
		float damage, bool use_health) {
	Dictionary out;
	Array removed;
	Array hardened_pos;
	PackedFloat32Array hardened_rem;
	Dictionary changed;
	const int n = positions.size();
	for (int i = 0; i < n && !use_health; ++i) {
		removed.push_back(positions[i]);
	}
	if (n > 0 && use_health) {
		const int hn = hardness_table.size();
		const int mn = materials.size();
		const int volume = CHUNK_BITS * CHUNK_BITS * CHUNK_BITS;
		const float *hard = hardness_table.ptr();
		const int32_t *mats = materials.ptr();
		// 伤害缓冲按 chunk 惰性取出到本地（ptrw 会分叉，最后统一回填给调用方）
		std::unordered_map<uint64_t, PackedFloat32Array> dmg;
		std::unordered_map<uint64_t, Vector3i> ck_of;
		Vector3i cur_ck;
		bool cur_valid = false;
		float *cur_ptr = nullptr;
		for (int i = 0; i < n; ++i) {
			const Vector3i p = positions[i];
			const Vector3i ck = chunk_of(p);
			if (!cur_valid || ck != cur_ck) {
				cur_ck = ck;
				cur_valid = true;
				const uint64_t kk = vkey(ck);
				auto it = dmg.find(kk);
				if (it == dmg.end()) {
					PackedFloat32Array b;
					if (damage_chunks.has(ck)) {
						b = damage_chunks[ck];
					}
					if (b.size() < volume) {
						b.resize(volume);
					}
					it = dmg.emplace(kk, b).first;
					ck_of[kk] = ck;
				}
				cur_ptr = it->second.ptrw();
			}
			const int32_t mid = (i < mn) ? mats[i] : -1;
			float h = 1.0f;
			if (mid >= 0 && mid < hn) {
				h = hard[mid];
			}
			if (h <= 0.0f) {
				removed.push_back(p);
				continue;
			}
			const int32_t idx = buf_index(p - ck * CHUNK_BITS);
			const float cur = cur_ptr[idx] + damage;
			if (cur >= h) {
				cur_ptr[idx] = 0.0f;   // 移除即清零：该位置日后被重建时不应继承旧伤
				removed.push_back(p);
			} else {
				cur_ptr[idx] = cur;
				hardened_pos.push_back(p);
				hardened_rem.push_back(h - cur);
			}
		}
		for (auto &kv : dmg) {
			changed[ck_of[kv.first]] = kv.second;
		}
	}
	out["removed"] = removed;
	out["hardened_pos"] = hardened_pos;
	out["hardened_rem"] = hardened_rem;
	out["damage_chunks"] = changed;
	return out;
}

Dictionary VoxelNative::install_flat_voxels(const PackedInt32Array &flat) {
	Dictionary out;
	const int n = flat.size();
	if (n < 4) {
		return out;
	}
	const int32_t *p = flat.ptr();
	const int volume = CHUNK_BITS * CHUNK_BITS * CHUNK_BITS;
	std::unordered_map<uint64_t, int> slot_of;
	std::vector<Vector3i> keys;
	std::vector<PackedInt32Array> bufs;
	// 第一趟：登记涉及的 chunk 并分配缓冲
	for (int i = 0; i + 3 < n; i += 4) {
		if (p[i + 3] <= 0) {
			continue;   // 空体素不写入（与 set_voxels 同语义）
		}
		const Vector3i ck = chunk_of(Vector3i(p[i], p[i + 1], p[i + 2]));
		const uint64_t kk = vkey(ck);
		if (slot_of.find(kk) == slot_of.end()) {
			slot_of.emplace(kk, (int)bufs.size());
			keys.push_back(ck);
			bufs.push_back(PackedInt32Array());
			bufs.back().resize(volume);
		}
	}
	// 第二趟：缓存每 chunk 的写入指针（避免逐体素取 ptrw），一次填满
	std::vector<int32_t *> ptrs(bufs.size());
	for (size_t s = 0; s < bufs.size(); ++s) {
		ptrs[s] = bufs[s].ptrw();
	}
	for (int i = 0; i + 3 < n; i += 4) {
		const int32_t mat = p[i + 3];
		if (mat <= 0) {
			continue;
		}
		const Vector3i pos(p[i], p[i + 1], p[i + 2]);
		const Vector3i ck = chunk_of(pos);
		ptrs[slot_of[vkey(ck)]][buf_index(pos - ck * CHUNK_BITS)] = mat;
	}
	for (size_t s = 0; s < bufs.size(); ++s) {
		out[keys[s]] = bufs[s];
	}
	return out;
}

// 金字塔增量降采样：只重算 block 内 [rmin, rmax] 区域的脏大格，未脏大格从 coarse 复用。
// 与全量 build_lod_block_halo_from_buffers_native 降采样规则一致（大格值 = 覆盖 cell³ 体素中
// 第一个非空材质），保证增量/全量结果一致。编辑体素后只影响少数大格 → 破坏成本 O(脏大格)。
// coarse: 现有 block 大格数据（PackedInt32Array 32³，未脏大格保留）；为空则先建空 buffer。
// buffers: LOD0 chunk 缓冲（chunk key -> PackedInt32Array 32³）。
// 返回完整 block 大格数据（脏大格已更新，未脏大格保持 coarse 旧值）。
PackedInt32Array VoxelNative::patch_lod_block(const Dictionary &buffers, const Vector3i &block_key,
		int lod_shift, const PackedInt32Array &coarse,
		const Vector3i &rmin, const Vector3i &rmax) {
	constexpr int BS = 32;
	const int cell = 1 << lod_shift;
	const int block_voxels = BS * cell;
	PackedInt32Array buf = coarse;
	if (buf.size() < BS * BS * BS) {
		buf.resize(BS * BS * BS);
	}
	// 惰性 chunk 缓冲（只读脏大格涉及的 chunk，避免全量读取）
	std::unordered_map<uint64_t, PackedInt32Array> chunk_bufs;
	auto get_voxel = [&](int wx, int wy, int wz) -> int32_t {
		const Vector3i p(wx, wy, wz);
		const Vector3i ck = chunk_of(p);
		const uint64_t kk = vkey(ck);
		auto it = chunk_bufs.find(kk);
		if (it == chunk_bufs.end()) {
			if (buffers.has(ck)) {
				chunk_bufs[kk] = buffers[ck];
				it = chunk_bufs.find(kk);
			} else {
				return 0;
			}
		}
		const Vector3i local = p - ck * CHUNK_BITS;
		if (local.x < 0 || local.y < 0 || local.z < 0 || local.x >= CHUNK_BITS || local.y >= CHUNK_BITS || local.z >= CHUNK_BITS) {
			return 0;
		}
		return it->second.ptr()[buf_index(local)];
	};
	// 只对脏大格降采样（规则见 downsample_cell，与全量一致）
	for (int gz = rmax.z; gz >= rmin.z; --gz) {
		const int bz = block_key.z * block_voxels + gz * cell;
		for (int gy = rmax.y; gy >= rmin.y; --gy) {
			const int by = block_key.y * block_voxels + gy * cell;
			for (int gx = rmax.x; gx >= rmin.x; --gx) {
				const int bx = block_key.x * block_voxels + gx * cell;
				buf[gx + gy * BS + gz * BS * BS] = downsample_cell(get_voxel, bx, by, bz, cell);
			}
		}
	}
	return buf;
}

// 金字塔逐级上推：当前层（lod>=2）从上一层 coarse 数据降采样（而非从 L0 全量）。
// 当前层 block 覆盖 (32<<lod)³ 体素；上一层 block 覆盖 (32<<(lod-1))³ = 8 个（2³）。
// 当前大格 (gx,gy,gz) 覆盖 2³ 个上一层大格：上一层大格坐标 = (block*32+g)*2 + (dx,dy,dz)。
// 降采样规则复用 downsample_cell（(z,y,x) 序取第一个非空），与全量 L0 降采样一致，
// 故"逐级上推"与"从 L0 全量重算"得到相同结果。
// coarse_buffers: 上一层 block → PackedInt32Array(32³ 大格) 字典。
// coarse: 当前 block 现有大格数据（未脏大格保留）。返回完整当前 block 大格数据。
PackedInt32Array VoxelNative::patch_lod_block_from_lod(const Dictionary &coarse_buffers,
		const Vector3i &block_key, int lod, const PackedInt32Array &coarse,
		const Vector3i &rmin, const Vector3i &rmax) {
	constexpr int BS = 32;
	PackedInt32Array buf = coarse;
	if (buf.size() < BS * BS * BS) {
		buf.resize(BS * BS * BS);
	}
	// 惰性读上一层 coarse（block → 32³ 大格）
	std::unordered_map<uint64_t, PackedInt32Array> coarse_map;
	auto get_prev = [&](int wx, int wy, int wz) -> int32_t {
		const Vector3i p(wx, wy, wz);
		const Vector3i pbk(p.x >> 5, p.y >> 5, p.z >> 5);
		const uint64_t kk = vkey(pbk);
		auto it = coarse_map.find(kk);
		if (it == coarse_map.end()) {
			if (coarse_buffers.has(pbk)) {
				coarse_map[kk] = coarse_buffers[pbk];
				it = coarse_map.find(kk);
			} else {
				return 0;
			}
		}
		const Vector3i local = p - pbk * BS;
		if (local.x < 0 || local.y < 0 || local.z < 0 || local.x >= BS || local.y >= BS || local.z >= BS) {
			return 0;
		}
		return it->second.ptr()[local.x + local.y * BS + local.z * BS * BS];
	};
	for (int gz = rmax.z; gz >= rmin.z; --gz) {
		const int pz = (block_key.z * BS + gz) * 2;
		for (int gy = rmax.y; gy >= rmin.y; --gy) {
			const int py = (block_key.y * BS + gy) * 2;
			for (int gx = rmax.x; gx >= rmin.x; --gx) {
				const int px = (block_key.x * BS + gx) * 2;
				buf[gx + gy * BS + gz * BS * BS] = downsample_cell(get_prev, px, py, pz, 2);
			}
		}
	}
	return buf;
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

// ----------------------------------------------------------------------------
// QVox 文件写入：CRC32（标准 IEEE 802.3，反射多项式 0xEDB88320）
// ----------------------------------------------------------------------------
//
// 与 zlib 口径一致：初值 0xFFFFFFFF，终值异或 0xFFFFFFFF。
// GDScript 逐字节查表算 1.4MB 要 ~84ms；同一算法在 C++ 下 ~0.5ms（约 170x），
// 故 GDScript 侧不再保留兜底实现，QVox 读写校验与子块索引统一调这里。
// 表用函数内 static const 惰性构造一次，线程安全（C++11 magic static）。

static const uint32_t *qvox_crc32_table() {
	static uint32_t table[256];
	static bool built = false;
	if (!built) {
		for (uint32_t i = 0; i < 256; ++i) {
			uint32_t c = i;
			for (int j = 0; j < 8; ++j) {
				c = (c & 1u) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
			}
			table[i] = c;
		}
		built = true;
	}
	return table;
}

// 对一段连续字节算 CRC32；start/length 可传 -1（start<0 → 0；length<0 → 到末尾）
static uint32_t qvox_crc32_run(const uint8_t *p, int64_t n) {
	const uint32_t *table = qvox_crc32_table();
	uint32_t crc = 0xFFFFFFFFu;
	for (int64_t i = 0; i < n; ++i) {
		crc = (crc >> 8) ^ table[(crc ^ p[i]) & 0xFFu];
	}
	return crc ^ 0xFFFFFFFFu;
}

int64_t VoxelNative::crc32(const PackedByteArray &p_data, int64_t p_start, int64_t p_length) {
	const int64_t total = p_data.size();
	int64_t start = p_start < 0 ? 0 : p_start;
	if (start > total) {
		start = total;
	}
	int64_t length;
	if (p_length < 0) {
		length = total - start;
	} else {
		length = p_length;
		if (start + length > total) {
			length = total - start;
		}
	}
	if (length <= 0) {
		// 空区间：标准 CRC32 的空输入值（初值异或终值）
		return (int64_t)0u;
	}
	return (int64_t)qvox_crc32_run(p_data.ptr() + start, length);
}

int64_t VoxelNative::crc32_segments(const PackedByteArray &p_data, const PackedInt64Array &p_offsets, const PackedInt64Array &p_lengths) {
	const int64_t total = p_data.size();
	const int64_t nseg = p_offsets.size() < p_lengths.size() ? p_offsets.size() : p_lengths.size();
	const uint32_t *table = qvox_crc32_table();
	uint32_t crc = 0xFFFFFFFFu;
	for (int64_t s = 0; s < nseg; ++s) {
		int64_t start = p_offsets[s];
		int64_t length = p_lengths[s];
		if (start < 0) {
			start = 0;
		}
		if (start > total) {
			start = total;
		}
		if (length < 0) {
			length = total - start;
		} else if (start + length > total) {
			length = total - start;
		}
		const uint8_t *p = p_data.ptr() + start;
		for (int64_t i = 0; i < length; ++i) {
			crc = (crc >> 8) ^ table[(crc ^ p[i]) & 0xFFu];
		}
	}
	return (int64_t)(crc ^ 0xFFFFFFFFu);
}

// ----------------------------------------------------------------------------
// QVox 块级编解码（原生）
// ----------------------------------------------------------------------------
// 字节布局权威在 QVoxSpec / docs/QVOX_FORMAT.md；这里只做实现，且与 GDScript 参考实现
// （QVoxBlockCodec 的 unpack 仍是 GDScript，由 test_qvox_format 的往返用例做 oracle）逐字节一致。
//   块内线性顺序 idx = x + y·B + z·B²（X 最快）；数值一律小端。

namespace {

constexpr int QVOX_CHANNEL_BYTES = 2;
constexpr int QVOX_CODEC_EMPTY = 0;
constexpr int QVOX_CODEC_SOLID = 1;
constexpr int QVOX_CODEC_RUN = 2;
constexpr int QVOX_CODEC_DENSE = 3;
constexpr int QVOX_CODEC_INDEXED = 4;
constexpr int QVOX_U8_MAX = 255;

// LEB128 长度
inline int qvox_varint_size(int64_t v) {
	int s = 1;
	while (v >= 0x80) {
		v >>= 7;
		++s;
	}
	return s;
}

// 表示 value 需要的最少位数（value ≥ 1；value=1 用 1 位）
inline int qvox_bits_for(int value) {
	int bits = 0;
	int v = value - 1;
	while (v > 0) {
		++bits;
		v >>= 1;
	}
	return bits < 1 ? 1 : bits;
}

PackedByteArray qvox_pack_solid(const int32_t *p, int n) {
	PackedByteArray out;
	out.resize(QVOX_CHANNEL_BYTES);
	uint8_t *w = out.ptrw();
	const int32_t v = n > 0 ? p[0] : 0;
	w[0] = (uint8_t)(v & 0xFF);
	w[1] = (uint8_t)((v >> 8) & 0xFF);
	return out;
}

PackedByteArray qvox_pack_run(const int32_t *p, int n) {
	// uint32 count + count×(varint 游程长度, uint16 值)
	std::vector<uint8_t> body;
	body.reserve((size_t)n + 16);
	uint32_t count = 0;
	int i = 0;
	while (i < n) {
		const int32_t v = p[i];
		int run = 1;
		while (i + run < n && p[i + run] == v) {
			++run;
		}
		uint64_t lv = (uint64_t)run;
		for (;;) {
			const uint8_t b = (uint8_t)(lv & 0x7F);
			lv >>= 7;
			if (lv != 0) {
				body.push_back((uint8_t)(b | 0x80));
			} else {
				body.push_back(b);
				break;
			}
		}
		body.push_back((uint8_t)(v & 0xFF));
		body.push_back((uint8_t)((v >> 8) & 0xFF));
		++count;
		i += run;
	}
	PackedByteArray out;
	out.resize(4 + (int64_t)body.size());
	uint8_t *w = out.ptrw();
	w[0] = (uint8_t)(count & 0xFF);
	w[1] = (uint8_t)((count >> 8) & 0xFF);
	w[2] = (uint8_t)((count >> 16) & 0xFF);
	w[3] = (uint8_t)((count >> 24) & 0xFF);
	for (size_t k = 0; k < body.size(); ++k) {
		w[4 + k] = body[k];
	}
	return out;
}

PackedByteArray qvox_pack_dense(const int32_t *p, int n) {
	PackedByteArray out;
	out.resize((int64_t)n * QVOX_CHANNEL_BYTES);
	uint8_t *w = out.ptrw();
	for (int i = 0; i < n; ++i) {
		w[2 * i] = (uint8_t)(p[i] & 0xFF);
		w[2 * i + 1] = (uint8_t)((p[i] >> 8) & 0xFF);
	}
	return out;
}

PackedByteArray qvox_pack_indexed(const int32_t *p, int n) {
	// 值表按"首次出现顺序"（与 GDScript 版一致，保证常见块逐字节相同）
	std::vector<int32_t> table;
	std::unordered_map<int32_t, int> index_of;
	table.reserve(256);
	index_of.reserve(1024);
	for (int i = 0; i < n; ++i) {
		const int32_t v = p[i];
		if (index_of.find(v) == index_of.end()) {
			index_of.emplace(v, (int)table.size());
			table.push_back(v);
		}
	}
	const int bits = qvox_bits_for((int)table.size());
	const int64_t table_bytes = 1 + (int64_t)table.size() * QVOX_CHANNEL_BYTES;
	const int64_t bit_bytes = ((int64_t)n * bits + 7) >> 3;
	PackedByteArray out;
	out.resize(table_bytes + bit_bytes);
	uint8_t *w = out.ptrw();
	w[0] = (uint8_t)(table.size() & 0xFF);
	for (size_t k = 0; k < table.size(); ++k) {
		w[1 + 2 * k] = (uint8_t)(table[k] & 0xFF);
		w[1 + 2 * k + 1] = (uint8_t)((table[k] >> 8) & 0xFF);
	}
	for (int64_t k = table_bytes; k < out.size(); ++k) {
		w[k] = 0;
	}
	int64_t bit_pos = 0;
	for (int i = 0; i < n; ++i) {
		const int code = index_of[p[i]];
		for (int b = 0; b < bits; ++b) {
			if ((code >> b) & 1) {
				w[table_bytes + (bit_pos >> 3)] |= (uint8_t)(1 << (bit_pos & 7));
			}
			++bit_pos;
		}
	}
	return out;
}

PackedByteArray qvox_pack_any(int codec, const int32_t *p, int n) {
	switch (codec) {
		case QVOX_CODEC_SOLID:
			return qvox_pack_solid(p, n);
		case QVOX_CODEC_RUN:
			return qvox_pack_run(p, n);
		case QVOX_CODEC_DENSE:
			return qvox_pack_dense(p, n);
		case QVOX_CODEC_INDEXED:
			return qvox_pack_indexed(p, n);
		default:
			return PackedByteArray();
	}
}

// 遍历所有 chunk 的非空体素，回调 fn(world_pos, material)
template <typename F>
void qvox_for_each_voxel(const Dictionary &buffers, F &&fn) {
	const Array keys = buffers.keys();
	const int32_t volume = CHUNK_BITS * CHUNK_BITS * CHUNK_BITS;
	for (int ki = 0; ki < keys.size(); ++ki) {
		const Vector3i ck = keys[ki];
		const PackedInt32Array buf = buffers[ck];
		if (buf.size() < volume) {
			continue;
		}
		const int32_t *p = buf.ptr();
		const Vector3i origin = ck * CHUNK_BITS;
		for (int32_t i = 0; i < volume; ++i) {
			const int32_t v = p[i];
			if (v > 0) {
				fn(origin + Vector3i(i % CHUNK_BITS, (i / CHUNK_BITS) % CHUNK_BITS, i / (CHUNK_BITS * CHUNK_BITS)), v);
			}
		}
	}
}

} // namespace

PackedByteArray VoxelNative::pack_with_codec(int codec, const PackedInt32Array &buf, int n) {
	if (n > buf.size()) {
		n = buf.size();
	}
	if (n <= 0 || codec == QVOX_CODEC_EMPTY) {
		return PackedByteArray();
	}
	return qvox_pack_any(codec, buf.ptr(), n);
}

Vector2i VoxelNative::voxel_value_range(const PackedInt32Array &buf) {
	const int n = buf.size();
	if (n <= 0) {
		return Vector2i(0, 0);
	}
	const int32_t *p = buf.ptr();
	int32_t mn = p[0];
	int32_t mx = p[0];
	for (int i = 1; i < n; ++i) {
		const int32_t v = p[i];
		if (v < mn) {
			mn = v;
		} else if (v > mx) {
			mx = v;
		}
	}
	return Vector2i(mn, mx);
}

PackedInt32Array VoxelNative::unpack_block(int codec, const PackedByteArray &payload, int n) {
	PackedInt32Array out;
	if (n <= 0) {
		return out;
	}
	const uint8_t *p = payload.ptr();
	const int64_t total = payload.size();
	switch (codec) {
		case QVOX_CODEC_SOLID: {
			if (total < QVOX_CHANNEL_BYTES) {
				return PackedInt32Array();
			}
			const int32_t v = (int32_t)(p[0] | (p[1] << 8));
			out.resize(n);
			int32_t *w = out.ptrw();
			for (int i = 0; i < n; ++i) {
				w[i] = v;
			}
			return out;
		}
		case QVOX_CODEC_RUN: {
			if (total < 4) {
				return PackedInt32Array();
			}
			const uint32_t count = (uint32_t)p[0] | ((uint32_t)p[1] << 8)
					| ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
			out.resize(n);
			int32_t *w = out.ptrw();
			int64_t pos = 4;
			int64_t idx = 0;
			for (uint32_t k = 0; k < count; ++k) {
				uint64_t run_len = 0;
				int shift = 0;
				bool ok = false;
				while (pos < total) {
					const uint8_t b = p[pos++];
					run_len |= (uint64_t)(b & 0x7F) << shift;
					if ((b & 0x80) == 0) {
						ok = true;
						break;
					}
					shift += 7;
					if (shift > 35) {
						break;
					}
				}
				if (!ok || pos + QVOX_CHANNEL_BYTES > total) {
					return PackedInt32Array();
				}
				const int32_t v = (int32_t)(p[pos] | (p[pos + 1] << 8));
				pos += QVOX_CHANNEL_BYTES;
				for (uint64_t j = 0; j < run_len; ++j) {
					if (idx >= n) {
						return PackedInt32Array();   // 游程和超过 N → 损坏
					}
					w[idx++] = v;
				}
			}
			if (idx != n) {
				return PackedInt32Array();   // 游程和 ≠ N → 损坏（§9 不变量）
			}
			return out;
		}
		case QVOX_CODEC_DENSE: {
			if (total < (int64_t)n * QVOX_CHANNEL_BYTES) {
				return PackedInt32Array();
			}
			out.resize(n);
			int32_t *w = out.ptrw();
			for (int i = 0; i < n; ++i) {
				w[i] = (int32_t)(p[2 * i] | (p[2 * i + 1] << 8));
			}
			return out;
		}
		case QVOX_CODEC_INDEXED: {
			if (total < 1) {
				return PackedInt32Array();
			}
			const int count = p[0];
			out.resize(n);
			int32_t *w = out.ptrw();
			if (count == 0) {   // 全空
				for (int i = 0; i < n; ++i) {
					w[i] = 0;
				}
				return out;
			}
			const int64_t table_end = 1 + (int64_t)count * QVOX_CHANNEL_BYTES;
			if (total < table_end) {
				return PackedInt32Array();
			}
			std::vector<int32_t> table(count);
			for (int k = 0; k < count; ++k) {
				table[k] = (int32_t)(p[1 + 2 * k] | (p[1 + 2 * k + 1] << 8));
			}
			const int bits = qvox_bits_for(count);
			if (total < table_end + (((int64_t)n * bits + 7) >> 3)) {
				return PackedInt32Array();
			}
			int64_t bit_pos = 0;
			for (int i = 0; i < n; ++i) {
				int code = 0;
				for (int b = 0; b < bits; ++b) {
					if ((p[table_end + (bit_pos >> 3)] >> (bit_pos & 7)) & 1) {
						code |= (1 << b);
					}
					++bit_pos;
				}
				if (code >= count) {
					return PackedInt32Array();   // 索引越界 → 损坏
				}
				w[i] = table[code];
			}
			return out;
		}
		default:
			return PackedInt32Array();
	}
}

Dictionary VoxelNative::choose_and_pack(const PackedInt32Array &buf, int n) {
	if (n > buf.size()) {
		n = buf.size();
	}
	int codec = QVOX_CODEC_EMPTY;
	if (n > 0) {
		const int32_t *p = buf.ptr();
		const int32_t first = p[0];
		// 第 1 趟：全零 / 全同（写入时最常见的两种形态，命中即免掉后续扫描）
		bool all_zero = true;
		for (int i = 0; i < n; ++i) {
			if (p[i] != 0) {
				all_zero = false;
				break;
			}
		}
		if (!all_zero) {
			bool all_same = true;
			for (int i = 1; i < n; ++i) {
				if (p[i] != first) {
					all_same = false;
					break;
				}
			}
			if (all_same) {
				codec = QVOX_CODEC_SOLID;
			} else {
				// 第 2 趟：RUN 精确字节 + 取值跨度（跨度为 INDEXED 的廉价预筛）
				int64_t run_bytes = 4;
				int run_len = 1;
				int32_t run_val = first;
				int32_t vmax = first;
				int32_t vmin = first;
				for (int i = 1; i < n; ++i) {
					const int32_t v = p[i];
					if (v == run_val) {
						++run_len;
					} else {
						run_bytes += (int64_t)qvox_varint_size(run_len) + QVOX_CHANNEL_BYTES;
						run_val = v;
						run_len = 1;
					}
					if (v > vmax) {
						vmax = v;
					} else if (v < vmin) {
						vmin = v;
					}
				}
				run_bytes += (int64_t)qvox_varint_size(run_len) + QVOX_CHANNEL_BYTES;

				codec = QVOX_CODEC_DENSE;
				int64_t best_bytes = (int64_t)n * QVOX_CHANNEL_BYTES;
				if (run_bytes < best_bytes) {
					codec = QVOX_CODEC_RUN;
					best_bytes = run_bytes;
				}

				// 第 3 趟：INDEXED 仅在"取值跨度 ≤ 255"时才真正统计
				if ((int64_t)vmax - (int64_t)vmin <= QVOX_U8_MAX) {
					std::unordered_set<int32_t> distinct;
					distinct.reserve(1024);
					bool ok = true;
					for (int i = 0; i < n; ++i) {
						distinct.insert(p[i]);
						if ((int)distinct.size() > QVOX_U8_MAX) {
							ok = false;
							break;
						}
					}
					if (ok) {
						const int bits = qvox_bits_for((int)distinct.size());
						const int64_t indexed_bytes = 1 + (int64_t)distinct.size() * QVOX_CHANNEL_BYTES
								+ (((int64_t)n * bits + 7) >> 3);
						if (indexed_bytes < best_bytes) {
							codec = QVOX_CODEC_INDEXED;
						}
					}
				}
			}
		}
	}
	Dictionary out;
	out["codec"] = codec;
	out["payload"] = n > 0 ? qvox_pack_any(codec, buf.ptr(), n) : PackedByteArray();
	return out;
}

Array VoxelNative::collect_all_positions(const Dictionary &buffers) {
	Array out;
	qvox_for_each_voxel(buffers, [&out](const Vector3i &pos, int32_t) {
		out.push_back(pos);
	});
	return out;
}

PackedInt32Array VoxelNative::collect_all_flat(const Dictionary &buffers) {
	int64_t count = 0;
	qvox_for_each_voxel(buffers, [&count](const Vector3i &, int32_t) {
		++count;
	});
	PackedInt32Array out;
	out.resize(count * 4);
	if (count == 0) {
		return out;
	}
	int32_t *w = out.ptrw();
	int64_t i = 0;
	qvox_for_each_voxel(buffers, [&w, &i](const Vector3i &pos, int32_t mat) {
		w[i++] = pos.x;
		w[i++] = pos.y;
		w[i++] = pos.z;
		w[i++] = mat;
	});
	return out;
}

Array VoxelNative::collect_bounds(const Dictionary &buffers) {
	Array out;
	bool any = false;
	int32_t mn[3] = { 0, 0, 0 };
	int32_t mx[3] = { 0, 0, 0 };
	qvox_for_each_voxel(buffers, [&any, &mn, &mx](const Vector3i &pos, int32_t) {
		const int32_t c[3] = { pos.x, pos.y, pos.z };
		if (!any) {
			any = true;
			for (int a = 0; a < 3; ++a) {
				mn[a] = c[a];
				mx[a] = c[a];
			}
			return;
		}
		for (int a = 0; a < 3; ++a) {
			if (c[a] < mn[a]) {
				mn[a] = c[a];
			}
			if (c[a] > mx[a]) {
				mx[a] = c[a];
			}
		}
	});
	if (any) {
		out.push_back(Vector3i(mn[0], mn[1], mn[2]));
		out.push_back(Vector3i(mx[0], mx[1], mx[2]));
	}
	return out;
}

Array VoxelNative::collect_sphere_positions(const Dictionary &buffers, const Vector3 &center, float radius) {
	Array out;
	if (radius < 0.0f) {
		return out;
	}
	// 与 GDScript 版同口径：cxi = floori(center.x)，r_i = ceili(radius)，
	// 判定 float(dx²+dy²+dz²) <= radius²（用未取整的 radius²，保证边界一致）。
	const int cxi = (int)std::floor((double)center.x);
	const int cyi = (int)std::floor((double)center.y);
	const int czi = (int)std::floor((double)center.z);
	const int r_i = (int)std::ceil((double)radius);
	const float radius_sq = radius * radius;
	const int32_t lo[3] = { cxi - r_i, cyi - r_i, czi - r_i };
	const int32_t hi[3] = { cxi + r_i, cyi + r_i, czi + r_i };

	const Array keys = buffers.keys();
	const int32_t volume = CHUNK_BITS * CHUNK_BITS * CHUNK_BITS;
	for (int ki = 0; ki < keys.size(); ++ki) {
		const Vector3i ck = keys[ki];
		const Vector3i origin = ck * CHUNK_BITS;
		// 只处理与球 AABB 相交的 chunk
		if (origin.x > hi[0] || origin.x + CHUNK_BITS - 1 < lo[0]
				|| origin.y > hi[1] || origin.y + CHUNK_BITS - 1 < lo[1]
				|| origin.z > hi[2] || origin.z + CHUNK_BITS - 1 < lo[2]) {
			continue;
		}
		const PackedInt32Array buf = buffers[ck];
		if (buf.size() < volume) {
			continue;
		}
		const int32_t *p = buf.ptr();
		const int32_t x0 = origin.x > lo[0] ? origin.x : lo[0];
		const int32_t x1 = origin.x + CHUNK_BITS - 1 < hi[0] ? origin.x + CHUNK_BITS - 1 : hi[0];
		const int32_t y0 = origin.y > lo[1] ? origin.y : lo[1];
		const int32_t y1 = origin.y + CHUNK_BITS - 1 < hi[1] ? origin.y + CHUNK_BITS - 1 : hi[1];
		const int32_t z0 = origin.z > lo[2] ? origin.z : lo[2];
		const int32_t z1 = origin.z + CHUNK_BITS - 1 < hi[2] ? origin.z + CHUNK_BITS - 1 : hi[2];
		for (int32_t z = z0; z <= z1; ++z) {
			const int32_t dz = z - czi;
			const int32_t lz = z - origin.z;
			for (int32_t y = y0; y <= y1; ++y) {
				const int32_t dy = y - cyi;
				const int32_t ly = y - origin.y;
				const int32_t row = ly * CHUNK_BITS + lz * CHUNK_BITS * CHUNK_BITS;
				const int32_t dyz = dy * dy + dz * dz;
				for (int32_t x = x0; x <= x1; ++x) {
					const int32_t lx = x - origin.x;
					if (p[row + lx] <= 0) {
						continue;
					}
					const int32_t dx = x - cxi;
					if ((float)(dx * dx + dyz) <= radius_sq) {
						out.push_back(Vector3i(x, y, z));
					}
				}
			}
		}
	}
	return out;
}

Array VoxelNative::collect_box_positions(const Dictionary &buffers, const Vector3i &min_p, const Vector3i &max_p) {
	Array out;
	if (min_p.x > max_p.x || min_p.y > max_p.y || min_p.z > max_p.z) {
		return out;
	}
	const Array keys = buffers.keys();
	const int32_t volume = CHUNK_BITS * CHUNK_BITS * CHUNK_BITS;
	for (int ki = 0; ki < keys.size(); ++ki) {
		const Vector3i ck = keys[ki];
		const Vector3i origin = ck * CHUNK_BITS;
		if (origin.x > max_p.x || origin.x + CHUNK_BITS - 1 < min_p.x
				|| origin.y > max_p.y || origin.y + CHUNK_BITS - 1 < min_p.y
				|| origin.z > max_p.z || origin.z + CHUNK_BITS - 1 < min_p.z) {
			continue;
		}
		const PackedInt32Array buf = buffers[ck];
		if (buf.size() < volume) {
			continue;
		}
		const int32_t *p = buf.ptr();
		const int32_t x0 = origin.x > min_p.x ? origin.x : min_p.x;
		const int32_t x1 = origin.x + CHUNK_BITS - 1 < max_p.x ? origin.x + CHUNK_BITS - 1 : max_p.x;
		const int32_t y0 = origin.y > min_p.y ? origin.y : min_p.y;
		const int32_t y1 = origin.y + CHUNK_BITS - 1 < max_p.y ? origin.y + CHUNK_BITS - 1 : max_p.y;
		const int32_t z0 = origin.z > min_p.z ? origin.z : min_p.z;
		const int32_t z1 = origin.z + CHUNK_BITS - 1 < max_p.z ? origin.z + CHUNK_BITS - 1 : max_p.z;
		for (int32_t z = z0; z <= z1; ++z) {
			const int32_t lz = z - origin.z;
			for (int32_t y = y0; y <= y1; ++y) {
				const int32_t row = (y - origin.y) * CHUNK_BITS + lz * CHUNK_BITS * CHUNK_BITS;
				for (int32_t x = x0; x <= x1; ++x) {
					if (p[row + (x - origin.x)] > 0) {
						out.push_back(Vector3i(x, y, z));
					}
				}
			}
		}
	}
	return out;
}

void VoxelNative::_bind_methods() {
	ClassDB::bind_static_method("VoxelNative", D_METHOD("choose_and_pack", "buf", "n"), &VoxelNative::choose_and_pack);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("pack_with_codec", "codec", "buf", "n"), &VoxelNative::pack_with_codec);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("unpack_block", "codec", "payload", "n"), &VoxelNative::unpack_block);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("voxel_value_range", "buf"), &VoxelNative::voxel_value_range);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_all_positions", "buffers"), &VoxelNative::collect_all_positions);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_all_flat", "buffers"), &VoxelNative::collect_all_flat);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_bounds", "buffers"), &VoxelNative::collect_bounds);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_sphere_positions", "buffers", "center", "radius"), &VoxelNative::collect_sphere_positions);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_box_positions", "buffers", "min_p", "max_p"), &VoxelNative::collect_box_positions);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("greedy_merge_dense", "grid", "width", "height"), &VoxelNative::greedy_merge_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_chunk_dense", "halo", "trans_flags", "scale", "chunk", "use_local_space", "offset"), &VoxelNative::generate_chunk_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_lod1_block_dense", "halo", "trans_flags", "scale", "block_key", "offset"), &VoxelNative::generate_lod1_block_dense);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_halo_from_buffers", "buffers", "chunk"), &VoxelNative::build_halo_from_buffers);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_arrays_native", "voxels", "trans_flags", "scale", "offset"), &VoxelNative::generate_arrays_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("generate_spheres_native", "voxels", "trans_flags", "subdivisions", "sphere_scale", "scale", "vertex_budget"), &VoxelNative::generate_spheres_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_lod_block_halo_from_buffers_native", "buffers", "block_key", "lod_shift"), &VoxelNative::build_lod_block_halo_from_buffers_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("patch_lod_block", "buffers", "block_key", "lod_shift", "coarse", "rmin", "rmax"), &VoxelNative::patch_lod_block);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("patch_lod_block_from_lod", "coarse_buffers", "block_key", "lod", "coarse", "rmin", "rmax"), &VoxelNative::patch_lod_block_from_lod);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("build_lod_block_halo_from_lod_buffers_native", "buffers", "block_key"), &VoxelNative::build_lod_block_halo_from_lod_buffers_native);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("find_unsupported_around", "buffers", "removed"), &VoxelNative::find_unsupported_around);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("propagate_stress", "buffers", "removed", "strength_table", "max_steps", "force", "decay"), &VoxelNative::propagate_stress);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_materials", "buffers", "positions"), &VoxelNative::collect_materials);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_materials_flat", "buffers", "positions"), &VoxelNative::collect_materials_flat);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("install_flat_voxels", "flat"), &VoxelNative::install_flat_voxels);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("apply_damage", "damage_chunks", "positions", "materials", "hardness_table", "damage", "use_health"), &VoxelNative::apply_damage);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("remove_voxels_bulk", "buffers", "positions"), &VoxelNative::remove_voxels_bulk);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("set_voxels_bulk", "buffers", "positions", "material_id"), &VoxelNative::set_voxels_bulk);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("collect_chunks", "positions"), &VoxelNative::collect_chunks);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("partition_connected", "positions"), &VoxelNative::partition_connected);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("snapshot_chunks_halo", "buffers", "chunks"), &VoxelNative::snapshot_chunks_halo);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("crc32", "data", "start", "length"), &VoxelNative::crc32);
	ClassDB::bind_static_method("VoxelNative", D_METHOD("crc32_segments", "data", "offsets", "lengths"), &VoxelNative::crc32_segments);
}
