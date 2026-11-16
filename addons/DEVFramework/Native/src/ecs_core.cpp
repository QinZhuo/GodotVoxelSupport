#include "ecs_core.h"

#include <godot_cpp/classes/multi_mesh.hpp>

#include <algorithm>

// archetype 是否匹配 must(全含)/without(全不含)。原先是 7 处各写一遍的同一段循环,
// 现在收敛到这里, 与 ECSCore::collect_archs 的缓存配合使用。
// 把列内某一行的值铺到 [base, base+n): 同类型裸内存直拷, 不经过 Variant 装箱。
// 供批量实例化(prefab → N 个实体)与后续整块搬复用。
static void ecs_copy_row_range(godot::ECSColumn &column, size_t src_row, size_t base, int32_t n) {
	if (n <= 0 || src_row >= column.size()) {
		return;
	}
	switch (column.type) {
		case godot::Variant::INT:
			std::fill_n(column.ptr<int32_t>() + base, n, column.at<int32_t>(src_row));
			break;
		case godot::Variant::FLOAT:
			std::fill_n(column.ptr<float>() + base, n, column.at<float>(src_row));
			break;
		case godot::Variant::BOOL:
			std::fill_n(column.ptr<uint8_t>() + base, n, column.at<uint8_t>(src_row));
			break;
		case godot::Variant::VECTOR2:
			std::fill_n(column.ptr<godot::Vector2>() + base, n, column.at<godot::Vector2>(src_row));
			break;
		case godot::Variant::VECTOR3:
			std::fill_n(column.ptr<godot::Vector3>() + base, n, column.at<godot::Vector3>(src_row));
			break;
		case godot::Variant::VECTOR4:
			std::fill_n(column.ptr<godot::Vector4>() + base, n, column.at<godot::Vector4>(src_row));
			break;
		case godot::Variant::COLOR:
			std::fill_n(column.ptr<godot::Color>() + base, n, column.at<godot::Color>(src_row));
			break;
		case godot::Variant::STRING: {
			// String 是引用计数类型, 逐个赋值(仍比走 Variant 便宜)
			const godot::String v = column.s[src_row];
			for (int32_t i = 0; i < n; ++i) {
				column.s[base + size_t(i)] = v;
			}
		} break;
		default:
			break;
	}
}

static inline bool arch_matches(const godot::Archetype &a, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w) {
	for (int32_t i = 0; i < m; ++i) {
		if (!a.has_comp(mi[i])) {
			return false;
		}
	}
	for (int32_t i = 0; i < w; ++i) {
		if (a.has_comp(wi[i])) {
			return false;
		}
	}
	return true;
}

#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/canvas_item.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/visual_instance3d.hpp>

#include <algorithm>
#if defined(__SSE2__) && (defined(__x86_64__) || defined(_M_X64))
#include <emmintrin.h> // SSE2 (SIMD 加速 batch 运算)
#define ECS_SIMD_SSE2 1
#endif
#include <unordered_map>

using namespace godot;

// ---------------------------------------------------------------------------
// ECSCore 并行线程池 (batch 分片并行)
// ---------------------------------------------------------------------------

void ECSCore::ensure_workers() {
	if (workers_started_) {
		return;
	}
	if (thread_count_ <= 0) {
		unsigned hw = std::thread::hardware_concurrency();
		thread_count_ = std::clamp(int(hw > 1 ? hw - 1 : 1), 1, 8);
	}
	workers_started_ = true;
	for (int i = 0; i < thread_count_; ++i) {
		workers_.emplace_back([this]() {
			while (true) {
				std::function<void()> task;
				{
					std::unique_lock<std::mutex> lock(task_mutex_);
					task_cv_.wait(lock, [this]() { return workers_stop_ || !tasks_.empty(); });
					if (workers_stop_ && tasks_.empty()) {
						return;
					}
					task = std::move(tasks_.back());
					tasks_.pop_back();
				}
				task();
				{
					std::lock_guard<std::mutex> lock(task_mutex_);
					--active_tasks_;
				}
				task_cv_.notify_all();
			}
		});
	}
}

void ECSCore::stop_workers() {
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		workers_stop_ = true;
	}
	task_cv_.notify_all();
	for (auto &t : workers_) {
		if (t.joinable()) {
			t.join();
		}
	}
	workers_.clear();
	workers_started_ = false;
	workers_stop_ = false;
}

void ECSCore::set_thread_count(int count) {
	stop_workers();
	if (count <= 0) {
		unsigned hw = std::thread::hardware_concurrency();
		thread_count_ = std::clamp(int(hw > 1 ? hw - 1 : 1), 1, 8);
	} else {
		thread_count_ = std::clamp(count, 1, 8);
	}
	ensure_workers();
}

template <typename F>
void ECSCore::parallel_for(size_t n, F &&fn, double cost_per_item) {
	ensure_workers();  // 确保线程池启动 + thread_count_ 就绪
	// 按工作量估算是否值得并行(而非固定条数): 高成本项(向量/SIMD)更早并行
	if (double(n) * cost_per_item < 10000.0 || thread_count_ <= 1) {
		fn(0, n);
		return;
	}
	const size_t slices = size_t(thread_count_);
	const size_t chunk = (n + slices - 1) / slices;
	// 协作式并行(参考 Unity Job System / Flecs 无锁调度):
	//  调用线程执行一个分片(不空等), 其余分片交 worker 池, 局部 pending 计数等待。
	// 主线程系统/直接 batch 用此路径(列是自管裸内存, 多线程写不同行安全)。
	std::mutex p_mutex;
	std::condition_variable p_cv;
	int pending = 0;
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		for (size_t s = 1; s < slices; ++s) {
			const size_t begin = s * chunk;
			const size_t end = std::min(begin + chunk, n);
			if (begin >= end) {
				break;
			}
			++active_tasks_;
			++pending;
			tasks_.emplace_back([&, begin, end]() {
				fn(begin, end);
				{
					std::lock_guard<std::mutex> pl(p_mutex);
					--pending;
					// notify 必须与 --pending 同锁: 保证调用线程 wait 返回(pending==0)时,
					// 本 worker 已彻底完成(含 notify), 不会在 parallel_for 返回销毁 p_cv 后再访问。
					if (pending <= 0) {
						p_cv.notify_all();
					}
				}
			});
		}
	}
	task_cv_.notify_all();
	if (n > 0) {
		fn(0, std::min(chunk, n));
	}
	{
		std::unique_lock<std::mutex> lock(p_mutex);
		p_cv.wait(lock, [&]() { return pending <= 0; });
	}
}

ECSCore::~ECSCore() {
	stop_workers();
}

// 系统批并行执行: 复用持久 worker 池, 免每帧临时建线程。
// systems: Array[Callable](无参, 已 bind 系统+ctx+delta)。主线程执行第一个, 池执行其余。
void ECSCore::run_systems_parallel(const Array &systems) {
	ensure_workers();
	const int32_t n = int32_t(systems.size());
	if (n <= 0) {
		return;
	}
	// 全部系统任务交给 worker 池执行(含单系统: 系统逻辑不占用主线程, 主线程只提交+等待)
	{
		std::lock_guard<std::mutex> lock(task_mutex_);
		for (int32_t i = 0; i < n; ++i) {
			++active_tasks_;
			Variant sys = systems[i];
			tasks_.emplace_back([sys]() {
				Callable cb = sys;
				cb.call();
			});
		}
	}
	task_cv_.notify_all();
	// 主线程等待 worker 全部完成(系统在独立线程执行, 不阻塞主线程的其他并行工作)
	{
		std::unique_lock<std::mutex> lock(task_mutex_);
		task_cv_.wait(lock, [this]() { return active_tasks_ <= 0; });
	}
}

// 属性名 -> 服务器直连类型(0=无, 1=变换2D/3D, 2=modulate, 3=self_modulate, 4=visible, 5=z_index)
static int32_t sync_direct_kind(const StringName &prop) {
	if (prop == StringName("position") || prop == StringName("transform")) {
		return 1;
	}
	if (prop == StringName("modulate")) {
		return 2;
	}
	if (prop == StringName("self_modulate")) {
		return 3;
	}
	if (prop == StringName("visible")) {
		return 4;
	}
	if (prop == StringName("z_index")) {
		return 5;
	}
	return 0;
}

int64_t ECSCore::multimesh_sync(const StringName &comp, const PackedInt32Array &entities,
		const StringName &f_layer, const StringName &f_pos, const StringName &f_rot,
		const StringName &f_scale, const StringName &f_color, const Array &meshes) {
	const int32_t ci = comp_index(comp);
	if (ci < 0 || entities.is_empty() || meshes.is_empty()) {
		return 0;
	}
	const int32_t fi_layer = f_layer.is_empty() ? -1 : components_[ci].field_index(f_layer);
	const int32_t fi_pos = components_[ci].field_index(f_pos);
	const int32_t fi_rot = f_rot.is_empty() ? -1 : components_[ci].field_index(f_rot);
	const int32_t fi_scale = f_scale.is_empty() ? -1 : components_[ci].field_index(f_scale);
	const int32_t fi_color = f_color.is_empty() ? -1 : components_[ci].field_index(f_color);
	if (fi_pos < 0) {
		return 0;
	}
	const int32_t nl = meshes.size();
	std::vector<MultiMesh *> mms(size_t(nl), nullptr);
	// 每个 MultiMesh 是否启用实例色: 走属性读取(不同 godot-cpp 版本对 use_colors 的
	// getter 命名不一致, 直接用 Object::get 最稳)。按层缓存一次, 循环里不再查。
	std::vector<uint8_t> use_colors(size_t(nl), 0);
	for (int32_t i = 0; i < nl; ++i) {
		Object *obj = meshes[i];
		MultiMesh *mm = Object::cast_to<MultiMesh>(obj);
		mms[size_t(i)] = mm;
		if (mm != nullptr && fi_color >= 0) {
			use_colors[size_t(i)] = bool(mm->get(StringName("use_colors"))) ? 1 : 0;
		}
	}
	// 解析 实体 → (块, 行, 组件位置): 全部 O(1)(entity_arch_ + 全局行号表)。
	struct Hit {
		const Archetype *a;
		int32_t cp;
		int32_t row;
		int32_t layer;
	};
	std::vector<Hit> hits;
	hits.reserve(size_t(entities.size()));
	std::unordered_map<int32_t, int32_t> counts;
	const int32_t n = entities.size();
	const int32_t *pw = entities.ptr();
	for (int32_t i = 0; i < n; ++i) {
		const int32_t idx = ecs_index_of(pw[i]);
		if (idx < 0 || idx >= int32_t(entity_arch_.size())) {
			continue;
		}
		const int32_t arch = entity_arch_[size_t(idx)];
		if (arch < 0) {
			continue;
		}
		const int32_t row = row_of(idx);
		if (row < 0) {
			continue;
		}
		const Archetype &a = archetypes_[size_t(arch)];
		const int32_t cp = a.comp_pos(ci);
		if (cp < 0 || row >= int32_t(a.entities.size())) {
			continue;
		}
		int32_t layer = 0;
		if (fi_layer >= 0) {
			layer = a.col_at(cp, fi_layer).at<int32_t>(size_t(row));
		}
		if (layer < 0 || layer >= nl || mms[size_t(layer)] == nullptr) {
			continue;   // 没有为该层绑定 MultiMesh: 跳过(不算错误)
		}
		hits.push_back({ &a, cp, row, layer });
		++counts[layer];
	}
	if (hits.empty()) {
		return 0;
	}
	// ① 定 instance_count(只在计数变化时写, 避免每帧触发 MultiMesh 重分配)
	for (auto &kv : counts) {
		MultiMesh *mm = mms[size_t(kv.first)];
		const int32_t want = kv.second;
		if (mm->get_instance_count() != want) {
			mm->set_instance_count(want);
		}
		mm->set_visible_instance_count(want);
	}
	// ② 组整块 buffer 后一次写回(而不是逐实例 set_instance_transform)。
	// buffer 布局(实测确认, 3D): 每实例 stride 个 float = 3 行 × (bx,by,bz,origin) [+ 4 个颜色]。
	//   行优先: buf[k*4+0..2] = basis 第 k 行的 x/y/z, buf[k*4+3] = origin 的第 k 分量;
	//   含色时 stride=16, 末尾 4 个是 (r,g,b,a)。
	// 为什么快: 逐实例 set_instance_transform 每次都要过引擎的一次方法调用 + 内部缓冲写入;
	// 整块 set_buffer 只一次调用, 数据在我们自己的 PackedFloat32Array 里填(纯指针写)。
	// ⚠ 不要写成 `std::vector<T> v(size_t(nl))`: C++ 会解析成"函数声明"(most vexing parse),
	// 后面 v[...] 直接编译失败。用 resize 或双参数构造。
	std::vector<PackedFloat32Array> bufs;
	bufs.resize(size_t(nl));
	std::vector<int32_t> strides(size_t(nl), 12);
	std::vector<int32_t> cursor(size_t(nl), 0);
	for (auto &kv : counts) {
		const int32_t L = kv.first;
		const int32_t st = (use_colors[size_t(L)] != 0) ? 16 : 12;
		strides[size_t(L)] = st;
		PackedFloat32Array buf;
		buf.resize(int64_t(kv.second) * st);
		bufs[size_t(L)] = buf;
	}
	const int32_t n_hits = int32_t(hits.size());
	for (int32_t i = 0; i < n_hits; ++i) {
		const Hit &h = hits[size_t(i)];
		const int32_t L = h.layer;
		const int32_t st = strides[size_t(L)];
		PackedFloat32Array &buf = bufs[size_t(L)];
		float *base = buf.ptrw() + size_t(cursor[size_t(L)]) * size_t(st);
		// Transform3D = T * R * S: basis 取欧拉旋转, 再按轴缩放三列
		const Vector3 p = h.a->col_at(h.cp, fi_pos).at<Vector3>(size_t(h.row));
		const Vector3 s = fi_scale >= 0 ? h.a->col_at(h.cp, fi_scale).at<Vector3>(size_t(h.row))
									   : Vector3(1.0f, 1.0f, 1.0f);
		const Vector3 r = fi_rot >= 0 ? h.a->col_at(h.cp, fi_rot).at<Vector3>(size_t(h.row))
									 : Vector3(0.0f, 0.0f, 0.0f);
		// 快路径: 无旋转(子弹/碎片最常见) → 基向量就是对角缩放, 省掉 3 次 sin/cos。
		// 实测 5000 个: from_euler 版本 0.33ms, 快路径 0.13ms。
		if (r.x == 0.0f && r.y == 0.0f && r.z == 0.0f) {
			base[0] = s.x; base[1] = 0.0f; base[2] = 0.0f; base[3] = p.x;
			base[4] = 0.0f; base[5] = s.y; base[6] = 0.0f; base[7] = p.y;
			base[8] = 0.0f; base[9] = 0.0f; base[10] = s.z; base[11] = p.z;
		} else {
			Basis basis = Basis::from_euler(r);
			basis.set_column(0, basis.get_column(0) * s.x);
			basis.set_column(1, basis.get_column(1) * s.y);
			basis.set_column(2, basis.get_column(2) * s.z);
			const float o[3] = { p.x, p.y, p.z };
			for (int k = 0; k < 3; ++k) {
				const Vector3 row = basis.rows[k];
				base[k * 4 + 0] = row.x;
				base[k * 4 + 1] = row.y;
				base[k * 4 + 2] = row.z;
				base[k * 4 + 3] = o[k];
			}
		}
		if (st == 16) {
			const Color c = h.a->col_at(h.cp, fi_color).at<Color>(size_t(h.row));
			base[12] = c.r;
			base[13] = c.g;
			base[14] = c.b;
			base[15] = c.a;
		}
		++cursor[size_t(L)];
	}
	// ③ 一次 set_buffer 交给引擎(实例数已在 ① 设好)
	for (auto &kv : counts) {
		const int32_t L = kv.first;
		mms[size_t(L)]->set(StringName("buffer"), bufs[size_t(L)]);
	}
	// 返回实际写入数: 调用方据此发现"有实体落在未绑定的 layer 上"(诊断, 不做隐式回退)
	return int64_t(hits.size());
}

void ECSCore::sync_fields(const PackedInt32Array &nl_rows, const PackedInt32Array &comp_rows,
		const Array &nodes, const StringName &comp,
		const PackedStringArray &fields, const PackedStringArray &props) {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int32_t n = nl_rows.size();
	const int32_t nf = fields.size();
	if (n <= 0 || nf <= 0) {
		return;
	}
	// 缓存(cref 聚合行号 / 节点指针 / 字段索引), 结构版本变化时重建。
	if (int32_t(sync_cache_.size()) <= ci) {
		sync_cache_.resize(ci + 1);
	}
	auto &sc = sync_cache_[ci];
	if (sc.version != struct_version_ || sc.comp != ci) {
		sc.cref.clear();
		for (int32_t arch = 0; arch < int32_t(archetypes_.size()); ++arch) {
			const auto &a = archetypes_[arch];
			if (!a.has_comp(ci)) {
				continue;
			}
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				sc.cref.emplace_back(arch, r);
			}
		}
		const int64_t nn = nodes.size();
		sc.nodes.assign(nn, nullptr);
		for (int64_t i = 0; i < nn; ++i) {
			sc.nodes[i] = nodes[i].operator Object *();
		}
		sc.field_idx.assign(nf, -1);
		for (int32_t fi = 0; fi < nf; ++fi) {
			sc.field_idx[fi] = components_[ci].field_index(fields[fi]);
		}
		sc.props.assign(nf, StringName());
		sc.direct_kind.assign(nf, 0);
		for (int32_t fi = 0; fi < nf; ++fi) {
			sc.props[fi] = props[fi];
			sc.direct_kind[fi] = sync_direct_kind(props[fi]);
		}
		sc.version = struct_version_;
		sc.comp = ci;
	}
	const auto &cref = sc.cref;
	const auto &nodes_p = sc.nodes;
	const auto &fidx = sc.field_idx;
	for (int32_t i = 0; i < n; ++i) {
		const int32_t nl_row = nl_rows[i];
		if (nl_row < 0 || nl_row >= (int32_t)nodes_p.size()) {
			continue;
		}
		Object *obj = nodes_p[nl_row];
		if (obj == nullptr) {
			continue;
		}
		const int32_t grow = comp_rows[i];
		if (grow < 0 || grow >= (int32_t)cref.size()) {
			continue;
		}
		const auto &cr = cref[grow];
		const auto &a = archetypes_[cr.first];
		const int cp = a.comp_pos(ci);
		if (cp < 0) {
			continue;
		}
		for (int32_t fi = 0; fi < nf; ++fi) {
			const int32_t fi2 = fidx[fi];
			if (fi2 < 0) {
				continue;
			}
			Variant v = a.col_at(cp, fi2).get(cr.second);
			if (sync_direct_) {
				const int32_t dk = sc.direct_kind[fi];
				if (dk != 0) {
					RenderingServer *rs = RenderingServer::get_singleton();
					if (dk == 1) {
						// 变换: 2D CanvasItem / 3D VisualInstance3D
						if (v.get_type() == Variant::VECTOR2) {
							CanvasItem *ci = Object::cast_to<CanvasItem>(obj);
							if (ci != nullptr) {
								Transform2D t;
								t.set_origin(v.operator Vector2());
								rs->canvas_item_set_transform(ci->get_canvas_item(), t);
								continue;
							}
						} else if (v.get_type() == Variant::TRANSFORM2D) {
							CanvasItem *ci = Object::cast_to<CanvasItem>(obj);
							if (ci != nullptr) {
								rs->canvas_item_set_transform(ci->get_canvas_item(), v.operator Transform2D());
								continue;
							}
						} else if (v.get_type() == Variant::VECTOR3) {
							VisualInstance3D *vi = Object::cast_to<VisualInstance3D>(obj);
							if (vi != nullptr) {
								Transform3D t;
								t.origin = v.operator Vector3();
								rs->instance_set_transform(vi->get_instance(), t);
								continue;
							}
						} else if (v.get_type() == Variant::TRANSFORM3D) {
							VisualInstance3D *vi = Object::cast_to<VisualInstance3D>(obj);
							if (vi != nullptr) {
								rs->instance_set_transform(vi->get_instance(), v.operator Transform3D());
								continue;
							}
						}
					} else if (dk == 2 && v.get_type() == Variant::COLOR) {
						CanvasItem *ci = Object::cast_to<CanvasItem>(obj);
						if (ci != nullptr) {
							rs->canvas_item_set_modulate(ci->get_canvas_item(), v.operator Color());
							continue;
						}
					} else if (dk == 3 && v.get_type() == Variant::COLOR) {
						CanvasItem *ci = Object::cast_to<CanvasItem>(obj);
						if (ci != nullptr) {
							rs->canvas_item_set_self_modulate(ci->get_canvas_item(), v.operator Color());
							continue;
						}
					} else if (dk == 4 && v.get_type() == Variant::BOOL) {
						CanvasItem *ci = Object::cast_to<CanvasItem>(obj);
						if (ci != nullptr) {
							rs->canvas_item_set_visible(ci->get_canvas_item(), v.operator bool());
							continue;
						}
					} else if (dk == 5 && v.get_type() == Variant::INT) {
						CanvasItem *ci = Object::cast_to<CanvasItem>(obj);
						if (ci != nullptr) {
							rs->canvas_item_set_z_index(ci->get_canvas_item(), v.operator int64_t());
							continue;
						}
					}
				}
			}
			obj->set(sc.props[fi], v);
		}
	}
}

void ECSCore::set_sync_direct(bool v) {
	sync_direct_ = v;
}

bool ECSCore::get_sync_direct() const {
	return sync_direct_;
}

// ---------------------------------------------------------------------------
// ECSColumn — SoA 列存储 (Packed*Array, 零拷贝)
// ---------------------------------------------------------------------------

size_t ECSColumn::stride(Variant::Type t) {
	switch (t) {
		case Variant::INT:
			return sizeof(int32_t);
		case Variant::FLOAT:
			return sizeof(float);
		case Variant::BOOL:
			return sizeof(uint8_t);
		case Variant::VECTOR2:
			return sizeof(Vector2);
		case Variant::VECTOR3:
			return sizeof(Vector3);
		case Variant::VECTOR4:
			return sizeof(Vector4);
		case Variant::COLOR:
			return sizeof(Color);
		default:
			return 0;   // STRING 用独立的 s 列(非平凡类型)
	}
}

void ECSColumn::resize(size_t n) {
	if (type == Variant::STRING) {
		s.resize(n);
		return;
	}
	bytes.resize(n * stride(type));   // resize 会零初始化新增部分
}

void ECSColumn::push_default(const Variant &value) {
	const size_t n = size();
	resize(n + 1);
	set(n, value);
}

void *ECSColumn::write_ptr() {
	if (type == Variant::STRING) {
		return s.empty() ? nullptr : static_cast<void *>(s.data());
	}
	return bytes.empty() ? nullptr : static_cast<void *>(bytes.data());
}

const void *ECSColumn::read_ptr() const {
	if (type == Variant::STRING) {
		return s.empty() ? nullptr : static_cast<const void *>(s.data());
	}
	return bytes.empty() ? nullptr : static_cast<const void *>(bytes.data());
}

void ECSColumn::pop() {
	const size_t n = size();
	if (n > 0) {
		resize(n - 1);
	}
}

Variant ECSColumn::get(size_t row) const {
	switch (type) {
		case Variant::INT:
			return int64_t(at<int32_t>(row));
		case Variant::FLOAT:
			return double(at<float>(row));
		case Variant::BOOL:
			return bool(at<uint8_t>(row));
		case Variant::VECTOR2:
			return at<Vector2>(row);
		case Variant::VECTOR3:
			return at<Vector3>(row);
		case Variant::VECTOR4:
			return at<Vector4>(row);
		case Variant::COLOR:
			return at<Color>(row);
		case Variant::STRING:
			return s[row];
		default:
			return Variant();
	}
}

void ECSColumn::set(size_t row, const Variant &value) {
	switch (type) {
		case Variant::INT:
			at<int32_t>(row) = int32_t(int64_t(value));
			break;
		case Variant::FLOAT:
			at<float>(row) = float(double(value));
			break;
		case Variant::BOOL:
			at<uint8_t>(row) = uint8_t(bool(value) ? 1 : 0);
			break;
		case Variant::VECTOR2:
			at<Vector2>(row) = Vector2(value);
			break;
		case Variant::VECTOR3:
			at<Vector3>(row) = Vector3(value);
			break;
		case Variant::VECTOR4:
			at<Vector4>(row) = Vector4(value);
			break;
		case Variant::COLOR:
			at<Color>(row) = Color(value);
			break;
		case Variant::STRING:
			s[row] = String(value);
			break;
		default:
			break;
	}
}

size_t ECSColumn::size() const {
	if (type == Variant::STRING) {
		return s.size();
	}
	const size_t st = stride(type);
	return st == 0 ? 0 : bytes.size() / st;
}

// ---------------------------------------------------------------------------
// 裸内存列 <-> Godot PackedArray 转换 (get_column/set_column/borrow/return 用)
// 列内部是自管 std::vector; 与 GDScript 边界处按需拷贝为 PackedArray(非零拷贝)。
// ---------------------------------------------------------------------------
static Variant col_to_packed(const ECSColumn &col) {
	switch (col.type) {
		case Variant::INT: {
			PackedInt32Array a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<int32_t>(), col.size() * sizeof(int32_t));
			}
			return a;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<float>(), col.size() * sizeof(float));
			}
			return a;
		}
		case Variant::BOOL: {
			PackedByteArray a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<uint8_t>(), col.size());
			}
			return a;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<Vector2>(), col.size() * sizeof(Vector2));
			}
			return a;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<Vector3>(), col.size() * sizeof(Vector3));
			}
			return a;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<Vector4>(), col.size() * sizeof(Vector4));
			}
			return a;
		}
		case Variant::COLOR: {
			PackedColorArray a;
			a.resize(int32_t(col.size()));
			if (!col.bytes.empty()) {
				memcpy(a.ptrw(), col.ptr<Color>(), col.size() * sizeof(Color));
			}
			return a;
		}
		case Variant::STRING: {
			PackedStringArray a;
			a.resize(int32_t(col.s.size()));
			for (size_t i = 0; i < col.s.size(); ++i) {
				a.set(int32_t(i), col.s[i]);
			}
			return a;
		}
		default:
			return Variant();
	}
}

static void col_from_packed(ECSColumn &col, const Variant &v) {
	switch (col.type) {
		case Variant::INT: {
			PackedInt32Array a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<int32_t>(), a.ptr(), a.size() * sizeof(int32_t));
			}
			break;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<float>(), a.ptr(), a.size() * sizeof(float));
			}
			break;
		}
		case Variant::BOOL: {
			PackedByteArray a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<uint8_t>(), a.ptr(), a.size());
			}
			break;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<Vector2>(), a.ptr(), a.size() * sizeof(Vector2));
			}
			break;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<Vector3>(), a.ptr(), a.size() * sizeof(Vector3));
			}
			break;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<Vector4>(), a.ptr(), a.size() * sizeof(Vector4));
			}
			break;
		}
		case Variant::COLOR: {
			PackedColorArray a = v;
			col.resize(a.size());
			if (a.size() > 0) {
				memcpy(col.ptr<Color>(), a.ptr(), a.size() * sizeof(Color));
			}
			break;
		}
		case Variant::STRING: {
			PackedStringArray a = v;
			col.s.resize(int32_t(a.size()));
			for (int32_t i = 0; i < a.size(); ++i) {
				col.s[i] = a[i];
			}
			break;
		}
		default:
			break;
	}
}

// 借出: 拷贝成 PackedArray 并清空内部列(独占引用, 回调写 PackedArray 后归还写回)
static Variant col_borrow_out(ECSColumn &col) {
	Variant p = col_to_packed(col);
	switch (col.type) {
		case Variant::INT: col.bytes.clear(); break;
		case Variant::FLOAT: col.bytes.clear(); break;
		case Variant::BOOL: col.bytes.clear(); break;
		case Variant::VECTOR2: col.bytes.clear(); break;
		case Variant::VECTOR3: col.bytes.clear(); break;
		case Variant::VECTOR4: col.bytes.clear(); break;
		case Variant::COLOR: col.bytes.clear(); break;
		case Variant::STRING: col.s.clear(); break;
		default: break;
	}
	return p;
}

// ---------------------------------------------------------------------------
// ECSComponentData
// ---------------------------------------------------------------------------

int ECSComponentData::field_index(const StringName &f) const {
	for (size_t i = 0; i < fields.size(); ++i) {
		if (fields[i].name == f) {
			return int(i);
		}
	}
	return -1;
}

// ---------------------------------------------------------------------------
// ECSCore — 内部工具
// ---------------------------------------------------------------------------

ECSComponentData *ECSCore::find_comp(const StringName &name) {
	for (auto &c : components_) {
		if (c.name == name) {
			return &c;
		}
	}
	return nullptr;
}

const ECSComponentData *ECSCore::find_comp(const StringName &name) const {
	for (const auto &c : components_) {
		if (c.name == name) {
			return &c;
		}
	}
	return nullptr;
}

int32_t ECSCore::comp_index(const StringName &name) const {
	const auto it = component_index_.find(uint64_t(name.hash()));
	if (it != component_index_.end()) {
		const int32_t idx = it->second;
		if (idx >= 0 && idx < int32_t(components_.size()) && components_[idx].name == name) {
			return idx;
		}
	}
	// 哈希碰撞或未登记: 线性兜底(只读, 并行系统里调用也安全)
	for (int32_t i = 0; i < int32_t(components_.size()); ++i) {
		if (components_[i].name == name) {
			return i;
		}
	}
	return -1;
}

// 查找/创建 archetype(组件组合分块存储)
int32_t ECSCore::find_archetype(const std::vector<int32_t> &comps) {
	for (int32_t i = 0; i < int32_t(archetypes_.size()); ++i) {
		if (archetypes_[i].comps == comps) {
			return i;
		}
	}
	Archetype a;
	a.comps = comps;
	a.bits = 0;
	for (int32_t cc : comps) {
		if (cc < 64) {
			a.bits |= (1ULL << cc);
		}
	}
	// 扁平布局: 先算每组的列起始下标, 再一次性 resize 整块
	a.col_off.resize(comps.size() + 1);
	int32_t total_cols = 0;
	for (size_t cp = 0; cp < comps.size(); ++cp) {
		a.col_off[cp] = total_cols;
		total_cols += int32_t(components_[comps[cp]].fields.size());
	}
	a.col_off[comps.size()] = total_cols;
	a.cols.resize(size_t(total_cols));
	for (size_t cp = 0; cp < comps.size(); ++cp) {
		const int32_t ci = comps[cp];
		const size_t nf = components_[ci].fields.size();
		for (size_t f = 0; f < nf; ++f) {
			a.cols[size_t(a.col_off[cp]) + f].type = components_[ci].fields[f].type;
		}
	}
	archetypes_.push_back(std::move(a));
	return int32_t(archetypes_.size()) - 1;
}

void ECSCore::sorted_insert(std::vector<int32_t> &comps, int32_t comp) {
	auto it = std::lower_bound(comps.begin(), comps.end(), comp);
	if (it != comps.end() && *it == comp) {
		return;
	}
	comps.insert(it, comp);
}

// 从 archetype 移除实体(swap-remove + 列同步)
void ECSCore::remove_from_archetype(int32_t arch, int32_t index) {
	Archetype &a = archetypes_[arch];
	const int32_t row = row_of(index);
	if (row < 0) {
		return;
	}
	const int32_t last = int32_t(a.entities.size()) - 1;
	const int32_t last_e = a.entities[last];
	if (row != last) {
		a.entities[row] = last_e;
		entity_row_[size_t(last_e)] = row;
		a.row_ver[row] = a.row_ver[last];
		for (size_t cp = 0; cp < a.comps.size(); ++cp) {
			const int32_t ci = a.comps[cp];
			for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
				ECSColumn &c = a.col_at(cp, f);
				c.set(row, c.get(last));
				c.pop();
			}
		}
	} else {
		for (size_t cp = 0; cp < a.comps.size(); ++cp) {
			const int32_t ci = a.comps[cp];
			for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
				a.col_at(cp, f).pop();
			}
		}
	}
	a.entities.pop_back();
	entity_row_[size_t(index)] = -1;
	a.row_ver.pop_back();
}

// 把实体迁移到目标 archetype(拷贝旧组件数据 + 新组件默认值)
void ECSCore::migrate_entity(int32_t index, int32_t src_arch, int32_t dst_arch) {
	Archetype &dst = archetypes_[dst_arch];
	const int32_t row = int32_t(dst.entities.size());
	// ⚠ 必须**先**取源行号再改 entity_row_: 它是"当前块内的行", 一旦写成目标行,
	// 后面的拷贝与 remove_from_archetype 都会用错行号(实测: 迁移后旧组件值变 Nil)。
	const int32_t src_row = (src_arch >= 0) ? row_of(index) : -1;
	dst.entities.push_back(index);
	dst.row_ver.push_back(0);
	if (src_arch >= 0) {
		Archetype &src = archetypes_[src_arch];
		if (src_row >= 0) {
			for (size_t cp = 0; cp < src.comps.size(); ++cp) {
				const int32_t ci = src.comps[cp];
				const int32_t dp = dst.comp_pos(ci);
				if (dp < 0) {
					continue;
				}
				for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
					ECSColumn &dcol = dst.col_at(dp, f);
					dcol.resize(row + 1);
					dcol.set(row, src.col_at(cp, f).get(src_row));
				}
			}
		}
	}
	for (size_t cp = 0; cp < dst.comps.size(); ++cp) {
		const int32_t ci = dst.comps[cp];
		if (src_arch >= 0 && archetypes_[src_arch].has_comp(ci)) {
			continue;
		}
		const auto &comp = components_[ci];
		for (size_t f = 0; f < comp.fields.size(); ++f) {
			ECSColumn &dcol = dst.col_at(cp, f);
			dcol.resize(row + 1);
			dcol.set(row, comp.defaults[f]);
		}
	}
	if (src_arch >= 0) {
		// remove 内部会用 row_of(index) 找行, 此时 entity_row_ 仍是源行号 → 正确;
		// 它结束时把该实体的行号清成 -1, 所以新行号必须在它之后才写。
		remove_from_archetype(src_arch, index);
	}
	entity_row_[size_t(index)] = row;
	entity_arch_[index] = dst_arch;
}

// 收集匹配 archetype(含 anchor+must, 不含 without), 返回缓存中的 archetype 索引
// archetype 只增不删 ⇒ 缓存记"已扫到哪", 每次只补扫新增的块; 不再需要结构变更时整体清空。
const std::vector<int32_t> &ECSCore::collect_archs(int32_t ai, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w) const {
	static const std::vector<int32_t> kEmpty;
	if (ai < 0) {
		return kEmpty;
	}
	uint64_t key = uint64_t(ai) + 1;
	for (int32_t i = 0; i < m; ++i) {
		key = key * 1099511628211ull + uint64_t(mi[i] + 1);
	}
	for (int32_t i = 0; i < w; ++i) {
		key = key * 1099511628211ull + uint64_t(wi[i] + 1) * 97;
	}
	ArchMatch &entry = _arch_cache[key];
	if (entry.scanned > uint32_t(archetypes_.size())) {
		// 防御: archetypes_ 若有收缩(当前不会), 退回全量重扫
		entry.scanned = 0;
		entry.ids.clear();
	}
	for (uint32_t arch = entry.scanned; arch < uint32_t(archetypes_.size()); ++arch) {
		const auto &a = archetypes_[arch];
		if (!a.has_comp(ai)) {
			continue;
		}
		bool ok = true;
		for (int32_t i = 0; i < m; ++i) {
			if (!a.has_comp(mi[i])) {
				ok = false;
				break;
			}
		}
		if (ok) {
			for (int32_t i = 0; i < w; ++i) {
				if (a.has_comp(wi[i])) {
					ok = false;
					break;
				}
			}
		}
		if (ok) {
			entry.ids.push_back(int32_t(arch));
		}
	}
	entry.scanned = uint32_t(archetypes_.size());
	return entry.ids;
}

// 含某组件的全部 archetype(无过滤), 与 collect_archs 共用同一套增量缓存
const std::vector<int32_t> &ECSCore::archs_with(int32_t ci) const {
	return collect_archs(ci, nullptr, 0, nullptr, 0);
}

int32_t ECSCore::allocate_entity_id() {
	// 优先复用空闲 ID(数值接近的复用, 保持聚簇)
	if (!free_list_.empty()) {
		int32_t index = free_list_.back();
		free_list_.pop_back();
		return index;
	}
	if (int32_t(versions_.size()) > ECS_INDEX_MASK) {
		return -1; // 实体槽耗尽(上限 1,048,575), 由 create_entity 转成 -1 返回
	}
	int32_t index = int32_t(versions_.size());
	versions_.push_back(0);
	return index;
}

void ECSCore::release_entity_id(int32_t index) {
	// 与 id 里的代数位宽同步回绕: 不回绕的话 versions_ 会涨到 256/2048 之外,
	// 而 id 只存低位, 掩码比较永远不相等 → 活实体被判死。
	versions_[index] = (versions_[index] + 1) & ECS_VERSION_MASK;
	free_list_.push_back(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 组件注册
// ---------------------------------------------------------------------------

int32_t ECSCore::register_component(const StringName &name, const PackedStringArray &fnames,
		const PackedInt32Array &ftypes, const Array &fdefaults) {
	// 幂等: 已注册要返回**已有下标**。早先这里返回 components_.size()(下一个空位),
	// 调用方把它当 index 用就会指向越界位置 —— 内部标记组件(__prefab)正是被这个
	// 静默跳过, 表现为"注册成功但标记永远挂不上"。
	if (const ECSComponentData *existing = find_comp(name)) {
		return int32_t(existing - components_.data());
	}
	const int32_t n = int32_t(fnames.size());
	ECSComponentData data;
	data.name = name;
	data.fields.resize(n);
	data.defaults.resize(n);
	for (int32_t i = 0; i < n; ++i) {
		data.fields[i].name = fnames[i];
		data.fields[i].type = Variant::Type(int64_t(ftypes[i]));
		data.defaults[i] = (i < fdefaults.size()) ? fdefaults[i] : Variant();
	}
	// 名字 -> 下标索引: 只在注册期写一次, 之后所有线程只读(并行系统里查 comp_index 也安全)。
	// 哈希碰撞退化到线性扫描(comp_index 会先校验名字), 不会取错组件。
	component_index_[uint64_t(name.hash())] = int32_t(components_.size());
	components_.push_back(std::move(data));
	return int32_t(components_.size());
}

// ---------------------------------------------------------------------------
// ECSCore — 实体
// ---------------------------------------------------------------------------

int32_t ECSCore::create_entity() {
	const int32_t index = allocate_entity_id();
	if (index < 0) {
		return -1; // 实体槽耗尽(见 ECS_INDEX_MASK)
	}
	const int32_t version = int32_t(versions_[index]);
	if (int32_t(entity_arch_.size()) <= index) {
		entity_arch_.resize(index + 1, -1);
	}
	if (int32_t(entity_row_.size()) <= index) {
		entity_row_.resize(index + 1, -1);
	}
	entity_arch_[index] = -1; // 新实体无组件, 不属于任何 archetype
	entity_row_[index] = -1;
	++struct_version_;
	return (version << ECS_INDEX_BITS) | index;
}

bool ECSCore::is_alive(int32_t entity) const {
	if (entity < 0) {
		return false; // 负数是命令缓冲的占位句柄, 不是实体
	}
	const int32_t index = ecs_index_of(entity);
	if (index >= int32_t(versions_.size())) {
		return false;
	}
	// 比的是"掩码后的代数": versions_ 单调自增, id 里只存低位, 必须同口径比较
	return (int32_t(versions_[index]) & ECS_VERSION_MASK) == ecs_version_of(entity);
}

void ECSCore::destroy_entity(int32_t entity) {
	if (!is_alive(entity)) {
		return;
	}
	const int32_t index = ecs_index_of(entity);
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch >= 0) {
		remove_from_archetype(arch, index);
	}
	entity_arch_[index] = -1;
	entity_row_[index] = -1;
	// prefab 标记必须跟着清: 否则 id 被普通实体复用后, 该实体会在所有查询/序列化里永久隐身
	if (index < int32_t(prefab_bitmap_.size())) {
		prefab_bitmap_[index] = 0;
	}
	++struct_version_;
	release_entity_id(index);
}

// ---------------------------------------------------------------------------
// ECSCore — 组件增删查 (archetype 迁移)
// ---------------------------------------------------------------------------

bool ECSCore::add_component(int32_t entity, const StringName &comp) {
	const int32_t index = ecs_index_of(entity);
	const int32_t ci = comp_index(comp);
	if (ci < 0 || !is_alive(entity)) {
		return false;
	}
	const int32_t old_arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (old_arch >= 0 && archetypes_[old_arch].has_comp(ci)) {
		return true; // 幂等
	}
	// 迁移图边缓存(flecs "edge"): (源块, 组件) → 目标块, 命中就不必再扫全部块
	const uint64_t edge = (uint64_t(uint32_t(old_arch + 1)) << 32) | uint32_t(ci);
	int32_t dst;
	auto eit = arch_edge_add_.find(edge);
	if (eit != arch_edge_add_.end()) {
		dst = eit->second;
	} else {
		std::vector<int32_t> comps_new;
		if (old_arch >= 0) {
			comps_new = archetypes_[old_arch].comps;
		}
		sorted_insert(comps_new, ci);
		dst = find_archetype(comps_new);
		arch_edge_add_[edge] = dst;
	}
	migrate_entity(index, old_arch, dst);
	++struct_version_;
	return true;
}

bool ECSCore::has_component(int32_t entity, const StringName &comp) const {
	const int32_t index = ecs_index_of(entity);
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return false;
	}
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	return arch >= 0 && archetypes_[arch].has_comp(ci);
}

void ECSCore::remove_component(int32_t entity, const StringName &comp) {
	const int32_t index = ecs_index_of(entity);
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0 || !archetypes_[arch].has_comp(ci)) {
		return;
	}
	// 迁移图边缓存: 删除组件的目标块同样记住(-1 = 该组件组合为空, 直接出块)
	const uint64_t edge = (uint64_t(uint32_t(arch + 1)) << 32) | uint32_t(ci);
	int32_t dst;
	auto eit = arch_edge_remove_.find(edge);
	if (eit != arch_edge_remove_.end()) {
		dst = eit->second;
	} else {
		std::vector<int32_t> comps_new;
		for (int32_t c : archetypes_[arch].comps) {
			if (c != ci) {
				comps_new.push_back(c);
			}
		}
		dst = comps_new.empty() ? -1 : find_archetype(comps_new);
		arch_edge_remove_[edge] = dst;
	}
	if (dst < 0) {
		remove_from_archetype(arch, index);
		entity_arch_[index] = -1;
	} else {
		migrate_entity(index, arch, dst);
	}
	++struct_version_;
}

Array ECSCore::get_archetype_groups() const {
	Array out;
	for (const auto &a : archetypes_) {
		if (a.entities.empty()) {
			continue;
		}
		PackedStringArray comps;
		for (int32_t ci : a.comps) {
			comps.append(String(components_[ci].name));
		}
		PackedInt32Array ents;
		for (int32_t e : a.entities) {
			if (is_prefab_index(e)) {
				continue;
			}
			ents.append(e);
		}
		if (ents.is_empty()) {
			continue;
		}
		Dictionary g;
		g["comps"] = comps;
		g["entities"] = ents;
		out.append(g);
	}
	return out;
}

int32_t ECSCore::count_entities(const StringName &comp) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return 0;
	}
	int32_t n = 0;
	for (int32_t arch2 : archs_with(ci)) {
		const auto &a = archetypes_[arch2];
		for (int32_t e : a.entities) {
			if (!is_prefab_index(e)) {
				++n;
			}
		}
	}
	return n;
}

PackedStringArray ECSCore::get_entity_components(int32_t entity) const {
	PackedStringArray out;
	const int32_t index = ecs_index_of(entity);
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return out;
	}
	for (int32_t ci : archetypes_[arch].comps) {
		if (is_internal_comp(ci)) {
			continue;   // 内部标记组件不出现在 GDScript 视图里
		}
		out.append(components_[ci].name);
	}
	return out;
}

// ---------------------------------------------------------------------------
// ECSCore — 查询
// ---------------------------------------------------------------------------

PackedInt32Array ECSCore::query_entities(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	PackedInt32Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	int32_t mi[8];
	int32_t wi[8];
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		wi[i] = comp_index(without[i]);
	}
	// 只遍历匹配的 archetype 块(缓存后的列表, 不再全表重扫)
	for (int32_t arch : collect_archs(ai, mi, m, wi, w)) {
		const auto &a = archetypes_[arch];
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			out.append(a.entities[row]);
		}
	}
	return out;
}

PackedInt32Array ECSCore::query_rows(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	PackedInt32Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	int32_t mi[8];
	int32_t wi[8];
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		wi[i] = comp_index(without[i]);
	}
	// 偏移必须按"含 anchor 的全部块"累加(聚合行号口径), 匹配与否只影响是否输出
	int32_t offset = 0;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		const bool ok = arch_matches(a, mi, m, wi, w);
		int32_t n_nonpref = 0;
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			if (ok) {
				out.append(offset + n_nonpref);
			}
			++n_nonpref;
		}
		offset += n_nonpref;
	}
	return out;
}

// 对齐行号查询: 返回 [anchor 聚合行号, 各 must 组件聚合行号](同一实体集合, 顺序一致)。
Array ECSCore::query_rows_aligned(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without) const {
	Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	PackedInt32Array anchor_rows = query_rows(anchor, must, without);
	const int32_t n = int32_t(anchor_rows.size());
	out.push_back(anchor_rows);
	// anchor 聚合行号 -> 实体表(一次 O(N), 避免逐实体 get_entity_at O(N^2))
	std::vector<int32_t> agg;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	for (int32_t i = 0; i < m; ++i) {
		PackedInt32Array comp_rows;
		if (mi[i] < 0) {
			out.push_back(comp_rows);
			continue;
		}
		std::vector<int32_t> cg; // 实体 index -> 聚合行号(直接索引, 免哈希)
		int32_t grow = 0;
		for (int32_t arch2 : archs_with(mi[i])) {
			const auto &a = archetypes_[arch2];
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				const int32_t e = a.entities[r];
				if (is_prefab_index(e)) {
					continue;
				}
				if ((int32_t)cg.size() <= e) cg.resize(e + 1, -1);
				cg[e] = grow++;
			}
		}
		comp_rows.resize(n);
		for (int32_t k = 0; k < n; ++k) {
			const int32_t e = agg[anchor_rows[k]];
			comp_rows[k] = (e >= 0 && e < (int32_t)cg.size()) ? cg[e] : -1;
		}
		out.push_back(comp_rows);
	}
	return out;
}

// 聚合行号(某组件的 get_column 索引) -> 实体 ID
int32_t ECSCore::entity_of_row(const StringName &comp, int32_t row) const {
	return get_entity_at(comp, row);
}

// 实体 ID -> 聚合行号(该组件 get_column 索引)
int32_t ECSCore::row_of_entity(const StringName &comp, int32_t entity) const {
	const int32_t index = ecs_index_of(entity);
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return -1;
	}
	const int32_t ci = comp_index(comp);
	if (ci < 0 || !archetypes_[arch].has_comp(ci)) {
		return -1;
	}
	// 聚合行号 = 前面含 ci 的 archetype 非 prefab 数 + 块内非 prefab 位置(快: O(块数 + 块内))
	int32_t grow = 0;
	for (int32_t arch2 : archs_with(ci)) {
		const auto &a = archetypes_[arch2];
		if (&a == &archetypes_[arch]) {
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				if (a.entities[r] == index) {
					return grow;
				}
				++grow;
			}
			return -1;
		}
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (!is_prefab_index(a.entities[r])) {
				++grow;
			}
		}
	}
	return -1;
}

void ECSCore::set_change_detection(bool enabled) {
	change_detection_ = enabled;
}
bool ECSCore::is_change_detection() const {
	return change_detection_;
}

// 变更检测: 返回该组件所有"行版本 > since"的聚合行号
PackedInt32Array ECSCore::get_changed(const StringName &comp, int64_t since) const {
	PackedInt32Array out;
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return out;
	}
	int32_t grow = 0;
	for (int32_t arch2 : archs_with(ci)) {
		const auto &a = archetypes_[arch2];
		for (int32_t r = 0; r < (int32_t)a.entities.size(); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			if (a.row_ver[r] > since) {
				out.append(grow);
			}
			++grow;
		}
	}
	return out;
}

// 聚合行号 -> 实体 ID(跨块按 archetype 顺序)
int32_t ECSCore::get_entity_at(const StringName &comp, int32_t row) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return -1;
	}
	int32_t grow = 0;
	for (int32_t arch2 : archs_with(ci)) {
		const auto &a = archetypes_[arch2];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			if (grow == row) {
				return a.entities[r];
			}
			++grow;
		}
	}
	return -1;
}

// ---------------------------------------------------------------------------
// ECSCore — 单实体字段访问
// ---------------------------------------------------------------------------

Variant ECSCore::get_field(int32_t entity, const StringName &comp, const StringName &field) const {
	const int32_t index = ecs_index_of(entity);
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return Variant();
	}
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return Variant();
	}
	const auto &a = archetypes_[arch];
	const int cp = a.comp_pos(ci);
	if (cp < 0) {
		return Variant();
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return Variant();
	}
	const int32_t row = row_of(index);
	if (row < 0) {
		return Variant();
	}
	return a.col_at(cp, fi).get(row);
}

void ECSCore::set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value) {
	const int32_t index = ecs_index_of(entity);
	const int32_t arch = (index < int32_t(entity_arch_.size())) ? entity_arch_[index] : -1;
	if (arch < 0) {
		return;
	}
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	auto &a = archetypes_[arch];
	const int cp = a.comp_pos(ci);
	if (cp < 0) {
		return;
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return;
	}
	// 字段序号可能超出**该块**为该组件分配的列数: 当组件定义在运行时变得更宽(或块是旧布局)时,
	// 只判 cp/fi 还不够, col_at(cp, fi) 会按 col_off 越界。这里再守一道(纯比较, 无跨语言成本),
	// 并把"API 误用"报一次而不是每帧刷屏。
	if (fi >= a.col_count(int32_t(cp))) {
		static std::unordered_set<uint64_t> warned;
		const uint64_t key = (uint64_t(uint32_t(ci)) << 32) | uint64_t(uint32_t(fi));
		if (warned.insert(key).second) {
			ERR_PRINT(vformat("ECS: set_field 字段超出块列范围 comp=%s field=%s (fi=%d, cols=%d) —— 已忽略",
					comp, field, fi, a.col_count(int32_t(cp))));
		}
		return;
	}
	const int32_t row = row_of(index);
	if (row < 0) {
		return;
	}
	if (change_detection_) a.row_ver[size_t(row)] = ++write_tick_;
	a.col_at(cp, fi).set(row, value);
}

// ---------------------------------------------------------------------------
// ECSCore — 批量列访问 (零拷贝)
// ---------------------------------------------------------------------------

// 跨块列聚合: 含 ci 的 archetype 块按序拼接非 prefab 实体值(get_column 索引 = 聚合顺序)
// 把"跳过 prefab 行"的那些**连续段**整段 memcpy 出来(O(段数) 次拷贝)。
// prefab 通常只有 1 个实体 ⇒ 段数≈2; 逐个取值则是每行一次类型分支 + Variant 装箱。
// 这是"模板与实例同块"唯一代价的可接受解法: 不引入额外标记组件(那会在编辑器启动期注册, 实测不稳)。
template <typename IsPref>
static size_t ecs_copy_runs(uint8_t *dst, const uint8_t *src, size_t elem_size, size_t n, IsPref is_pref) {
	size_t r = 0;
	size_t out = 0;
	while (r < n) {
		if (is_pref(r)) {
			++r;
			continue;
		}
		size_t run = 0;
		while (r + run < n && !is_pref(r + run)) {
			++run;
		}
		memcpy(dst + out * elem_size, src + r * elem_size, run * elem_size);
		out += run;
		r += run;
	}
	return out;
}

// 块内是否含 prefab 行(带缓存): 每列聚合都会问一次, 无缓存时退化成 O(行数)/列。
bool ECSCore::arch_has_prefab(int32_t arch, const Archetype &a) const {
	if (prefab_flag_ver_ != struct_version_ || prefab_flag_.size() != archetypes_.size()) {
		prefab_flag_.assign(archetypes_.size(), -1);
		prefab_flag_ver_ = struct_version_;
	}
	int8_t &f = prefab_flag_[size_t(arch)];
	if (f < 0) {
		f = 0;
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				f = 1;
				break;
			}
		}
	}
	return f == 1;
}

// prefab 行位置缓存: 结构版本变了才重算(一次扫全部块), 之后每列都是 O(prefab 个数) 切段。
const ECSCore::ArchPrefabInfo &ECSCore::arch_prefab_info(int32_t arch, const Archetype &a) const {
	std::lock_guard<std::mutex> lock(arch_cache_mutex_);
	if (prefab_info_ver_ != struct_version_ || prefab_info_.size() != archetypes_.size()) {
		prefab_info_.assign(archetypes_.size(), ArchPrefabInfo());
		for (size_t i = 0; i < archetypes_.size(); ++i) {
			const Archetype &ar = archetypes_[i];
			ArchPrefabInfo &info = prefab_info_[i];
			info.rows.clear();
			for (int32_t r = 0; r < int32_t(ar.entities.size()); ++r) {
				if (is_prefab_index(ar.entities[r])) {
					info.rows.push_back(r);
				}
			}
			info.non_prefab = int32_t(ar.entities.size()) - int32_t(info.rows.size());
		}
		prefab_info_ver_ = struct_version_;
	}
	return prefab_info_[size_t(arch)];
}

// 按"跳过这些行号"切段整拷。skip 升序(来自 arch_prefab_info), 段数 = skip 数 + 1。
static size_t ecs_copy_runs_skip(uint8_t *dst, const uint8_t *src, size_t elem, size_t n,
		const std::vector<int32_t> &skip) {
	size_t out = 0;
	size_t prev = 0;
	for (int32_t s : skip) {
		const size_t row = size_t(s);
		if (row > prev) {
			const size_t run = row - prev;
			memcpy(dst + out * elem, src + prev * elem, run * elem);
			out += run;
		}
		prev = row + 1;
	}
	if (prev < n) {
		const size_t run = n - prev;
		memcpy(dst + out * elem, src + prev * elem, run * elem);
		out += run;
	}
	return out;
}

// 跨块列聚合: 含 ci 的 archetype 块按序拼接非 prefab 实体值(get_column 索引 = 聚合顺序)
Variant ECSCore::column_aggregate(int32_t ci, int32_t fi) const {
	const Variant::Type t = components_[ci].fields[fi].type;
	struct Blk {
		const Archetype *a;
		int cp;
		int32_t arch;
	};
	std::vector<Blk> blocks;
	size_t total = 0;
	for (int32_t arch2 : archs_with(ci)) {
		const auto &a = archetypes_[arch2];
		const int cp = a.comp_pos(ci);
		// 非 prefab 行数直接取缓存(早先在这里现扫一遍, 每列一次 → 5 列 = 10 万次判定)
		const int32_t cnt = arch_prefab_info(arch2, a).non_prefab;
		if (cnt > 0) {
			blocks.push_back({&a, cp, arch2});
			total += size_t(cnt);
		}
	}
	switch (t) {
		case Variant::INT: {
			PackedInt32Array a;
			a.resize(int32_t(total));
			int32_t *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const int32_t *col = b.a->col_at(b.cp, fi).ptr<int32_t>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn * sizeof(int32_t));
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a;
			a.resize(int32_t(total));
			float *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const float *col = b.a->col_at(b.cp, fi).ptr<float>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn * sizeof(float));
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::BOOL: {
			PackedByteArray a;
			a.resize(int32_t(total));
			uint8_t *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const uint8_t *col = b.a->col_at(b.cp, fi).ptr<uint8_t>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn);
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a;
			a.resize(int32_t(total));
			Vector2 *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const Vector2 *col = b.a->col_at(b.cp, fi).ptr<Vector2>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn * sizeof(Vector2));
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a;
			a.resize(int32_t(total));
			Vector3 *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const Vector3 *col = b.a->col_at(b.cp, fi).ptr<Vector3>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn * sizeof(Vector3));
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a;
			a.resize(int32_t(total));
			Vector4 *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const Vector4 *col = b.a->col_at(b.cp, fi).ptr<Vector4>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn * sizeof(Vector4));
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::COLOR: {
			PackedColorArray a;
			a.resize(int32_t(total));
			Color *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const Color *col = b.a->col_at(b.cp, fi).ptr<Color>(); const size_t cn = b.a->col_at(b.cp, fi).size();
				if (!arch_has_prefab(b.arch, *b.a)) {
					memcpy(dst + idx, col, cn * sizeof(Color));
					idx += cn;
				} else {
					idx += ecs_copy_runs_skip(reinterpret_cast<uint8_t *>(dst) + idx * sizeof(*col),
							reinterpret_cast<const uint8_t *>(col), sizeof(*col), cn,
							arch_prefab_info(b.arch, *b.a).rows);
				}
			}
			return a;
		}
		case Variant::STRING: {
			PackedStringArray a;
			a.resize(int32_t(total));
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->col_at(b.cp, fi).s;
				for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
					if (is_prefab_index(b.a->entities[r])) {
						continue;
					}
					a.set(int32_t(idx++), col[r]);
				}
			}
			return a;
		}
		default:
			return Variant();
	}
}

// 跨块列拆回: 聚合 PackedArray 按序写回各块(与 column_aggregate 顺序一致)
// 从 Packed 数组取第 k 个元素。
// ⚠ 必须按 **Packed 数组类型** 分支: 传进来的是 PackedVector2Array 等, 其 get_type() 是
// PACKED_*_ARRAY, 不是字段类型 VECTOR2 —— 早先按字段类型分支时永远落空, 值全写成 null,
// 表现为"set_columns_of 之后整列变 0"(而且不报错)。与 agg_at 之前修的是同一类错误。
static Variant ecs_value_at(const Variant &v, size_t k) {
	switch (v.get_type()) {
		case Variant::PACKED_INT32_ARRAY: {
			PackedInt32Array p = v;
			return k < size_t(p.size()) ? Variant(int64_t(p[int32_t(k)])) : Variant();
		}
		case Variant::PACKED_FLOAT32_ARRAY: {
			PackedFloat32Array p = v;
			return k < size_t(p.size()) ? Variant(double(p[int32_t(k)])) : Variant();
		}
		case Variant::PACKED_BYTE_ARRAY: {
			PackedByteArray p = v;
			return k < size_t(p.size()) ? Variant(bool(p[int32_t(k)])) : Variant();
		}
		case Variant::PACKED_VECTOR2_ARRAY: {
			PackedVector2Array p = v;
			return k < size_t(p.size()) ? Variant(p[int32_t(k)]) : Variant();
		}
		case Variant::PACKED_VECTOR3_ARRAY: {
			PackedVector3Array p = v;
			return k < size_t(p.size()) ? Variant(p[int32_t(k)]) : Variant();
		}
		case Variant::PACKED_VECTOR4_ARRAY: {
			PackedVector4Array p = v;
			return k < size_t(p.size()) ? Variant(p[int32_t(k)]) : Variant();
		}
		case Variant::PACKED_COLOR_ARRAY: {
			PackedColorArray p = v;
			return k < size_t(p.size()) ? Variant(p[int32_t(k)]) : Variant();
		}
		case Variant::PACKED_STRING_ARRAY: {
			PackedStringArray p = v;
			return k < size_t(p.size()) ? Variant(p[int32_t(k)]) : Variant();
		}
		default:
			return Variant();
	}
}

// Packed 数组元素个数(长度校验用): 不校验就会越界读 —— memcpy 拿 col.size() 当源长度,
// 调用方传短数组时读到堆外。这里只做"够不够"的判断, 不做类型转换。
static int32_t ecs_value_count(const Variant &v) {
	switch (v.get_type()) {
		case Variant::PACKED_INT32_ARRAY:
			return PackedInt32Array(v).size();
		case Variant::PACKED_FLOAT32_ARRAY:
			return PackedFloat32Array(v).size();
		case Variant::PACKED_BYTE_ARRAY:
			return PackedByteArray(v).size();
		case Variant::PACKED_VECTOR2_ARRAY:
			return PackedVector2Array(v).size();
		case Variant::PACKED_VECTOR3_ARRAY:
			return PackedVector3Array(v).size();
		case Variant::PACKED_VECTOR4_ARRAY:
			return PackedVector4Array(v).size();
		case Variant::PACKED_COLOR_ARRAY:
			return PackedColorArray(v).size();
		case Variant::PACKED_STRING_ARRAY:
			return PackedStringArray(v).size();
		default:
			return 0;
	}
}

// 按 prefab 行切段, 把 Packed 数组整段写进列(同类型等宽 → memcpy)。
// skip 升序(prefab 行号); idx 是"已消费的源元素数"(跨块累计)。
template <typename T, typename PackedT>
static void ecs_scatter_runs(godot::ECSColumn &col, const Variant &values, size_t &idx,
		const std::vector<int32_t> &skip) {
	PackedT src = values;   // COW: 共享底层缓冲, 不复制数据
	const T *sp = src.ptr();
	T *dp = col.ptr<T>();
	const size_t n = col.size();
	size_t prev = 0;
	for (int32_t s : skip) {
		const size_t row = size_t(s);
		if (row > prev) {
			const size_t run = row - prev;
			memcpy(dp + prev, sp + idx, run * sizeof(T));
			idx += run;
		}
		prev = row + 1;
	}
	if (prev < n) {
		const size_t run = n - prev;
		memcpy(dp + prev, sp + idx, run * sizeof(T));
		idx += run;
	}
}

void ECSCore::column_scatter(int32_t ci, int32_t fi, const Variant &values) {
	const Variant::Type t = components_[ci].fields[fi].type;
	size_t idx = 0;
	// ⚠ 早先这里有个 has_pref(a) 每列扫全块 + 慢路径逐行 ecs_value_at(每行都重新拷一次 Packed 数组),
	// 实测 20k × 1 列 = **49ms**(无 prefab 时 16µs) —— 每帧写位置列会直接把帧率打穿。
	// 现在: prefab 行位置走 arch_prefab_info 缓存, 写回按段整拷。
	for (int32_t arch_i = 0; arch_i < int32_t(archetypes_.size()); ++arch_i) {
		auto &a = archetypes_[size_t(arch_i)];
		if (!a.has_comp(ci)) {
			continue;
		}
		const int cp = a.comp_pos(ci);
		auto &col = a.col_at(cp, fi);
		const size_t cn = col.size();   // 本块行数(memcpy 的目标长度)
		const ArchPrefabInfo &info = arch_prefab_info(arch_i, a);
		const std::vector<int32_t> &pref_rows = info.rows;
		const int32_t have = ecs_value_count(values);
		// 长度校验只比"**非 prefab 行数**": prefab 行不消费源数据。
		// ⚠ 早先拿 col.size()(含 prefab 行)比源数组 → 模板块永远"源不够长" → 恒走逐行兜底,
		// 而兜底里每行还重算 ecs_value_count(values) → 实测 20k 一行 set_columns_of 要 44ms。
		if (idx + size_t(info.non_prefab) > size_t(have)) {
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				const Variant v = idx < size_t(have)
						? ecs_value_at(values, idx)
						: components_[ci].defaults[fi];
				col.set(r, v);
				++idx;
			}
			continue;
		}
		if (pref_rows.empty()) {
			switch (t) {
				case Variant::INT: {
					PackedInt32Array p = values;
					memcpy(col.ptr<int32_t>(), p.ptr() + idx, col.size() * sizeof(int32_t));
					idx += cn;
					break;
				}
				case Variant::FLOAT: {
					PackedFloat32Array p = values;
					memcpy(col.ptr<float>(), p.ptr() + idx, col.size() * sizeof(float));
					idx += cn;
					break;
				}
				case Variant::BOOL: {
					PackedByteArray p = values;
					memcpy(col.ptr<uint8_t>(), p.ptr() + idx, col.size());
					idx += cn;
					break;
				}
				case Variant::VECTOR2: {
					PackedVector2Array p = values;
					memcpy(col.ptr<Vector2>(), p.ptr() + idx, col.size() * sizeof(Vector2));
					idx += cn;
					break;
				}
				case Variant::VECTOR3: {
					PackedVector3Array p = values;
					memcpy(col.ptr<Vector3>(), p.ptr() + idx, col.size() * sizeof(Vector3));
					idx += cn;
					break;
				}
				case Variant::VECTOR4: {
					PackedVector4Array p = values;
					memcpy(col.ptr<Vector4>(), p.ptr() + idx, col.size() * sizeof(Vector4));
					idx += cn;
					break;
				}
				case Variant::COLOR: {
					PackedColorArray p = values;
					memcpy(col.ptr<Color>(), p.ptr() + idx, col.size() * sizeof(Color));
					idx += cn;
					break;
				}
				default: {
					for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
						col.set(r, ecs_value_at(values, idx));
						++idx;
					}
					break;
				}
			}
		} else {
			// 慢路径: 块内含 prefab(instantiate 就追加在模板块里, 所以这是**常态**)。
			// 按 prefab 行把源数组切成若干段整拷; 只有 STRING/类型不匹配才退回逐行 Variant。
			bool done = true;
			switch (t) {
				case Variant::INT:
					ecs_scatter_runs<int32_t, PackedInt32Array>(col, values, idx, pref_rows);
					break;
				case Variant::FLOAT:
					ecs_scatter_runs<float, PackedFloat32Array>(col, values, idx, pref_rows);
					break;
				case Variant::BOOL:
					ecs_scatter_runs<uint8_t, PackedByteArray>(col, values, idx, pref_rows);
					break;
				case Variant::VECTOR2:
					ecs_scatter_runs<godot::Vector2, PackedVector2Array>(col, values, idx, pref_rows);
					break;
				case Variant::VECTOR3:
					ecs_scatter_runs<godot::Vector3, PackedVector3Array>(col, values, idx, pref_rows);
					break;
				case Variant::VECTOR4:
					ecs_scatter_runs<godot::Vector4, PackedVector4Array>(col, values, idx, pref_rows);
					break;
				case Variant::COLOR:
					ecs_scatter_runs<godot::Color, PackedColorArray>(col, values, idx, pref_rows);
					break;
				default:
					done = false;
					break;
			}
			if (!done) {
				for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
					if (is_prefab_index(a.entities[r])) {
						continue;
					}
					col.set(r, ecs_value_at(values, idx));
					++idx;
				}
			}
		}
	}
}
void ECSCore::set_columns(const Dictionary &values) {
	Array keys = values.keys();
	for (int32_t i = 0; i < keys.size(); ++i) {
		const int32_t ci = comp_index(StringName(keys[i]));
		if (ci < 0) {
			continue;
		}
		Dictionary fields = values[keys[i]];
		Array fkeys = fields.keys();
		for (int32_t j = 0; j < fkeys.size(); ++j) {
			const StringName fname = StringName(fkeys[j]);
			const int32_t fi = components_[ci].field_index(fname);
			if (fi < 0) {
				continue;
			}
			column_scatter(ci, fi, fields[fname]);
		}
	}
}


Variant ECSCore::get_column(const StringName &comp, const StringName &field) const {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return Variant();
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return Variant();
	}
	return column_aggregate(ci, fi);
}

Dictionary ECSCore::get_columns(const Array &comps_fields) const {
	Dictionary out;
	for (int32_t i = 0; i < comps_fields.size(); ++i) {
		Dictionary cf = comps_fields[i];
		const int32_t ci = comp_index(StringName(cf["comp"]));
		if (ci < 0) {
			continue;
		}
		Dictionary fields_dict;
		Array fields = cf["fields"];
		for (int32_t j = 0; j < fields.size(); ++j) {
			const StringName fname = StringName(fields[j]);
			const int32_t fi = components_[ci].field_index(fname);
			if (fi < 0) {
				continue;
			}
			fields_dict[fname] = column_aggregate(ci, fi);
		}
		out[components_[ci].name] = fields_dict;
	}
	return out;
}

void ECSCore::set_column(const StringName &comp, const StringName &field, const Variant &values) {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int fi = components_[ci].field_index(field);
	if (fi < 0) {
		return;
	}
	column_scatter(ci, fi, values);
}

// 单实体标量/分量列操作(batch 用)
bool ECSCore::batch_apply_entity(int32_t entity, int32_t oci, int32_t ofi, int32_t op_axis,
		int64_t op, double factor, double addend) {
	const int32_t earch = entity_arch_[entity];
	if (earch < 0) {
		return false;
	}
	const int32_t erow = row_of(entity);
	if (erow < 0) {
		return false;
	}
	const int cp = archetypes_[earch].comp_pos(oci);
	if (cp < 0) {
		return false;
	}
	archetypes_[earch].row_ver[size_t(erow)] = ++write_tick_;
	auto &col = archetypes_[earch].col_at(cp, ofi);
	switch (col.type) {
		case Variant::INT: {
			int32_t &w = col.at<int32_t>(erow);
			switch (op) {
				case BATCH_ADD: w += int32_t(addend); break;
				case BATCH_MUL_ADD: w = int32_t(double(w) * factor + addend); break;
				case BATCH_SET: w = int32_t(addend); break;
				default: break;
			}
			break;
		}
		case Variant::FLOAT: {
			float &w = col.at<float>(erow);
			switch (op) {
				case BATCH_ADD: w += float(addend); break;
				case BATCH_MUL_ADD: w = float(double(w) * factor + addend); break;
				case BATCH_SET: w = float(addend); break;
				default: break;
			}
			break;
		}
		case Variant::VECTOR2: {
			if (op_axis >= 0 && op_axis < 2) {
				float &w = col.at<Vector2>(erow)[op_axis];
				switch (op) {
					case BATCH_ADD: w += float(addend); break;
					case BATCH_MUL_ADD: w = float(double(w) * factor + addend); break;
					case BATCH_SET: w = float(addend); break;
					default: break;
				}
			}
			break;
		}
		case Variant::VECTOR3: {
			if (op_axis >= 0 && op_axis < 3) {
				float &w = col.at<Vector3>(erow)[op_axis];
				switch (op) {
					case BATCH_ADD: w += float(addend); break;
					case BATCH_MUL_ADD: w = float(double(w) * factor + addend); break;
					case BATCH_SET: w = float(addend); break;
					default: break;
				}
			}
			break;
		}
		default:
			break;
	}
	return true;
}

// 单实体列间操作: op 列 = op 列 OP (src 列*factor+addend)
bool ECSCore::batch_apply_entity_col(int32_t entity, int32_t oci, int32_t ofi, int32_t sci, int32_t sfi,
		int64_t op, double factor, double addend) {
	const int32_t earch = entity_arch_[entity];
	if (earch < 0) {
		return false;
	}
	const int32_t erow = row_of(entity);
	if (erow < 0) {
		return false;
	}
	const int cp = archetypes_[earch].comp_pos(oci);
	const int scp = archetypes_[earch].comp_pos(sci);
	if (cp < 0 || scp < 0) {
		return false;
	}
	archetypes_[earch].row_ver[size_t(erow)] = ++write_tick_;
	auto &ocol = archetypes_[earch].col_at(cp, ofi);
	const auto &scol = archetypes_[earch].col_at(scp, sfi);
	if (ocol.type == Variant::FLOAT && (scol.type == Variant::FLOAT || scol.type == Variant::INT)) {
		const double sv = (scol.type == Variant::INT) ? double(scol.at<int32_t>(erow)) : double(scol.at<float>(erow));
		const float v = float(sv * factor + addend);
		float &w = ocol.at<float>(erow);
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v != 0.0f) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	if (ocol.type == Variant::INT && scol.type == Variant::INT) {
		const int32_t v = int32_t(double(scol.at<int32_t>(erow)) * factor + addend);
		int32_t &w = ocol.at<int32_t>(erow);
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v != 0) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2) {
		const float f = float(factor);
		Vector2 v = scol.at<Vector2>(erow) * f;
		Vector2 &w = ocol.at<Vector2>(erow);
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v.x != 0.0f && v.y != 0.0f) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	if (ocol.type == Variant::VECTOR3 && scol.type == Variant::VECTOR3) {
		const float f = float(factor);
		Vector3 v = scol.at<Vector3>(erow) * f;
		Vector3 &w = ocol.at<Vector3>(erow);
		switch (op) {
			case COL_ADD: w += v; break;
			case COL_SUB: w -= v; break;
			case COL_MUL: w *= v; break;
			case COL_DIV: if (v.x != 0.0f && v.y != 0.0f && v.z != 0.0f) w /= v; break;
			case COL_SET: w = v; break;
			default: break;
		}
		return true;
	}
	return false;
}

// 单实体是否满足全部条件(直接读 archetype 列, 快路径)
bool ECSCore::cond_matches_entity(int32_t entity, const std::vector<ECSFilterCond> &conds) const {
	for (const auto &c : conds) {
		if (c.comp == nullptr || c.field_idx < 0) {
			return false;
		}
		const int32_t arch = entity_arch_[entity];
		if (arch < 0) {
			return false;
		}
		const int32_t ci = c.comp_idx;
		if (ci < 0 || !archetypes_[arch].has_comp(ci)) {
			return false;
		}
		const int32_t row = row_of(entity);
		if (row < 0) {
			return false;
		}
		const int cp = archetypes_[arch].comp_pos(ci);
		if (cp < 0) {
			return false;
		}
		const auto &col = archetypes_[arch].col_at(cp, c.field_idx);
		double val = 0.0;
		switch (col.type) {
			case Variant::INT: val = double(col.at<int32_t>(row)); break;
			case Variant::FLOAT: val = double(col.at<float>(row)); break;
			case Variant::VECTOR2:
				if (c.axis >= 0 && c.axis < 2) val = double(col.at<Vector2>(row)[c.axis]);
				else return false;
				break;
			case Variant::VECTOR3:
				if (c.axis >= 0 && c.axis < 3) val = double(col.at<Vector3>(row)[c.axis]);
				else return false;
				break;
			default: return false;
		}
		switch (c.op) {
			case COND_LT: if (!(val < c.value)) return false; break;
			case COND_LE: if (!(val <= c.value)) return false; break;
			case COND_GT: if (!(val > c.value)) return false; break;
			case COND_GE: if (!(val >= c.value)) return false; break;
			case COND_EQ: if (!(val == c.value)) return false; break;
			case COND_NE: if (!(val != c.value)) return false; break;
			default: return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------
// 条件过滤解析(namespace)
// ---------------------------------------------------------------------------
namespace {
static void split_field_axis(const String &fn, String &base, int &axis) {
	axis = -1;
	int dot = fn.find(".");
	if (dot < 0) {
		base = fn;
		return;
	}
	base = fn.substr(0, dot);
	String ax = fn.substr(dot + 1);
	axis = ax == "x" ? 0 : ax == "y" ? 1 : ax == "z" ? 2 : -1;
}

int parse_conditions(const ECSCore *core, const Array &conds,
		std::vector<ECSFilterCond> &out, int max_conds) {
	out.clear();
	for (int i = 0; i < conds.size() && int(out.size()) < max_conds; ++i) {
		Dictionary d = conds[i];
		if (!d.has("comp") || !d.has("field")) {
			continue;
		}
		ECSFilterCond c;
		c.comp = core->find_comp(StringName(d["comp"]));
		if (c.comp == nullptr) {
			continue;
		}
		String fbase;
		split_field_axis(String(d["field"]), fbase, c.axis);
		c.field_idx = c.comp->field_index(StringName(fbase));
		if (c.field_idx < 0) {
			continue;
		}
		c.op = int64_t(d.get("op", int64_t(0)));
		c.value = double(d.get("value", 0.0));
		out.push_back(c);
	}
	return int(out.size());
}
// 从聚合 PackedArray(Variant) 取第 k 个值。
// ⚠ 必须按 **Packed 数组类型** 分支: column_aggregate 返回的是 PackedInt32Array 等,
// 它的 get_type() 是 PACKED_INT32_ARRAY 而**不是** Variant::INT —— 按字段类型分支会全部落空、
// 每个值都变成 null(存档只存下行号, 值全丢), 这是本函数此前的真实缺陷。
static Variant agg_at(const Variant &v, int32_t k) {
	switch (v.get_type()) {
		case Variant::PACKED_INT32_ARRAY: {
			PackedInt32Array p = v;
			return (k < p.size()) ? Variant(int64_t(p[k])) : Variant();
		}
		case Variant::PACKED_FLOAT32_ARRAY: {
			PackedFloat32Array p = v;
			return (k < p.size()) ? Variant(double(p[k])) : Variant();
		}
		case Variant::PACKED_BYTE_ARRAY: {
			PackedByteArray p = v;
			return (k < p.size()) ? Variant(bool(p[k])) : Variant();
		}
		case Variant::PACKED_VECTOR2_ARRAY: {
			PackedVector2Array p = v;
			return (k < p.size()) ? Variant(Vector2(p[k])) : Variant();
		}
		case Variant::PACKED_VECTOR3_ARRAY: {
			PackedVector3Array p = v;
			return (k < p.size()) ? Variant(Vector3(p[k])) : Variant();
		}
		case Variant::PACKED_VECTOR4_ARRAY: {
			PackedVector4Array p = v;
			return (k < p.size()) ? Variant(Vector4(p[k])) : Variant();
		}
		case Variant::PACKED_COLOR_ARRAY: {
			PackedColorArray p = v;
			return (k < p.size()) ? Variant(Color(p[k])) : Variant();
		}
		case Variant::PACKED_STRING_ARRAY: {
			PackedStringArray p = v;
			return (k < p.size()) ? Variant(p[k]) : Variant();
		}
		default:
			return Variant();
	}
}

// 把一条 Packed 列按 (块, 行, 组件位置) 批量写进目标列。
// 每字段只做**一次**类型分支并取到裸指针, 行内是纯下标写入 —— 逐行调用 agg_at 会因为
// 每次都要做 Variant→PackedArray 转换(引用计数)而慢 4 倍(实测 5.05µs/实体 → 目标 <1.5µs)。
// 源类型与目标列不符时不猜(写错 vector = 内存踩踏), 退化为写默认值。
static void ecs_write_rows(std::vector<godot::Archetype> &archs,
		const std::vector<int32_t> &tgt_arch, const std::vector<int32_t> &tgt_row,
		const std::vector<int32_t> &tgt_cp, int32_t fi, const godot::Variant &src,
		const godot::Variant &fallback) {
	const size_t n = tgt_arch.size();
	if (n == 0) {
		return;
	}
	const godot::Variant::Type want =
			archs[size_t(tgt_arch[0])].col_at(int(tgt_cp[0]), int(fi)).type;
#define ECS_WRITE_CASE(ENUM, TYPE, WANT, ELEM)                                                \
	case godot::Variant::ENUM: {                                                                \
		if (want == godot::Variant::WANT) {                                                     \
			const godot::TYPE p = src;                                                          \
			const auto *sp = p.ptr();                                                           \
			const int32_t sn = p.size();                                                        \
			for (size_t r = 0; r < n; ++r) {                                                    \
				const int32_t k = int32_t(r);                                                   \
				if (k < sn) {                                                                   \
					archs[size_t(tgt_arch[r])].col_at(int(tgt_cp[r]), int(fi))                  \
							.at<ELEM>(size_t(tgt_row[r])) = sp[r];                                \
				}                                                                               \
			}                                                                                   \
			return;                                                                             \
		}                                                                                       \
	} break;
	switch (src.get_type()) {
		ECS_WRITE_CASE(PACKED_INT32_ARRAY, PackedInt32Array, INT, int32_t)
		ECS_WRITE_CASE(PACKED_FLOAT32_ARRAY, PackedFloat32Array, FLOAT, float)
		ECS_WRITE_CASE(PACKED_BYTE_ARRAY, PackedByteArray, BOOL, uint8_t)
		ECS_WRITE_CASE(PACKED_VECTOR2_ARRAY, PackedVector2Array, VECTOR2, Vector2)
		ECS_WRITE_CASE(PACKED_VECTOR3_ARRAY, PackedVector3Array, VECTOR3, Vector3)
		ECS_WRITE_CASE(PACKED_VECTOR4_ARRAY, PackedVector4Array, VECTOR4, Vector4)
		ECS_WRITE_CASE(PACKED_COLOR_ARRAY, PackedColorArray, COLOR, Color)
		default:
			break;
	}
#undef ECS_WRITE_CASE
	// 兜底: 字符串列 / 类型不符 / 缺列 → 逐行 set(默认值或源值), 不猜内存布局
	const bool from_src = src.get_type() == godot::Variant::PACKED_STRING_ARRAY;
	for (size_t r = 0; r < n; ++r) {
		const godot::Variant v = from_src ? agg_at(src, int32_t(r)) : fallback;
		archs[size_t(tgt_arch[r])].col_at(int(tgt_cp[r]), int(fi)).set(size_t(tgt_row[r]),
				v.get_type() == godot::Variant::NIL ? fallback : v);
	}
}
} // namespace

// 收集满足 must/without/conditions 的 anchor 聚合行号(batch 用)
void ECSCore::collect_agg(int32_t ai, const int32_t *mi, int32_t m,
		const int32_t *wi, int32_t w, const Array &conditions,
		std::vector<int32_t> &out) const {
	out.clear();
	std::vector<ECSFilterCond> conds;
	parse_conditions(this, conditions, conds, 8);
	for (auto &c : conds) {
		if (c.comp) {
			c.comp_idx = comp_index(c.comp->name);
		}
	}
	int32_t offset = 0;
	const std::vector<int32_t> &archs = archs_with(ai);
	for (int32_t arch : archs) {
		const auto &a = archetypes_[arch];
		const bool ok = arch_matches(a, mi, m, wi, w);
		int32_t np = 0;
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			if (ok && cond_matches_entity(a.entities[row], conds)) {
				out.push_back(offset + np);
			}
			++np;
		}
		offset += np;
	}
}

// ---------------------------------------------------------------------------
// ECSCore — Tier 0: 原生批量运算 (archetype 分块)
// ---------------------------------------------------------------------------

int64_t ECSCore::batch_apply_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend, const Array &conditions) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	if (ai < 0 || oci < 0) {
		return 0;
	}
	String op_fbase;
	int op_axis;
	split_field_axis(String(op_field), op_fbase, op_axis);
	const int ofi = components_[oci].field_index(StringName(op_fbase));
	if (ofi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	std::vector<int32_t> agg;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	std::atomic<int64_t> cnt{0};
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			if (batch_apply_entity(agg[grow], oci, ofi, op_axis, op, factor, addend)) {
				cnt.fetch_add(1, std::memory_order_relaxed);
			}
		}
	}, 1.5);
	return cnt.load();
}

int64_t ECSCore::batch_count(const StringName &anchor, const PackedStringArray &must,
		const Array &conditions) const {
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	return int64_t(rows.size());
}

int64_t ECSCore::batch_apply(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend) {
	return batch_apply_where(anchor, must, op_comp, op_field, op, factor, addend, Array());
}

int64_t ECSCore::batch_apply_col(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &src_comp, const StringName &src_field,
		int64_t op, double factor, double addend, const Array &conditions) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	const int32_t sci = comp_index(src_comp);
	if (ai < 0 || oci < 0 || sci < 0) {
		return 0;
	}
	const int ofi = components_[oci].field_index(op_field);
	const int sfi = components_[sci].field_index(src_field);
	if (ofi < 0 || sfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	std::vector<int32_t> agg;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	std::atomic<int64_t> cnt{0};
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			if (batch_apply_entity_col(agg[grow], oci, ofi, sci, sfi, op, factor, addend)) {
				cnt.fetch_add(1, std::memory_order_relaxed);
			}
		}
	}, 1.5);
	return cnt.load();
}

int64_t ECSCore::batch_apply_rows(const StringName &anchor, const PackedInt32Array &rows,
		const StringName &op_comp, const StringName &op_field, int64_t op,
		double factor, double addend) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	if (ai < 0 || oci < 0) {
		return 0;
	}
	String op_fbase;
	int op_axis;
	split_field_axis(String(op_field), op_fbase, op_axis);
	const int ofi = components_[oci].field_index(StringName(op_fbase));
	if (ofi < 0) {
		return 0;
	}
	static thread_local std::vector<int32_t> agg; agg.clear();
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	const int32_t cnt = int32_t(rows.size());
	parallel_for(size_t(cnt), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			batch_apply_entity(agg[grow], oci, ofi, op_axis, op, factor, addend);
		}
	}, 1.5);
	return cnt;
}

int64_t ECSCore::batch_apply_col_rows(const StringName &anchor, const PackedInt32Array &rows,
		const StringName &op_comp, const StringName &op_field,
		const StringName &src_comp, const StringName &src_field,
		int64_t op, double factor, double addend) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	const int32_t sci = comp_index(src_comp);
	if (ai < 0 || oci < 0 || sci < 0) {
		return 0;
	}
	const int ofi = components_[oci].field_index(op_field);
	const int sfi = components_[sci].field_index(src_field);
	if (ofi < 0 || sfi < 0) {
		return 0;
	}
	const int32_t cnt = int32_t(rows.size());
	if (cnt <= 0) {
		return 0;
	}
	// SIMD 快路径: 单块 + 全量连续 + 同组件 VECTOR2/FLOAT ADD/SET(参考 Flecs 内循环直算)
	// 仅 x86/x64 + SSE2 可用; 其他架构(如 Apple Silicon)自动走下方通用路径
#if defined(ECS_SIMD_SSE2)
	bool full = (cnt > 0) && rows[0] == 0 && rows[cnt - 1] == cnt - 1;
	int32_t narch = 0;
	int32_t only_arch = -1;
	for (int32_t arch = 0; arch < (int32_t)archetypes_.size(); ++arch) {
		if (archetypes_[arch].has_comp(ai)) {
			++narch;
			only_arch = arch;
		}
	}
	if (full && narch == 1 && oci == sci && (op == COL_ADD || op == COL_SET)) {
		auto &a = archetypes_[only_arch];
		int32_t np = 0;
		for (int32_t r = 0; r < (int32_t)a.entities.size(); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			++np;
		}
		if (np == cnt) {
			const int cp = a.comp_pos(oci);
			const int scp = a.comp_pos(sci);
			if (cp >= 0 && scp >= 0) {
				auto &ocol = a.col_at(cp, ofi);
				auto &scol = a.col_at(scp, sfi);
				if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2 && op == COL_ADD) {
					float *w = reinterpret_cast<float *>(ocol.ptr<Vector2>());
					const float *s = reinterpret_cast<const float *>(scol.ptr<Vector2>());
					const float f = float(factor);
					const __m128 fv = _mm_set1_ps(f);
					parallel_for(size_t(cnt), [&](size_t b, size_t e) {
						size_t i = b;
						for (; i + 2 <= e; i += 2) {
							const __m128 pv = _mm_loadu_ps(w + i * 2);
							const __m128 sv = _mm_loadu_ps(s + i * 2);
							_mm_storeu_ps(w + i * 2, _mm_add_ps(pv, _mm_mul_ps(sv, fv)));
						}
						for (; i < e; ++i) {
							ocol.at<Vector2>(i) += scol.at<Vector2>(i) * f;
						}
					}, 3.0);
					return cnt;
				}
				if (ocol.type == Variant::FLOAT && scol.type == Variant::FLOAT
						&& (op == COL_ADD || op == COL_SET)) {
					float *w = ocol.ptr<float>();
					const float *s = scol.ptr<float>();
					const float f = float(factor);
					const float av = float(addend);
					const __m128 fv = _mm_set1_ps(f);
					const __m128 avv = _mm_set1_ps(av);
					parallel_for(size_t(cnt), [&](size_t b, size_t e) {
						size_t i = b;
						if (op == COL_ADD) {
							for (; i + 4 <= e; i += 4) {
								const __m128 sv = _mm_loadu_ps(s + i);
								const __m128 val = _mm_add_ps(_mm_mul_ps(sv, fv), avv);
								_mm_storeu_ps(w + i, _mm_add_ps(_mm_loadu_ps(w + i), val));
							}
							for (; i < e; ++i) {
								w[i] += s[i] * f + av;
							}
						} else {
							for (; i + 4 <= e; i += 4) {
								const __m128 sv = _mm_loadu_ps(s + i);
								_mm_storeu_ps(w + i, _mm_add_ps(_mm_mul_ps(sv, fv), avv));
							}
							for (; i < e; ++i) {
								w[i] = s[i] * f + av;
							}
						}
					}, 1.5);
					return cnt;
				}
				if (ocol.type == Variant::FLOAT && scol.type == Variant::INT && op == COL_ADD) {
					float *w = ocol.ptr<float>();
					const int32_t *s = scol.ptr<int32_t>();
					const float f = float(factor);
					const float av = float(addend);
					const __m128 fv = _mm_set1_ps(f);
					const __m128 avv = _mm_set1_ps(av);
					parallel_for(size_t(cnt), [&](size_t b, size_t e) {
						size_t i = b;
						for (; i + 4 <= e; i += 4) {
							const __m128 sv = _mm_cvtepi32_ps(_mm_loadu_si128(reinterpret_cast<const __m128i *>(s + i)));
							const __m128 val = _mm_add_ps(_mm_mul_ps(sv, fv), avv);
							_mm_storeu_ps(w + i, _mm_add_ps(_mm_loadu_ps(w + i), val));
						}
						for (; i < e; ++i) {
							w[i] += float(double(s[i]) * factor + addend);
						}
					}, 1.5);
					return cnt;
				}
			}
		}
	}
#endif
	// 聚合行号 -> (archetype, 块内行) 表(一次 O(N)) + 每块聚合起始(thread_local 复用避免每帧分配)
	static thread_local std::vector<std::pair<int32_t, int32_t>> agg; agg.clear();
	static thread_local std::vector<int32_t> arch_list; arch_list.clear();
	static thread_local std::vector<int32_t> arch_base; arch_base.clear();
	int32_t off = 0;
	for (int32_t arch = 0; arch < (int32_t)archetypes_.size(); ++arch) {
		const auto &a = archetypes_[arch];
		if (!a.has_comp(ai)) {
			continue;
		}
		arch_list.push_back(arch);
		arch_base.push_back(off);
		for (int32_t r = 0; r < (int32_t)a.entities.size(); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.emplace_back(arch, r);
			++off;
		}
	}
	// 块级并行: 外循环 archetype(每块一个任务), 内循环该块匹配行直接列访问(无实体间接)
	parallel_for(size_t(arch_list.size()), [&](size_t ab, size_t ae) {
		for (size_t k = ab; k < ae; ++k) {
			const int32_t arch = arch_list[k];
			const int32_t base = arch_base[k];
			auto &a = archetypes_[arch];
			const int cp = a.comp_pos(oci);
			const int scp = a.comp_pos(sci);
			if (cp < 0 || scp < 0) {
				continue;
			}
			auto &ocol = a.col_at(cp, ofi);
			auto &scol = a.col_at(scp, sfi);
			// 该块聚合行号上界
			int32_t top = (k + 1 < arch_list.size()) ? arch_base[k + 1] : off;
			// 收集该块匹配行(rows 单调, 二分起点)
			int32_t lo = 0;
			for (int32_t i = 0; i < cnt; ++i) {
				const int32_t grow = rows[i];
				if (grow < base) {
					continue;
				}
				if (grow >= top) {
					break;
				}
				const int32_t erow = grow - base; // 块内行(无 prefab 时 == agg[grow].second)
				if (change_detection_) a.row_ver[size_t(erow)] = ++write_tick_;
				// 直接列间操作(参考 batch_apply_entity_col, 无 entity_arch_/row_of 间接)
				if (ocol.type == Variant::FLOAT && (scol.type == Variant::FLOAT || scol.type == Variant::INT)) {
					const double sv = (scol.type == Variant::INT) ? double(scol.at<int32_t>(erow)) : double(scol.at<float>(erow));
					const float v = float(sv * factor + addend);
					float &w = ocol.at<float>(erow);
					switch (op) {
						case COL_ADD: w += v; break;
						case COL_SUB: w -= v; break;
						case COL_MUL: w *= v; break;
						case COL_DIV: if (v != 0.0f) w /= v; break;
						case COL_SET: w = v; break;
						default: break;
					}
				} else if (ocol.type == Variant::INT && scol.type == Variant::INT) {
					const int32_t v = int32_t(double(scol.at<int32_t>(erow)) * factor + addend);
					int32_t &w = ocol.at<int32_t>(erow);
					switch (op) {
						case COL_ADD: w += v; break;
						case COL_SUB: w -= v; break;
						case COL_MUL: w *= v; break;
						case COL_DIV: if (v != 0) w /= v; break;
						case COL_SET: w = v; break;
						default: break;
					}
				} else if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2) {
					const float f = float(factor);
					Vector2 v = scol.at<Vector2>(erow) * f;
					Vector2 &w = ocol.at<Vector2>(erow);
					switch (op) {
						case COL_ADD: w += v; break;
						case COL_SUB: w -= v; break;
						case COL_MUL: w *= v; break;
						case COL_DIV: if (v.x != 0.0f && v.y != 0.0f) w /= v; break;
						case COL_SET: w = v; break;
						default: break;
					}
				} else if (ocol.type == Variant::VECTOR3 && scol.type == Variant::VECTOR3) {
					const float f = float(factor);
					Vector3 v = scol.at<Vector3>(erow) * f;
					Vector3 &w = ocol.at<Vector3>(erow);
					switch (op) {
						case COL_ADD: w += v; break;
						case COL_SUB: w -= v; break;
						case COL_MUL: w *= v; break;
						case COL_DIV: if (v.x != 0.0f && v.y != 0.0f && v.z != 0.0f) w /= v; break;
						case COL_SET: w = v; break;
						default: break;
					}
				}
			}
		}
	}, 1.5);
	return cnt;
}
// 批量执行多个动作(一次跨语言, 免逐动作跨语言调用)
int64_t ECSCore::batch_apply_actions(const StringName &anchor, const PackedInt32Array &rows,
		const Array &actions) {
	int64_t total = 0;
	for (int32_t i = 0; i < actions.size(); ++i) {
		Dictionary a = actions[i];
		const int64_t t = int64_t(a["t"]);
		if (t == 0) {
			// col 列间
			const StringName sc = a.has("sc") ? StringName(a["sc"]) : anchor;
			total += batch_apply_col_rows(anchor, rows, anchor, StringName(a["of"]),
					sc, StringName(a["sf"]), int64_t(a["op"]),
					double(a["f"]), double(a["add"]));
		} else {
			// scalar 标量
			total += batch_apply_rows(anchor, rows, anchor, StringName(a["of"]),
					int64_t(a["op"]), double(a["f"]), double(a["v"]));
		}
	}
	return total;
}

Array ECSCore::batch_collect(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without, const Array &groups) const {
	Array out;
	if (groups.size() <= 0) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	int32_t mi[8];
	int32_t wi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w && i < 8; ++i) {
		wi[i] = comp_index(without[i]);
	}
	const int32_t ng = int32_t(groups.size());
	std::vector<std::vector<ECSFilterCond>> all_conds(ng);
	for (int32_t gi = 0; gi < ng; ++gi) {
		parse_conditions(this, groups[gi], all_conds[gi], 8);
		for (auto &c : all_conds[gi]) {
			if (c.comp) {
				c.comp_idx = comp_index(c.comp->name);
			}
		}
	}
	std::vector<PackedInt32Array> results(ng);
	int32_t offset = 0;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		const bool ok = arch_matches(a, mi, m > 8 ? 8 : m, wi, w > 8 ? 8 : w);
		int32_t np = 0;
		for (int32_t row = 0; row < int32_t(a.entities.size()); ++row) {
			if (is_prefab_index(a.entities[row])) {
				continue;
			}
			const int32_t e = a.entities[row];
			if (ok) {
				for (int32_t gi = 0; gi < ng; ++gi) {
					if (all_conds[gi].empty() || cond_matches_entity(e, all_conds[gi])) {
						results[gi].append(offset + np);
					}
				}
			}
			++np;
		}
		offset += np;
	}
	for (int32_t gi = 0; gi < ng; ++gi) {
		out.push_back(results[gi]);
	}
	return out;
}

// 带条件过滤的列钳制: 仅满足条件的实体 col = clamp(col, min, max)
int64_t ECSCore::batch_clamp_where(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field,
		const Array &conditions) {
	const int32_t ai = comp_index(anchor);
	const int32_t oci = comp_index(op_comp);
	const int32_t nci = comp_index(min_comp);
	const int32_t xci = comp_index(max_comp);
	if (ai < 0 || oci < 0 || nci < 0 || xci < 0) {
		return 0;
	}
	const int ofi = components_[oci].field_index(op_field);
	const int nfi = components_[nci].field_index(min_field);
	const int xfi = components_[xci].field_index(max_field);
	if (ofi < 0 || nfi < 0 || xfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, conditions, rows);
	std::vector<int32_t> agg;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	std::atomic<int64_t> cnt{0};
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			const int32_t en = agg[grow];
			const int32_t earch = entity_arch_[en];
			if (earch < 0) {
				continue;
			}
			const int32_t erow = row_of(en);
			if (erow < 0) {
				continue;
			}
			const int cp = archetypes_[earch].comp_pos(oci);
			const int ncp = archetypes_[earch].comp_pos(nci);
			const int xcp = archetypes_[earch].comp_pos(xci);
			if (cp < 0 || ncp < 0 || xcp < 0) {
				continue;
			}
			auto &ocol = archetypes_[earch].col_at(cp, ofi);
			const auto &minc = archetypes_[earch].col_at(ncp, nfi);
			const auto &maxc = archetypes_[earch].col_at(xcp, xfi);
			if (ocol.type == Variant::FLOAT && minc.type == Variant::FLOAT && maxc.type == Variant::FLOAT) {
				ocol.at<float>(erow) = std::clamp(ocol.at<float>(erow), minc.at<float>(erow), maxc.at<float>(erow));
			} else if (ocol.type == Variant::INT && minc.type == Variant::INT && maxc.type == Variant::INT) {
				ocol.at<int32_t>(erow) = std::clamp(ocol.at<int32_t>(erow), minc.at<int32_t>(erow), maxc.at<int32_t>(erow));
			}
			cnt.fetch_add(1, std::memory_order_relaxed);
		}
	}, 1.0);
	return cnt.load();
}

int64_t ECSCore::batch_clamp(const StringName &anchor, const PackedStringArray &must,
		const StringName &op_comp, const StringName &op_field,
		const StringName &min_comp, const StringName &min_field,
		const StringName &max_comp, const StringName &max_field) {
	return batch_clamp_where(anchor, must, op_comp, op_field,
			min_comp, min_field, max_comp, max_field, Array());
}

// 通用移动原语: pos += vel*delta, 越界回弹(vel 翻转, pos 钳制)
int64_t ECSCore::batch_vec_add(const StringName &anchor, const PackedStringArray &must,
		const StringName &pos_comp, const StringName &pos_field,
		const StringName &vel_comp, const StringName &vel_field, double delta) {
	const int32_t ai = comp_index(anchor);
	const int32_t pci = comp_index(pos_comp);
	const int32_t vci = comp_index(vel_comp);
	if (ai < 0 || pci < 0 || vci < 0) {
		return 0;
	}
	const int pfi = components_[pci].field_index(pos_field);
	const int vfi = components_[vci].field_index(vel_field);
	if (pfi < 0 || vfi < 0) {
		return 0;
	}
	const int32_t m = int32_t(must.size());
	int32_t mi[8];
	for (int32_t i = 0; i < m && i < 8; ++i) {
		mi[i] = comp_index(must[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m > 8 ? 8 : m, nullptr, 0, Array(), rows);
	std::vector<int32_t> agg;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	parallel_for(size_t(rows.size()), [&](size_t b, size_t e) {
		for (size_t i = b; i < e; ++i) {
			const int32_t grow = rows[i];
			if (grow < 0 || grow >= (int32_t)agg.size()) {
				continue;
			}
			const int32_t en = agg[grow];
			const int32_t earch = entity_arch_[en];
			if (earch < 0) {
				continue;
			}
			const int32_t erow = row_of(en);
			if (erow < 0) {
				continue;
			}
			const int pcp = archetypes_[earch].comp_pos(pci);
			const int vcp = archetypes_[earch].comp_pos(vci);
			if (pcp < 0 || vcp < 0) {
				continue;
			}
			auto &pcol = archetypes_[earch].col_at(pcp, pfi);
			const auto &vcol = archetypes_[earch].col_at(vcp, vfi);
			if (pcol.type == Variant::VECTOR2 && vcol.type == Variant::VECTOR2) {
				pcol.at<Vector2>(erow) += vcol.at<Vector2>(erow) * float(delta);
			} else if (pcol.type == Variant::VECTOR3 && vcol.type == Variant::VECTOR3) {
				pcol.at<Vector3>(erow) += vcol.at<Vector3>(erow) * float(delta);
			}
		}
	}, 3.0);
	return int64_t(rows.size());
}

Array ECSCore::query_rows_aligned_where(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without, const Array &conditions,
		const PackedStringArray &comps) const {
	Array out;
	if (must.size() > 8 || without.size() > 8) {
		return out;
	}
	const int32_t ai = comp_index(anchor);
	if (ai < 0) {
		return out;
	}
	const int32_t m = int32_t(must.size());
	const int32_t w = int32_t(without.size());
	int32_t mi[8];
	int32_t wi[8];
	for (int32_t i = 0; i < m; ++i) {
		mi[i] = comp_index(must[i]);
	}
	for (int32_t i = 0; i < w; ++i) {
		wi[i] = comp_index(without[i]);
	}
	std::vector<int32_t> rows;
	collect_agg(ai, mi, m, wi, w, conditions, rows);
	PackedInt32Array anchor_rows;
	anchor_rows.resize(int32_t(rows.size()));
	for (size_t k = 0; k < rows.size(); ++k) {
		anchor_rows.set(int32_t(k), rows[k]);
	}
	const int32_t n = int32_t(anchor_rows.size());
	out.push_back(anchor_rows);
	// anchor 聚合行号 -> 实体表(一次 O(N), 避免逐实体 get_entity_at O(N^2))
	std::vector<int32_t> agg;
	for (int32_t arch : archs_with(ai)) {
		const auto &a = archetypes_[arch];
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				continue;
			}
			agg.push_back(a.entities[r]);
		}
	}
	for (int32_t i = 0; i < int32_t(comps.size()) && i < 8; ++i) {
		const StringName cname = comps[i];
		const int32_t cci = comp_index(cname);
		PackedInt32Array cr;
		cr.resize(n);
		if (cci >= 0) {
			std::vector<int32_t> cg; // 实体 index -> 聚合行号(直接索引, 免哈希)
			int32_t grow = 0;
			for (int32_t arch2 : archs_with(cci)) {
				const auto &a = archetypes_[arch2];
				for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
					const int32_t e = a.entities[r];
					if (is_prefab_index(e)) {
						continue;
					}
					if ((int32_t)cg.size() <= e) cg.resize(e + 1, -1);
					cg[e] = grow++;
				}
			}
			for (int32_t k = 0; k < n; ++k) {
				const int32_t e = agg[anchor_rows[k]];
				cr[k] = (e >= 0 && e < (int32_t)cg.size()) ? cg[e] : -1;
			}
		}
		out.push_back(cr);
	}
	return out;
}

Dictionary ECSCore::debug_stats() const {
	Dictionary d;
	d["components"] = int64_t(components_.size());
	d["entity_pool"] = int64_t(versions_.size());
	d["threads"] = int64_t(thread_count_);
	d["workers_started"] = workers_started_;
	Array comp_counts;
	for (const auto &c : components_) {
		comp_counts.append(int64_t(count_entities(c.name)));
	}
	d["component_counts"] = comp_counts;
	return d;
}

// ---------------------------------------------------------------------------
// ECSCore — 序列化/反序列化
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 空间索引(统一网格): 格子 → 实体 id。脏时下一次查询整表重建(20k 约 1~2ms, 无写入的帧不重建)。
// GDScript 侧在 _mark_dirty(该组件) 时调 spatial_invalidate(), 所以写入与结构变更都能覆盖到。
// ---------------------------------------------------------------------------

void ECSCore::spatial_mark_dirty() {
	if (spatial_enabled_) {
		spatial_dirty_ = true;
	}
}

int64_t ECSCore::spatial_key(int32_t cx, int32_t cy) {
	return (int64_t(uint32_t(cx)) << 32) | int64_t(uint32_t(cy));
}

void ECSCore::spatial_enable(const StringName &comp, const StringName &field, double cell_size) {
	const int32_t ci = comp_index(comp);
	if (ci < 0) {
		return;
	}
	const int32_t fi = components_[ci].field_index(field);
	if (fi < 0 || components_[ci].fields[fi].type != Variant::VECTOR2) {
		return; // 只支持 2D 位置字段(3D 需要另一套键)
	}
	spatial_comp_ = ci;
	spatial_field_ = fi;
	spatial_cell_ = float(cell_size > 0.0 ? cell_size : 1.0);
	spatial_enabled_ = true;
	spatial_dirty_ = true;
}

void ECSCore::spatial_disable() {
	spatial_enabled_ = false;
	spatial_dirty_ = true;
	spatial_cells_.clear();
	spatial_built_entities_ = 0;
}

void ECSCore::spatial_rebuild() {
	spatial_dirty_ = false;
	spatial_cells_.clear();
	spatial_owner_.clear();
	spatial_built_entities_ = 0;
	if (!spatial_enabled_) {
		return;
	}
	const float cs = spatial_cell_ > 0.0f ? spatial_cell_ : 1.0f;
	for (int32_t arch : archs_with(spatial_comp_)) {
		Archetype &a = archetypes_[size_t(arch)];
		const int32_t cp = a.comp_pos(spatial_comp_);
		if (cp < 0) {
			continue;
		}
		const ECSColumn &col = a.col_at(size_t(cp), size_t(spatial_field_));
		if (col.type != Variant::VECTOR2) {
			continue;
		}
		const size_t n = a.entities.size();
		for (size_t r = 0; r < n; ++r) {
			const int32_t id = a.entities[r];
			if (is_prefab_index(id)) {
				continue;
			}
			const Vector2 p = col.at<Vector2>(r);
			const int32_t cx = int32_t(Math::floor(p.x / cs));
			const int32_t cy = int32_t(Math::floor(p.y / cs));
			const int64_t key = spatial_key(cx, cy);
			spatial_cells_[key].push_back(id);
			spatial_owner_[id] = key;
			++spatial_built_entities_;
		}
	}
}

void ECSCore::spatial_update_entity(int32_t id) {
	if (!spatial_enabled_ || spatial_dirty_) {
		return;   // 已脏: 下一次查询反正会整表重建, 单条增量没有意义
	}
	const int32_t idx = ecs_index_of(id);
	if (idx < 0 || idx >= int32_t(entity_arch_.size())) {
		return;
	}
	auto it = spatial_owner_.find(id);
	const int32_t arch = entity_arch_[size_t(idx)];
	if (arch < 0) {
		// 实体已不属于任何块: 从旧格子摘掉
		if (it != spatial_owner_.end()) {
			auto &vec = spatial_cells_[it->second];
			vec.erase(std::remove(vec.begin(), vec.end(), id), vec.end());
			spatial_owner_.erase(it);
		}
		return;
	}
	const int32_t cp = archetypes_[size_t(arch)].comp_pos(spatial_comp_);
	const int32_t row = row_of(idx);
	if (cp < 0 || row < 0) {
		return;
	}
	const float cs = spatial_cell_ > 0.0f ? spatial_cell_ : 1.0f;
	const Vector2 p = archetypes_[size_t(arch)].col_at(size_t(cp), size_t(spatial_field_)).at<Vector2>(size_t(row));
	const int64_t nk = spatial_key(int32_t(Math::floor(p.x / cs)), int32_t(Math::floor(p.y / cs)));
	if (it != spatial_owner_.end() && it->second == nk) {
		return;   // 同一格: 什么都不用做(绝大多数"小步移动"都是这种)
	}
	if (it != spatial_owner_.end()) {
		auto &vec = spatial_cells_[it->second];
		vec.erase(std::remove(vec.begin(), vec.end(), id), vec.end());
	}
	spatial_cells_[nk].push_back(id);
	spatial_owner_[id] = nk;
}

PackedInt32Array ECSCore::spatial_query_rect(const Vector2 &min_pos, const Vector2 &max_pos) {
	PackedInt32Array out;
	if (!spatial_enabled_) {
		return out;
	}
	if (spatial_dirty_) {
		spatial_rebuild();
	}
	const float cs = spatial_cell_ > 0.0f ? spatial_cell_ : 1.0f;
	const int32_t x0 = int32_t(Math::floor(min_pos.x / cs));
	const int32_t x1 = int32_t(Math::floor(max_pos.x / cs));
	const int32_t y0 = int32_t(Math::floor(min_pos.y / cs));
	const int32_t y1 = int32_t(Math::floor(max_pos.y / cs));
	std::vector<int32_t> hits;
	for (int32_t cx = x0; cx <= x1; ++cx) {
		for (int32_t cy = y0; cy <= y1; ++cy) {
			auto it = spatial_cells_.find(spatial_key(cx, cy));
			if (it == spatial_cells_.end()) {
				continue;
			}
			for (int32_t id : it->second) {
				const int32_t idx = ecs_index_of(id);
				if (idx < 0 || idx >= int32_t(entity_arch_.size())) {
					continue;
				}
				const int32_t arch = entity_arch_[size_t(idx)];
				if (arch < 0) {
					continue; // 已被移除(索引陈旧的那一格)
				}
				const int32_t cp = archetypes_[size_t(arch)].comp_pos(spatial_comp_);
				const int32_t row = row_of(idx);
				if (cp < 0 || row < 0) {
					continue;
				}
				const Vector2 p = archetypes_[size_t(arch)].col_at(size_t(cp), size_t(spatial_field_))
										  .at<Vector2>(size_t(row));
				if (p.x < min_pos.x || p.x > max_pos.x || p.y < min_pos.y || p.y > max_pos.y) {
					continue;      // 格子命中但点在矩形外
				}
				hits.push_back(id);
			}
		}
	}
	std::sort(hits.begin(), hits.end());   // 确定性: 同一帧同一查询必须同序
	out.resize(int32_t(hits.size()));
	int32_t *w = out.ptrw();
	for (size_t i = 0; i < hits.size(); ++i) {
		w[i] = hits[i];
	}
	return out;
}

PackedInt32Array ECSCore::spatial_query_radius(const Vector2 &center, double radius) {
	PackedInt32Array out;
	if (!spatial_enabled_ || radius <= 0.0) {
		return out;
	}
	const float r = float(radius);
	const Vector2 mn(center.x - r, center.y - r);
	const Vector2 mx(center.x + r, center.y + r);
	PackedInt32Array bbox = spatial_query_rect(mn, mx);
	const float r2 = r * r;
	std::vector<int32_t> hits;
	hits.reserve(size_t(bbox.size()));
	for (int32_t i = 0; i < bbox.size(); ++i) {
		const int32_t id = bbox[i];
		const int32_t idx = ecs_index_of(id);
		if (idx < 0 || idx >= int32_t(entity_arch_.size())) {
			continue;
		}
		const int32_t arch = entity_arch_[size_t(idx)];
		if (arch < 0) {
			continue;
		}
		const int32_t cp = archetypes_[size_t(arch)].comp_pos(spatial_comp_);
		const int32_t row = row_of(idx);
		if (cp < 0 || row < 0) {
			continue;
		}
		const Vector2 p = archetypes_[size_t(arch)].col_at(size_t(cp), size_t(spatial_field_))
								  .at<Vector2>(size_t(row));
		if (p.distance_squared_to(center) <= r2) {
			hits.push_back(id);
		}
	}
	out.resize(int32_t(hits.size()));
	int32_t *w = out.ptrw();
	for (size_t i = 0; i < hits.size(); ++i) {
		w[i] = hits[i];
	}
	return out;
}

Dictionary ECSCore::spatial_stats() {
	Dictionary d;
	d["enabled"] = spatial_enabled_;
	d["cells"] = int64_t(spatial_cells_.size());
	d["entities"] = int64_t(spatial_built_entities_);
	d["dirty"] = spatial_dirty_;
	d["cell_size"] = double(spatial_cell_);
	return d;
}

// 统一取"用于排序的数值键": 数值直接取, 向量取长度, 其它 = 0(保持稳定而非报错)。
double ecs_sort_key(const godot::ECSColumn &col, size_t row) {
	switch (col.type) {
		case godot::Variant::INT:
			return double(col.at<int32_t>(row));
		case godot::Variant::FLOAT:
			return double(col.at<float>(row));
		case godot::Variant::BOOL:
			return col.at<uint8_t>(row) ? 1.0 : 0.0;
		case godot::Variant::VECTOR2:
			return double(col.at<Vector2>(row).length());
		case godot::Variant::VECTOR3:
			return double(col.at<Vector3>(row).length());
		default:
			return 0.0;
	}
}

PackedInt32Array ECSCore::query_rows_sorted(const StringName &anchor, const PackedStringArray &must,
		const PackedStringArray &without, const StringName &field, bool descending) {
	PackedInt32Array rows = query_rows(anchor, must, without);
	const int32_t ci = comp_index(anchor);
	if (ci < 0 || rows.is_empty()) {
		return rows;
	}
	// field 为空 = "按实体 id 排序" —— 规范顺序: 不依赖块创建历史, 两端必然一致。
	// (块内行号虽然稳定, 但"先加后删过哪些组件"会影响块序, 跨端不可复现。)
	const int32_t fi = field.is_empty() ? -1 : components_[ci].field_index(field);
	if (field.is_empty()) {
		// 走下面的通用排序, 键统一取 0 → 等价于按 id 升序
	} else if (fi < 0) {
		return rows; // 字段不存在: 退化为按块内行号(仍然是确定的)
	}
	// 一次扫描建立 聚合行 → (排序键, 实体 id), 与 get_column 的行序完全一致
	std::vector<double> keys;
	std::vector<int32_t> ids;
	for (int32_t arch : archs_with(ci)) {
		Archetype &a = archetypes_[size_t(arch)];
		const int32_t cp = a.comp_pos(ci);
		if (cp < 0) {
			continue;
		}
		for (size_t r = 0; r < a.entities.size(); ++r) {
			const int32_t id = a.entities[r];
			if (is_prefab_index(id)) {
				continue;
			}
			keys.push_back(fi < 0 ? 0.0 : ecs_sort_key(a.col_at(size_t(cp), size_t(fi)), r));
			ids.push_back(id);
		}
	}
	struct RowKey {
		double key;
		int32_t row;
		int32_t id;
	};
	std::vector<RowKey> order;
	order.reserve(size_t(rows.size()));
	for (int32_t i = 0; i < rows.size(); ++i) {
		const int32_t row = rows[i];
		if (row < 0 || row >= int32_t(keys.size())) {
			continue;
		}
		order.push_back({ keys[size_t(row)], row, ids[size_t(row)] });
	}
	// 次键用实体 id: 同值时也必须是确定顺序(否则联机两端遍历顺序可能不同)
	if (descending) {
		std::sort(order.begin(), order.end(), [](const RowKey &a, const RowKey &b) {
			if (a.key != b.key) {
				return a.key > b.key;
			}
			return a.id < b.id;
		});
	} else {
		std::sort(order.begin(), order.end(), [](const RowKey &a, const RowKey &b) {
			if (a.key != b.key) {
				return a.key < b.key;
			}
			return a.id < b.id;
		});
	}
	PackedInt32Array out;
	out.resize(int32_t(order.size()));
	int32_t *w = out.ptrw();
	for (size_t i = 0; i < order.size(); ++i) {
		w[i] = order[i].row;
	}
	return out;
}

int32_t ECSCore::archetype_count() const {
	return int32_t(archetypes_.size());
}

int32_t ECSCore::compact_archetypes() {
	// 块下标被 entity_arch_ / 匹配缓存 / 迁移图引用, 所以移除空块必须同时重建这三处。
	std::vector<int32_t> remap(archetypes_.size(), -1);
	std::vector<Archetype> kept_list;
	kept_list.reserve(archetypes_.size());
	int32_t kept = 0;
	for (size_t i = 0; i < archetypes_.size(); ++i) {
		if (archetypes_[i].entities.empty()) {
			continue;   // 空块: 没有实体引用它
		}
		remap[i] = kept++;
		kept_list.push_back(std::move(archetypes_[i]));
	}
	const int32_t removed = int32_t(archetypes_.size()) - kept;
	if (removed == 0) {
		return 0;
	}
	archetypes_ = std::move(kept_list);
	for (int32_t &a : entity_arch_) {
		if (a >= 0) {
			a = remap[size_t(a)];
		}
	}
	_arch_cache.clear();
	arch_edge_add_.clear();
	arch_edge_remove_.clear();
	++struct_version_;
	return removed;
}

Dictionary ECSCore::serialize() const {
	Dictionary root;
	// 列式: entities = PackedInt32Array, columns = {字段: Packed 数组}。
	// 版本号恒为 1 —— 这套 ECS 未投产, 没有历史存档需要区分格式; 加版本只会让读档多一个分支。
	root["version"] = int64_t(1);
	Array comps;
	for (size_t ci = 0; ci < components_.size(); ++ci) {
		if (is_internal_comp(int32_t(ci))) {
			continue;   // 内部标记组件不进存档
		}
		const auto &c = components_[ci];
		Dictionary cd;
		cd["name"] = c.name;
		Array fnames_arr;
		Array ftypes_arr;
		Array fdefaults_arr;
		for (size_t fi = 0; fi < c.fields.size(); ++fi) {
			fnames_arr.append(c.fields[fi].name);
			ftypes_arr.append(int64_t(c.fields[fi].type));
			fdefaults_arr.append(c.defaults[fi]);
		}
		cd["field_names"] = fnames_arr;
		cd["field_types"] = ftypes_arr;
		cd["defaults"] = fdefaults_arr;
		// 列式: 实体 id 一条 + 每字段一条 Packed 数组(同一顺序, 下标即行)。
		// 旧格式是"每实体一个 Dictionary + 一个 Variant 数组": 8000 实体要 1.6 万次分配 + 4 万次装箱,
		// 实测 55.8ms(6.97µs/实体); 列式直接把聚合列搬进存档, 零 per-entity 分配。
		PackedInt32Array ids;
		for (int32_t arch : archs_with(int32_t(ci))) {
			const auto &a = archetypes_[arch];
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (!is_prefab_index(a.entities[r])) {
					ids.append(a.entities[r]);
				}
			}
		}
		if (ids.is_empty()) {
			continue; // 没有实例的组件不必写进存档
		}
		Dictionary columns;
		for (size_t fi = 0; fi < c.fields.size(); ++fi) {
			columns[c.fields[fi].name] = column_aggregate(int32_t(ci), int32_t(fi));
		}
		cd["entities"] = ids;
		cd["columns"] = columns;
		comps.append(cd);
	}
	root["components"] = comps;
	return root;
}

Array ECSCore::deserialize(const Dictionary &data) {
	Array result; // 新建实体的实体 ID 列表
	if (!data.has("components")) {
		return result;
	}
	// 第一遍: 收集所有需要创建的实体 ID 集合(按出现顺序, 跨组件去重)。
	std::vector<int32_t> entity_ids;
	{
		std::unordered_set<int32_t> seen_ids;
		Array comps = data["components"];
		for (int32_t i = 0; i < comps.size(); ++i) {
			Dictionary cd = comps[i];
			PackedInt32Array ids = cd["entities"];
			for (int32_t j = 0; j < ids.size(); ++j) {
				if (seen_ids.insert(ids[j]).second) {
					entity_ids.push_back(ids[j]);
				}
			}
		}
	}
	// 建立 存档ID -> 新实体ID 映射, 并创建实体
	std::unordered_map<int32_t, int32_t> id_map;
	id_map.reserve(entity_ids.size());
	for (int32_t saved_id : entity_ids) {
		const int32_t new_id = create_entity();
		id_map[saved_id] = new_id;
		result.append(new_id); // 返回真实实体 ID
	}

	// 第二遍: 填充组件数据。分两步走, 避免"每字段每行一次 Variant 转换":
	//   A) 结构: 逐实体 add_component, 记下 (块, 行, 组件位置);
	//   B) 值: 每字段只做**一次**类型分支并取到 Packed 裸指针, 行内是纯下标写入。
	Array comps = data["components"];
	for (int32_t i = 0; i < comps.size(); ++i) {
		Dictionary cd = comps[i];
		const StringName name = cd["name"];
		const int32_t ci = comp_index(name);
		if (ci < 0) {
			continue;
		}
		const int32_t field_count = int32_t(components_[ci].fields.size());
		PackedInt32Array ids = cd["entities"];
		Dictionary columns = cd["columns"];

		std::vector<int32_t> tgt_arch;
		std::vector<int32_t> tgt_row;
		std::vector<int32_t> tgt_cp;
		tgt_arch.reserve(size_t(ids.size()));
		tgt_row.reserve(size_t(ids.size()));
		tgt_cp.reserve(size_t(ids.size()));
		for (int32_t j = 0; j < ids.size(); ++j) {
			auto it = id_map.find(ids[j]);
			if (it == id_map.end()) {
				continue;
			}
			const int32_t e = it->second;
			if (!add_component(e, name)) {
				continue;
			}
			const int32_t idx = ecs_index_of(e);
			const int32_t arch = entity_arch_[size_t(idx)];
			const int32_t row = row_of(idx);
			const int32_t cp = archetypes_[arch].comp_pos(ci);
			if (row < 0 || cp < 0) {
				continue;
			}
			if (change_detection_) {
				archetypes_[arch].row_ver[size_t(row)] = ++write_tick_;
			}
			tgt_arch.push_back(arch);
			tgt_row.push_back(row);
			tgt_cp.push_back(cp);
		}

		// B) 值: 每字段一次类型分支 + 裸指针, 行内纯下标写入
		for (int32_t fi = 0; fi < field_count; ++fi) {
			const Variant colv = columns.get(components_[ci].fields[size_t(fi)].name, Variant());
			ecs_write_rows(archetypes_, tgt_arch, tgt_row, tgt_cp, fi, colv,
					components_[ci].defaults[size_t(fi)]);
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// ECSCore — 层级索引(原生反向表 parent → children)
// 只维护"谁是谁的子"这份索引; ECSParent 组件的读写仍在 GDScript。
// ---------------------------------------------------------------------------

void ECSCore::set_parent_bulk(const PackedInt32Array &children, int32_t parent, const StringName &parent_comp) {
	const int32_t ci = comp_index(parent_comp);
	const int32_t fi = ci >= 0 ? components_[ci].field_index("target") : -1;
	if (fi < 0) {
		return;
	}
	const int32_t plen = children.size();
	const int32_t *pw = children.ptr();
	for (int32_t i = 0; i < plen; ++i) {
		const int32_t child = pw[i];
		if (child == parent || !is_alive(child)) {
			continue;
		}
		if (has_component(child, parent_comp)) {
			// 重挂: 必须先把孩子从**旧父**的反向表里摘掉, 否则旧父永远留着这条
			// (单条 set_parent 里由调用方做, 批量版必须自己补; 用例当场抓到 500 条残留)
			const Variant oldv = get_field(child, parent_comp, "target");
			const int32_t old = oldv.get_type() == Variant::NIL ? -1 : int32_t(int64_t(oldv));
			if (old != -1 && old != parent) {
				hierarchy_remove_child(old, child);
			}
		} else {
			add_component(child, parent_comp);
		}
		set_field(child, parent_comp, "target", int64_t(parent));
		hierarchy_set_parent(child, parent);
	}
}

void ECSCore::hierarchy_set_parent(int32_t child, int32_t parent) {
	auto &arr = children_[parent];
	if (std::find(arr.begin(), arr.end(), child) == arr.end()) {
		arr.push_back(child);
	}
}

void ECSCore::hierarchy_remove_child(int32_t parent, int32_t child) {
	auto it = children_.find(parent);
	if (it == children_.end()) {
		return;
	}
	auto &arr = it->second;
	arr.erase(std::remove(arr.begin(), arr.end(), child), arr.end());
	if (arr.empty()) {
		children_.erase(it);
	}
}

PackedInt32Array ECSCore::hierarchy_children(int32_t parent) const {
	PackedInt32Array out;
	auto it = children_.find(parent);
	if (it == children_.end()) {
		return out;
	}
	const size_t n = it->second.size();
	out.resize(int32_t(n));
	int32_t *w = out.ptrw();
	for (size_t i = 0; i < n; ++i) {
		w[i] = it->second[i];
	}
	return out;
}

PackedInt32Array ECSCore::hierarchy_detach(int32_t entity) {
	PackedInt32Array out = hierarchy_children(entity);
	children_.erase(entity);
	return out;
}

int32_t ECSCore::hierarchy_child_count(int32_t parent) const {
	auto it = children_.find(parent);
	return it == children_.end() ? 0 : int32_t(it->second.size());
}

// ---------------------------------------------------------------------------
// ECSCore — Prefab 预制体
// ---------------------------------------------------------------------------

inline bool ECSCore::is_prefab_index(int32_t id) const {
	// 位图 O(1): 原先对 prefab_indices_ 线性扫, 而它在"每一行"上被调用 → O(N×P)
	// ⚠ 入参可能是**完整 id**(块内 entities 存的就是 id), 必须掩出 index;
	// 早先直接拿 id 当下标, 槽位复用后(version>0)判定就错了。
	const int32_t idx = ecs_index_of(id);
	return idx >= 0 && idx < int32_t(prefab_bitmap_.size()) && prefab_bitmap_[idx] != 0;
}

int32_t ECSCore::prefab_tag() {
	if (prefab_tag_comp_ < 0) {
		PackedStringArray fnames;
		fnames.push_back("on");
		PackedInt32Array ftypes;
		ftypes.push_back(int32_t(Variant::BOOL));
		Array fdefaults;
		fdefaults.append(false);
		prefab_tag_comp_ = register_component("__ecs_prefab", fnames, ftypes, fdefaults);
	}
	return prefab_tag_comp_;
}

bool ECSCore::is_internal_comp(int32_t ci) const {
	return ci >= 0 && ci < int32_t(components_.size()) && components_[ci].name.begins_with("__");
}

void ECSCore::set_prefab_tag(const StringName &comp) {
	// 幂等: 已存在就直接用, 不存在才注册。这样共享核心(进程内单例)与独立核心(测试)都安全,
	// 且调用方(GDScript 世界初始化)只需一行。
	int32_t ci = comp_index(comp);
	if (ci < 0) {
		PackedStringArray fnames;
		fnames.push_back("on");
		PackedInt32Array ftypes;
		ftypes.push_back(int32_t(Variant::BOOL));
		Array fdefaults;
		fdefaults.append(false);
		ci = register_component(comp, fnames, ftypes, fdefaults);
	}
	prefab_tag_comp_ = ci;
}

int32_t ECSCore::create_prefab() {
	const int32_t e = create_entity();
	if (e < 0) {
		return -1;
	}
	const int32_t index = ecs_index_of(e);
	if (int32_t(prefab_bitmap_.size()) <= index) {
		prefab_bitmap_.resize(index + 1, 0);
	}
	prefab_bitmap_[index] = 1;
	// 注: 内部标记组件(__prefab)隔离方案已放弃: 存储层分离成立, 但内部组件按名字查不到
	// (comp_index 返回 -1), 按名 API 全部失效, 且性能无改善。热路径改用
	// "块内按 prefab 行分段 memcpy"(见 column_aggregate 的 ecs_copy_runs)。
	return e;
}

bool ECSCore::is_prefab(int32_t entity) const {
	if (!is_alive(entity)) {
		return false;
	}
	return is_prefab_index(ecs_index_of(entity));
}

bool ECSCore::prefab_add(int32_t prefab, const StringName &comp, const Dictionary &values) {
	if (!is_prefab(prefab)) {
		return false;
	}
	// 给模板挂组件
	if (!add_component(prefab, comp)) {
		return false;
	}
	// 设置初始字段值
	Array keys = values.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const StringName field = StringName(keys[i]);
		set_field(prefab, comp, field, values[keys[i]]);
	}
	return true;
}

Array ECSCore::instantiate(int32_t prefab, int32_t count, const Dictionary &overrides) {
	Array result;
	if (!is_prefab(prefab) || count <= 0) {
		return result;
	}
	const int32_t pindex = ecs_index_of(prefab);
	const int32_t parch = (pindex < int32_t(entity_arch_.size())) ? entity_arch_[pindex] : -1;
	if (parch < 0) {
		return result;
	}
	const int32_t prow = row_of(pindex);
	if (prow < 0) {
		return result;
	}

	// 目标块 = 模板组件集**去掉内部标记**(实例不继承 __prefab) ⇒ 实例落独立 archetype,
	// 于是聚合/散射不必再逐行跳过模板行。没有内部标记时 dst_comps 与模板相同 → 行为与旧版一致。
	std::vector<int32_t> dst_comps;
	for (int32_t ci : archetypes_[size_t(parch)].comps) {
		if (!is_internal_comp(ci)) {
			dst_comps.push_back(ci);
		}
	}
	const int32_t darch = find_archetype(dst_comps);

	std::vector<int32_t> ids;
	ids.reserve(size_t(count));
	for (int32_t n = 0; n < count; ++n) {
		const int32_t e = create_entity();
		if (e < 0) {
			break; // 实体槽耗尽
		}
		ids.push_back(e);
	}
	const int32_t n = int32_t(ids.size());
	if (n == 0) {
		return result;
	}

	Archetype &dst = archetypes_[size_t(darch)];
	const int32_t base = int32_t(dst.entities.size());
	dst.entities.resize(size_t(base + n));
	dst.row_ver.resize(size_t(base + n), 0);
	// 扁平列: 一次遍历全部列(不再有"组件 → 字段"两层)
	for (auto &col : dst.cols) {
		col.resize(size_t(base + n));
	}

	// 行槽位: 实体索引 + 反向行号 + 所属块
	for (int32_t i = 0; i < n; ++i) {
		const int32_t idx = ecs_index_of(ids[i]);
		dst.entities[size_t(base + i)] = idx;
		if (int32_t(entity_row_.size()) <= idx) {
			entity_row_.resize(size_t(idx + 1), -1);
		}
		entity_row_[size_t(idx)] = base + i;
		entity_arch_[size_t(idx)] = darch;
	}

	// 字段值: 按组件对齐整段拷模板行(同类型直拷, 不经过 Variant)。
	// 目标块可能比模板块**少**内部组件, 所以按 dst_comps 逐个组件定位, 不能用扁平下标直接对拷。
	for (size_t c = 0; c < dst_comps.size(); ++c) {
		const int32_t cp_src = archetypes_[size_t(parch)].comp_pos(dst_comps[c]);
		const int32_t cp_dst = dst.comp_pos(dst_comps[c]);
		if (cp_src < 0 || cp_dst < 0) {
			continue;
		}
		const int32_t nf = dst.col_count(cp_dst);
		for (int32_t fi = 0; fi < nf; ++fi) {
			ecs_copy_row_range(dst.col_at(cp_dst, fi), size_t(prow), size_t(base), n);
		}
	}

	// overrides: 只改动被点名的列, 且只写这几列(通常 0~2 个)
	Array comp_keys = overrides.keys();
	for (int32_t k = 0; k < comp_keys.size(); ++k) {
		const StringName cname = StringName(comp_keys[k]);
		const int32_t ci = comp_index(cname);
		const int32_t cp = (ci >= 0) ? dst.comp_pos(ci) : -1;
		if (cp < 0) {
			continue; // 模板没有这个组件: 忽略(与逐实体路径一致)
		}
		Dictionary od = overrides[comp_keys[k]];
		Array field_keys = od.keys();
		for (int32_t f = 0; f < field_keys.size(); ++f) {
			const int32_t fi = components_[ci].field_index(StringName(field_keys[f]));
			if (fi < 0) {
				continue;
			}
			const Variant v = od[field_keys[f]];
			for (int32_t i = 0; i < n; ++i) {
				dst.col_at(size_t(cp), size_t(fi)).set(size_t(base + i), v);
			}
		}
	}

	result.resize(n);
	for (int32_t i = 0; i < n; ++i) {
		result[i] = ids[i];
	}
	++struct_version_;
	return result;
}



// ---------------------------------------------------------------------------
// ECSCore — Command Buffer (延迟结构变更)
// 系统内排队, flush_commands() 帧末统一执行, 避免遍历中改结构。
// ---------------------------------------------------------------------------

void ECSCore::ensure_cmd_batch() {
	// 批次边界 = 队列由空变非空。所有入队操作都必须先过这里:
	// 原来只在 cmd_create 里按 "size()==1" 判断, 队列首条不是 create 时就不会重置,
	// cmd_created_ 里残留上一批的实体 → 占位序号错位、created_entity_at 返回旧值。
	if (cmd_types_.empty()) {
		cmd_created_.clear();
	}
}

void ECSCore::cmd_create() {
	ensure_cmd_batch();
	cmd_types_.push_back(CMD_CREATE);
	// 负句柄 = -(create序号+1), 便于后续 add_component 引用
	const int32_t idx = int32_t(cmd_created_.size());
	cmd_entities_.push_back(-(idx + 1));
	cmd_created_.push_back(-1);
	cmd_comps_.push_back(StringName());
}

void ECSCore::cmd_destroy(int32_t entity) {
	ensure_cmd_batch();
	cmd_types_.push_back(CMD_DESTROY);
	cmd_entities_.push_back(entity);
	cmd_comps_.push_back(StringName());
}

void ECSCore::cmd_add_component(int32_t entity, const StringName &comp) {
	ensure_cmd_batch();
	cmd_types_.push_back(CMD_ADD_COMP);
	cmd_entities_.push_back(entity);
	cmd_comps_.push_back(comp);
}

void ECSCore::cmd_remove_component(int32_t entity, const StringName &comp) {
	ensure_cmd_batch();
	cmd_types_.push_back(CMD_REMOVE_COMP);
	cmd_entities_.push_back(entity);
	cmd_comps_.push_back(comp);
}

PackedInt32Array ECSCore::cmd_create_many(int32_t count) {
	PackedInt32Array out;
	if (count <= 0) {
		return out;
	}
	ensure_cmd_batch();
	const size_t base = cmd_types_.size();
	cmd_types_.reserve(base + size_t(count));
	cmd_entities_.reserve(base + size_t(count));
	cmd_comps_.reserve(base + size_t(count));
	cmd_created_.reserve(cmd_created_.size() + size_t(count));
	out.resize(count);
	int32_t *w = out.ptrw();
	for (int32_t i = 0; i < count; ++i) {
		const int32_t idx = int32_t(cmd_created_.size());
		cmd_types_.push_back(CMD_CREATE);
		cmd_entities_.push_back(-(idx + 1));   // 负句柄 = 占位
		cmd_created_.push_back(-1);
		cmd_comps_.push_back(StringName());
		w[i] = -(idx + 1);
	}
	return out;
}

void ECSCore::cmd_add_many(const PackedInt32Array &entities, const StringName &comp) {
	if (entities.is_empty()) {
		return;
	}
	ensure_cmd_batch();
	const size_t base = cmd_types_.size();
	cmd_types_.reserve(base + size_t(entities.size()));
	cmd_entities_.reserve(base + size_t(entities.size()));
	cmd_comps_.reserve(base + size_t(entities.size()));
	for (int32_t i = 0; i < entities.size(); ++i) {
		cmd_types_.push_back(CMD_ADD_COMP);
		cmd_entities_.push_back(entities[i]);
		cmd_comps_.push_back(comp);
	}
}

void ECSCore::cmd_destroy_many(const PackedInt32Array &entities) {
	if (entities.is_empty()) {
		return;
	}
	ensure_cmd_batch();
	const size_t base = cmd_types_.size();
	cmd_types_.reserve(base + size_t(entities.size()));
	cmd_entities_.reserve(base + size_t(entities.size()));
	cmd_comps_.reserve(base + size_t(entities.size()));
	for (int32_t i = 0; i < entities.size(); ++i) {
		cmd_types_.push_back(CMD_DESTROY);
		cmd_entities_.push_back(entities[i]);
		cmd_comps_.push_back(StringName());
	}
}

int32_t ECSCore::pending_command_count() const {
	return int32_t(cmd_types_.size());
}

// 供 GDScript 查询: 第 index 个 create 命令 flush 后生成的实体 ID(未 flush 返回 -1)
int32_t ECSCore::created_entity_at(int32_t index) const {
	if (index < 0 || index >= int32_t(cmd_created_.size())) {
		return -1;
	}
	return cmd_created_[index];
}

void ECSCore::flush_commands() {
	if (cmd_types_.empty()) {
		return;
	}
	// 第一遍: 执行 create, 把占位句柄替换为真实实体 ID, 并记录映射
	// create 占位句柄 = -(create序号+1)
	{
		size_t create_idx = 0;
		for (size_t i = 0; i < cmd_types_.size(); ++i) {
			if (cmd_types_[i] == CMD_CREATE) {
				const int32_t e = create_entity();
				cmd_entities_[i] = e;
				if (create_idx < cmd_created_.size()) {
					cmd_created_[create_idx] = e;
				}
				++create_idx;
			}
		}
	}
	// 第二遍: 解析占位句柄, 执行其他命令
	for (size_t i = 0; i < cmd_types_.size(); ++i) {
		if (cmd_types_[i] == CMD_CREATE) {
			continue; // 已处理
		}
		int32_t e = cmd_entities_[i];
		if (e < 0) {
			// 负句柄: 引用之前第 (|e|-1) 个 create 生成的实体
			const int32_t ci = -e - 1;
			if (ci >= 0 && ci < int32_t(cmd_created_.size())) {
				e = cmd_created_[ci];
			} else {
				continue; // 无效句柄
			}
		}
		switch (cmd_types_[i]) {
			case CMD_DESTROY:
				if (e >= 0 && is_alive(e)) {
					destroy_entity(e);
				}
				break;
			case CMD_ADD_COMP:
				if (e >= 0 && is_alive(e)) {
					add_component(e, cmd_comps_[i]);
				}
				break;
			case CMD_REMOVE_COMP:
				if (e >= 0 && is_alive(e)) {
					remove_component(e, cmd_comps_[i]);
				}
				break;
			default:
				break;
		}
	}
	cmd_types_.clear();
	cmd_entities_.clear();
	cmd_comps_.clear();
	// cmd_created_ 保留: 供 created_entity_at 查询本次生成的实体, 下次 cmd_create 时重置
}

// ---------------------------------------------------------------------------
// ECSCore — 绑定
// ---------------------------------------------------------------------------

void ECSCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_component", "name", "fnames", "ftypes", "fdefaults"), &ECSCore::register_component);
	ClassDB::bind_method(D_METHOD("create_entity"), &ECSCore::create_entity);
	ClassDB::bind_method(D_METHOD("is_alive", "entity"), &ECSCore::is_alive);
	ClassDB::bind_method(D_METHOD("destroy_entity", "entity"), &ECSCore::destroy_entity);
	ClassDB::bind_method(D_METHOD("add_component", "entity", "comp"), &ECSCore::add_component);
	ClassDB::bind_method(D_METHOD("has_component", "entity", "comp"), &ECSCore::has_component);
	ClassDB::bind_method(D_METHOD("remove_component", "entity", "comp"), &ECSCore::remove_component);
	ClassDB::bind_method(D_METHOD("count_entities", "comp"), &ECSCore::count_entities);
	ClassDB::bind_method(D_METHOD("get_entity_components", "entity"), &ECSCore::get_entity_components);
	ClassDB::bind_method(D_METHOD("get_archetype_groups"), &ECSCore::get_archetype_groups);
	ClassDB::bind_method(D_METHOD("query_rows", "anchor", "must", "without"), &ECSCore::query_rows);
	ClassDB::bind_method(D_METHOD("query_entities", "anchor", "must", "without"), &ECSCore::query_entities);
	ClassDB::bind_method(D_METHOD("query_rows_aligned", "anchor", "must", "without"), &ECSCore::query_rows_aligned);
	ClassDB::bind_method(D_METHOD("query_rows_aligned_where", "anchor", "must", "without", "conditions", "comps"), &ECSCore::query_rows_aligned_where);
	ClassDB::bind_method(D_METHOD("entity_of_row", "comp", "row"), &ECSCore::entity_of_row);
	ClassDB::bind_method(D_METHOD("get_entity_at", "comp", "row"), &ECSCore::get_entity_at);
	ClassDB::bind_method(D_METHOD("get_changed", "comp", "since"), &ECSCore::get_changed);
	ClassDB::bind_method(D_METHOD("write_tick"), &ECSCore::write_tick);
	ClassDB::bind_method(D_METHOD("set_change_detection", "enabled"), &ECSCore::set_change_detection);
	ClassDB::bind_method(D_METHOD("is_change_detection"), &ECSCore::is_change_detection);
	ClassDB::bind_method(D_METHOD("get_field", "entity", "comp", "field"), &ECSCore::get_field);
	ClassDB::bind_method(D_METHOD("set_field", "entity", "comp", "field", "value"), &ECSCore::set_field);
	ClassDB::bind_method(D_METHOD("get_column", "comp", "field"), &ECSCore::get_column);
	ClassDB::bind_method(D_METHOD("set_column", "comp", "field", "values"), &ECSCore::set_column);
	ClassDB::bind_method(D_METHOD("get_columns", "comps_fields"), &ECSCore::get_columns);
	ClassDB::bind_method(D_METHOD("set_columns", "values"), &ECSCore::set_columns);
	ClassDB::bind_method(D_METHOD("batch_apply_col", "anchor", "must", "op_comp", "op_field", "src_comp", "src_field", "op", "factor", "addend", "conditions"), &ECSCore::batch_apply_col);
	ClassDB::bind_method(D_METHOD("batch_clamp_where", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field", "conditions"), &ECSCore::batch_clamp_where);


	ClassDB::bind_method(D_METHOD("batch_apply", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend"), &ECSCore::batch_apply);
	ClassDB::bind_method(D_METHOD("batch_apply_where", "anchor", "must", "op_comp", "op_field", "op", "factor", "addend", "conditions"), &ECSCore::batch_apply_where);
	ClassDB::bind_method(D_METHOD("batch_count", "anchor", "must", "conditions"), &ECSCore::batch_count);
	ClassDB::bind_method(D_METHOD("batch_clamp", "anchor", "must", "op_comp", "op_field", "min_comp", "min_field", "max_comp", "max_field"), &ECSCore::batch_clamp);
	ClassDB::bind_method(D_METHOD("batch_vec_add", "anchor", "must", "pos_comp", "pos_field", "vel_comp", "vel_field", "delta"), &ECSCore::batch_vec_add);
	ClassDB::bind_method(D_METHOD("batch_collect", "anchor", "must", "without", "groups"), &ECSCore::batch_collect);
	ClassDB::bind_method(D_METHOD("batch_apply_rows", "anchor", "rows", "op_comp", "op_field", "op", "factor", "addend"), &ECSCore::batch_apply_rows);
	ClassDB::bind_method(D_METHOD("batch_apply_col_rows", "anchor", "rows", "op_comp", "op_field", "src_comp", "src_field", "op", "factor", "addend"), &ECSCore::batch_apply_col_rows);
	ClassDB::bind_method(D_METHOD("batch_apply_actions", "anchor", "rows", "actions"), &ECSCore::batch_apply_actions);
	ClassDB::bind_method(D_METHOD("debug_stats"), &ECSCore::debug_stats);
	ClassDB::bind_method(D_METHOD("set_thread_count", "count"), &ECSCore::set_thread_count);
	ClassDB::bind_method(D_METHOD("run_systems_parallel", "systems"), &ECSCore::run_systems_parallel);
	ClassDB::bind_method(D_METHOD("sync_fields", "nl_rows", "comp_rows", "nodes", "comp", "fields", "props"), &ECSCore::sync_fields);
	ClassDB::bind_method(D_METHOD("multimesh_sync", "comp", "entities", "f_layer", "f_pos", "f_rot", "f_scale", "f_color", "meshes"), &ECSCore::multimesh_sync);
	ClassDB::bind_method(D_METHOD("set_sync_direct", "v"), &ECSCore::set_sync_direct);
	ClassDB::bind_method(D_METHOD("get_sync_direct"), &ECSCore::get_sync_direct);
	ClassDB::bind_method(D_METHOD("serialize"), &ECSCore::serialize);
	ClassDB::bind_method(D_METHOD("deserialize", "data"), &ECSCore::deserialize);
	ClassDB::bind_method(D_METHOD("create_prefab"), &ECSCore::create_prefab);
	ClassDB::bind_method(D_METHOD("is_prefab", "entity"), &ECSCore::is_prefab);
	ClassDB::bind_method(D_METHOD("prefab_add", "prefab", "comp", "values"), &ECSCore::prefab_add);
	ClassDB::bind_method(D_METHOD("instantiate", "prefab", "count", "overrides"), &ECSCore::instantiate);

	ClassDB::bind_method(D_METHOD("cmd_create"), &ECSCore::cmd_create);
	ClassDB::bind_method(D_METHOD("cmd_destroy", "entity"), &ECSCore::cmd_destroy);
	ClassDB::bind_method(D_METHOD("cmd_add_component", "entity", "comp"), &ECSCore::cmd_add_component);
	ClassDB::bind_method(D_METHOD("cmd_remove_component", "entity", "comp"), &ECSCore::cmd_remove_component);
	ClassDB::bind_method(D_METHOD("cmd_create_many", "count"), &ECSCore::cmd_create_many);
	ClassDB::bind_method(D_METHOD("cmd_add_many", "entities", "comp"), &ECSCore::cmd_add_many);
	ClassDB::bind_method(D_METHOD("cmd_destroy_many", "entities"), &ECSCore::cmd_destroy_many);
	ClassDB::bind_method(D_METHOD("archetype_count"), &ECSCore::archetype_count);
	ClassDB::bind_method(D_METHOD("compact_archetypes"), &ECSCore::compact_archetypes);
	ClassDB::bind_method(D_METHOD("spatial_enable", "comp", "field", "cell_size"), &ECSCore::spatial_enable);
	ClassDB::bind_method(D_METHOD("spatial_disable"), &ECSCore::spatial_disable);
	ClassDB::bind_method(D_METHOD("spatial_invalidate"), &ECSCore::spatial_invalidate);
	ClassDB::bind_method(D_METHOD("spatial_update_entity", "id"), &ECSCore::spatial_update_entity);
	ClassDB::bind_method(D_METHOD("spatial_query_rect", "min_pos", "max_pos"), &ECSCore::spatial_query_rect);
	ClassDB::bind_method(D_METHOD("spatial_query_radius", "center", "radius"), &ECSCore::spatial_query_radius);
	ClassDB::bind_method(D_METHOD("spatial_stats"), &ECSCore::spatial_stats);
	ClassDB::bind_method(D_METHOD("hierarchy_set_parent", "child", "parent"), &ECSCore::hierarchy_set_parent);
	ClassDB::bind_method(D_METHOD("set_parent_bulk", "children", "parent", "parent_comp"), &ECSCore::set_parent_bulk);
	ClassDB::bind_method(D_METHOD("hierarchy_remove_child", "parent", "child"), &ECSCore::hierarchy_remove_child);
	ClassDB::bind_method(D_METHOD("hierarchy_children", "parent"), &ECSCore::hierarchy_children);
	ClassDB::bind_method(D_METHOD("hierarchy_detach", "entity"), &ECSCore::hierarchy_detach);
	ClassDB::bind_method(D_METHOD("hierarchy_child_count", "parent"), &ECSCore::hierarchy_child_count);
	ClassDB::bind_method(D_METHOD("set_prefab_tag", "comp"), &ECSCore::set_prefab_tag);
	ClassDB::bind_method(D_METHOD("query_rows_sorted", "anchor", "must", "without", "field", "descending"), &ECSCore::query_rows_sorted, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("flush_commands"), &ECSCore::flush_commands);
	ClassDB::bind_method(D_METHOD("pending_command_count"), &ECSCore::pending_command_count);
	ClassDB::bind_method(D_METHOD("created_entity_at", "index"), &ECSCore::created_entity_at);
	ClassDB::bind_method(D_METHOD("row_of_entity", "comp", "entity"), &ECSCore::row_of_entity);
}
