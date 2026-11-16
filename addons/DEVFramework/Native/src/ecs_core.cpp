#include "ecs_core.h"

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
			std::fill_n(column.i32.begin() + base, n, column.i32[src_row]);
			break;
		case godot::Variant::FLOAT:
			std::fill_n(column.f32.begin() + base, n, column.f32[src_row]);
			break;
		case godot::Variant::BOOL:
			std::fill_n(column.b.begin() + base, n, column.b[src_row]);
			break;
		case godot::Variant::VECTOR2:
			std::fill_n(column.v2.begin() + base, n, column.v2[src_row]);
			break;
		case godot::Variant::VECTOR3:
			std::fill_n(column.v3.begin() + base, n, column.v3[src_row]);
			break;
		case godot::Variant::VECTOR4:
			std::fill_n(column.v4.begin() + base, n, column.v4[src_row]);
			break;
		case godot::Variant::COLOR:
			std::fill_n(column.col.begin() + base, n, column.col[src_row]);
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
			Variant v = a.cols[cp][fi2].get(cr.second);
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

void ECSColumn::resize(size_t n) {
	switch (type) {
		case Variant::INT: i32.resize(int32_t(n)); break;
		case Variant::FLOAT: f32.resize(int32_t(n)); break;
		case Variant::BOOL: b.resize(int32_t(n)); break;
		case Variant::VECTOR2: v2.resize(int32_t(n)); break;
		case Variant::VECTOR3: v3.resize(int32_t(n)); break;
		case Variant::VECTOR4: v4.resize(int32_t(n)); break;
		case Variant::COLOR: col.resize(int32_t(n)); break;
		case Variant::STRING: s.resize(int32_t(n)); break;
		default: break;
	}
}

void ECSColumn::push_default(const Variant &value) {
	switch (type) {
		case Variant::INT: i32.push_back(int32_t(value)); break;
		case Variant::FLOAT: f32.push_back(float(value)); break;
		case Variant::BOOL: b.push_back(bool(value) ? 1 : 0); break;
		case Variant::VECTOR2: v2.push_back(Vector2(value)); break;
		case Variant::VECTOR3: v3.push_back(Vector3(value)); break;
		case Variant::VECTOR4: v4.push_back(Vector4(value)); break;
		case Variant::COLOR: col.push_back(Color(value)); break;
		case Variant::STRING: s.push_back(String(value)); break;
		default: break;
	}
}

void *ECSColumn::write_ptr() {
	switch (type) {
		case Variant::INT: return i32.empty() ? nullptr : i32.data();
		case Variant::FLOAT: return f32.empty() ? nullptr : f32.data();
		case Variant::BOOL: return b.empty() ? nullptr : b.data();
		case Variant::VECTOR2: return v2.empty() ? nullptr : v2.data();
		case Variant::VECTOR3: return v3.empty() ? nullptr : v3.data();
		case Variant::VECTOR4: return v4.empty() ? nullptr : v4.data();
		case Variant::COLOR: return col.empty() ? nullptr : col.data();
		case Variant::STRING: return s.empty() ? nullptr : s.data();
		default: return nullptr;
	}
}

const void *ECSColumn::read_ptr() const {
	switch (type) {
		case Variant::INT: return i32.empty() ? nullptr : i32.data();
		case Variant::FLOAT: return f32.empty() ? nullptr : f32.data();
		case Variant::BOOL: return b.empty() ? nullptr : b.data();
		case Variant::VECTOR2: return v2.empty() ? nullptr : v2.data();
		case Variant::VECTOR3: return v3.empty() ? nullptr : v3.data();
		case Variant::VECTOR4: return v4.empty() ? nullptr : v4.data();
		case Variant::COLOR: return col.empty() ? nullptr : col.data();
		case Variant::STRING: return s.empty() ? nullptr : s.data();
		default: return nullptr;
	}
}

void ECSColumn::pop() {
	switch (type) {
		case Variant::INT: i32.resize(i32.size() - 1); break;
		case Variant::FLOAT: f32.resize(f32.size() - 1); break;
		case Variant::BOOL: b.resize(b.size() - 1); break;
		case Variant::VECTOR2: v2.resize(v2.size() - 1); break;
		case Variant::VECTOR3: v3.resize(v3.size() - 1); break;
		case Variant::VECTOR4: v4.resize(v4.size() - 1); break;
		case Variant::COLOR: col.resize(col.size() - 1); break;
		case Variant::STRING: s.resize(s.size() - 1); break;
		default: break;
	}
}

Variant ECSColumn::get(size_t row) const {
	switch (type) {
		case Variant::INT: return int64_t(i32[int32_t(row)]);
		case Variant::FLOAT: return double(f32[int32_t(row)]);
		case Variant::BOOL: return bool(b[int32_t(row)]);
		case Variant::VECTOR2: return v2[int32_t(row)];
		case Variant::VECTOR3: return v3[int32_t(row)];
		case Variant::VECTOR4: return v4[int32_t(row)];
		case Variant::COLOR: return col[int32_t(row)];
		case Variant::STRING: return s[int32_t(row)];
		default: return Variant();
	}
}

void ECSColumn::set(size_t row, const Variant &value) {
	const int32_t r = int32_t(row);
	switch (type) {
		case Variant::INT: i32[r] = int32_t(int64_t(value)); break;
		case Variant::FLOAT: f32[r] = float(double(value)); break;
		case Variant::BOOL: b[r] = uint8_t(bool(value)); break;
		case Variant::VECTOR2: v2[r] = Vector2(value); break;
		case Variant::VECTOR3: v3[r] = Vector3(value); break;
		case Variant::VECTOR4: v4[r] = Vector4(value); break;
		case Variant::COLOR: col[r] = Color(value); break;
		case Variant::STRING: s[r] = String(value); break;
		default: break;
	}
}

size_t ECSColumn::size() const {
	switch (type) {
		case Variant::INT: return size_t(i32.size());
		case Variant::FLOAT: return size_t(f32.size());
		case Variant::BOOL: return size_t(b.size());
		case Variant::VECTOR2: return size_t(v2.size());
		case Variant::VECTOR3: return size_t(v3.size());
		case Variant::VECTOR4: return size_t(v4.size());
		case Variant::COLOR: return size_t(col.size());
		case Variant::STRING: return size_t(s.size());
		default: return 0;
	}
}

// ---------------------------------------------------------------------------
// 裸内存列 <-> Godot PackedArray 转换 (get_column/set_column/borrow/return 用)
// 列内部是自管 std::vector; 与 GDScript 边界处按需拷贝为 PackedArray(非零拷贝)。
// ---------------------------------------------------------------------------
static Variant col_to_packed(const ECSColumn &col) {
	switch (col.type) {
		case Variant::INT: {
			PackedInt32Array a;
			a.resize(int32_t(col.i32.size()));
			if (!col.i32.empty()) {
				memcpy(a.ptrw(), col.i32.data(), col.i32.size() * sizeof(int32_t));
			}
			return a;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a;
			a.resize(int32_t(col.f32.size()));
			if (!col.f32.empty()) {
				memcpy(a.ptrw(), col.f32.data(), col.f32.size() * sizeof(float));
			}
			return a;
		}
		case Variant::BOOL: {
			PackedByteArray a;
			a.resize(int32_t(col.b.size()));
			if (!col.b.empty()) {
				memcpy(a.ptrw(), col.b.data(), col.b.size());
			}
			return a;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a;
			a.resize(int32_t(col.v2.size()));
			if (!col.v2.empty()) {
				memcpy(a.ptrw(), col.v2.data(), col.v2.size() * sizeof(Vector2));
			}
			return a;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a;
			a.resize(int32_t(col.v3.size()));
			if (!col.v3.empty()) {
				memcpy(a.ptrw(), col.v3.data(), col.v3.size() * sizeof(Vector3));
			}
			return a;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a;
			a.resize(int32_t(col.v4.size()));
			if (!col.v4.empty()) {
				memcpy(a.ptrw(), col.v4.data(), col.v4.size() * sizeof(Vector4));
			}
			return a;
		}
		case Variant::COLOR: {
			PackedColorArray a;
			a.resize(int32_t(col.col.size()));
			if (!col.col.empty()) {
				memcpy(a.ptrw(), col.col.data(), col.col.size() * sizeof(Color));
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
			col.i32.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.i32.data(), a.ptr(), a.size() * sizeof(int32_t));
			}
			break;
		}
		case Variant::FLOAT: {
			PackedFloat32Array a = v;
			col.f32.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.f32.data(), a.ptr(), a.size() * sizeof(float));
			}
			break;
		}
		case Variant::BOOL: {
			PackedByteArray a = v;
			col.b.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.b.data(), a.ptr(), a.size());
			}
			break;
		}
		case Variant::VECTOR2: {
			PackedVector2Array a = v;
			col.v2.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.v2.data(), a.ptr(), a.size() * sizeof(Vector2));
			}
			break;
		}
		case Variant::VECTOR3: {
			PackedVector3Array a = v;
			col.v3.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.v3.data(), a.ptr(), a.size() * sizeof(Vector3));
			}
			break;
		}
		case Variant::VECTOR4: {
			PackedVector4Array a = v;
			col.v4.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.v4.data(), a.ptr(), a.size() * sizeof(Vector4));
			}
			break;
		}
		case Variant::COLOR: {
			PackedColorArray a = v;
			col.col.resize(int32_t(a.size()));
			if (a.size() > 0) {
				memcpy(col.col.data(), a.ptr(), a.size() * sizeof(Color));
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
		case Variant::INT: col.i32.clear(); break;
		case Variant::FLOAT: col.f32.clear(); break;
		case Variant::BOOL: col.b.clear(); break;
		case Variant::VECTOR2: col.v2.clear(); break;
		case Variant::VECTOR3: col.v3.clear(); break;
		case Variant::VECTOR4: col.v4.clear(); break;
		case Variant::COLOR: col.col.clear(); break;
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
	a.cols.resize(comps.size());
	for (size_t cp = 0; cp < comps.size(); ++cp) {
		const int32_t ci = comps[cp];
		a.cols[cp].resize(components_[ci].fields.size());
		for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
			a.cols[cp][f].type = components_[ci].fields[f].type;
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
	const int32_t row = a.row_of(index);
	if (row < 0) {
		return;
	}
	const int32_t last = int32_t(a.entities.size()) - 1;
	const int32_t last_e = a.entities[last];
	if (row != last) {
		a.entities[row] = last_e;
		a.row_map[last_e] = row;
		a.row_ver[row] = a.row_ver[last];
		for (size_t cp = 0; cp < a.comps.size(); ++cp) {
			const int32_t ci = a.comps[cp];
			for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
				ECSColumn &c = a.cols[cp][f];
				c.set(row, c.get(last));
				c.pop();
			}
		}
	} else {
		for (size_t cp = 0; cp < a.comps.size(); ++cp) {
			const int32_t ci = a.comps[cp];
			for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
				a.cols[cp][f].pop();
			}
		}
	}
	a.entities.pop_back();
	a.row_map[index] = -1;
	a.row_ver.pop_back();
}

// 把实体迁移到目标 archetype(拷贝旧组件数据 + 新组件默认值)
void ECSCore::migrate_entity(int32_t index, int32_t src_arch, int32_t dst_arch) {
	Archetype &dst = archetypes_[dst_arch];
	const int32_t row = int32_t(dst.entities.size());
	dst.entities.push_back(index);
	if (int32_t(dst.row_map.size()) <= index) {
		dst.row_map.resize(index + 1, -1);
	}
	dst.row_map[index] = row;
	dst.row_ver.push_back(0);
	if (src_arch >= 0) {
		Archetype &src = archetypes_[src_arch];
		const int32_t src_row = src.row_of(index);
		if (src_row >= 0) {
			for (size_t cp = 0; cp < src.comps.size(); ++cp) {
				const int32_t ci = src.comps[cp];
				const int32_t dp = dst.comp_pos(ci);
				if (dp < 0) {
					continue;
				}
				for (size_t f = 0; f < components_[ci].fields.size(); ++f) {
					ECSColumn &dcol = dst.cols[dp][f];
					dcol.resize(row + 1);
					dcol.set(row, src.cols[cp][f].get(src_row));
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
			ECSColumn &dcol = dst.cols[cp][f];
			dcol.resize(row + 1);
			dcol.set(row, comp.defaults[f]);
		}
	}
	if (src_arch >= 0) {
		remove_from_archetype(src_arch, index);
	}
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
	if (find_comp(name) != nullptr) {
		return int32_t(components_.size()); // 已注册, 幂等
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
	entity_arch_[index] = -1; // 新实体无组件, 不属于任何 archetype
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
PackedInt32Array ECSCore::get_changed(const StringName &comp, uint32_t since) const {
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
	const int32_t row = a.row_of(index);
	if (row < 0) {
		return Variant();
	}
	return a.cols[cp][fi].get(row);
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
	const int32_t row = a.row_of(index);
	if (row < 0) {
		return;
	}
	if (change_detection_) ++a.row_ver[row];
	a.cols[cp][fi].set(row, value);
}

// ---------------------------------------------------------------------------
// ECSCore — 批量列访问 (零拷贝)
// ---------------------------------------------------------------------------

// 跨块列聚合: 含 ci 的 archetype 块按序拼接非 prefab 实体值(get_column 索引 = 聚合顺序)
// 跨块列聚合: 含 ci 的 archetype 块按序拼接非 prefab 实体值(get_column 索引 = 聚合顺序)
Variant ECSCore::column_aggregate(int32_t ci, int32_t fi) const {
	const Variant::Type t = components_[ci].fields[fi].type;
	struct Blk {
		const Archetype *a;
		int cp;
	};
	std::vector<Blk> blocks;
	size_t total = 0;
	for (int32_t arch2 : archs_with(ci)) {
		const auto &a = archetypes_[arch2];
		const int cp = a.comp_pos(ci);
		int cnt = 0;
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (!is_prefab_index(a.entities[r])) {
				++cnt;
			}
		}
		if (cnt > 0) {
			blocks.push_back({&a, cp});
			total += size_t(cnt);
		}
	}
	// 无 prefab 块整块 memcpy(快路径)
	auto has_pref = [this](const Archetype &a) {
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				return true;
			}
		}
		return false;
	};
	switch (t) {
		case Variant::INT: {
			PackedInt32Array a;
			a.resize(int32_t(total));
			int32_t *dst = a.ptrw();
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].i32;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(int32_t));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
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
				const auto &col = b.a->cols[b.cp][fi].f32;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(float));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
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
				const auto &col = b.a->cols[b.cp][fi].b;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size());
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
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
				const auto &col = b.a->cols[b.cp][fi].v2;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Vector2));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
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
				const auto &col = b.a->cols[b.cp][fi].v3;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Vector3));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
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
				const auto &col = b.a->cols[b.cp][fi].v4;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Vector4));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
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
				const auto &col = b.a->cols[b.cp][fi].col;
				if (!has_pref(*b.a)) {
					memcpy(dst + idx, col.data(), col.size() * sizeof(Color));
					idx += col.size();
				} else {
					for (int32_t r = 0; r < int32_t(b.a->entities.size()); ++r) {
						if (is_prefab_index(b.a->entities[r])) {
							continue;
						}
						dst[idx++] = col[r];
					}
				}
			}
			return a;
		}
		case Variant::STRING: {
			PackedStringArray a;
			a.resize(int32_t(total));
			size_t idx = 0;
			for (const auto &b : blocks) {
				const auto &col = b.a->cols[b.cp][fi].s;
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
void ECSCore::column_scatter(int32_t ci, int32_t fi, const Variant &values) {
	const Variant::Type t = components_[ci].fields[fi].type;
	size_t idx = 0;
	auto has_pref = [this](const Archetype &a) {
		for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
			if (is_prefab_index(a.entities[r])) {
				return true;
			}
		}
		return false;
	};
	for (auto &a : archetypes_) {
		if (!a.has_comp(ci)) {
			continue;
		}
		const int cp = a.comp_pos(ci);
		auto &col = a.cols[cp][fi];
		if (!has_pref(a)) {
			switch (t) {
				case Variant::INT: {
					PackedInt32Array p = values;
					memcpy(col.i32.data(), p.ptr() + idx, col.i32.size() * sizeof(int32_t));
					idx += col.i32.size();
					break;
				}
				case Variant::FLOAT: {
					PackedFloat32Array p = values;
					memcpy(col.f32.data(), p.ptr() + idx, col.f32.size() * sizeof(float));
					idx += col.f32.size();
					break;
				}
				case Variant::BOOL: {
					PackedByteArray p = values;
					memcpy(col.b.data(), p.ptr() + idx, col.b.size());
					idx += col.b.size();
					break;
				}
				case Variant::VECTOR2: {
					PackedVector2Array p = values;
					memcpy(col.v2.data(), p.ptr() + idx, col.v2.size() * sizeof(Vector2));
					idx += col.v2.size();
					break;
				}
				case Variant::VECTOR3: {
					PackedVector3Array p = values;
					memcpy(col.v3.data(), p.ptr() + idx, col.v3.size() * sizeof(Vector3));
					idx += col.v3.size();
					break;
				}
				case Variant::VECTOR4: {
					PackedVector4Array p = values;
					memcpy(col.v4.data(), p.ptr() + idx, col.v4.size() * sizeof(Vector4));
					idx += col.v4.size();
					break;
				}
				case Variant::COLOR: {
					PackedColorArray p = values;
					memcpy(col.col.data(), p.ptr() + idx, col.col.size() * sizeof(Color));
					idx += col.col.size();
					break;
				}
				default: {
					for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
						Variant v;
				switch (values.get_type()) {
					case Variant::INT: { PackedInt32Array p = values; v = Variant(int64_t(p[int32_t(idx)])); break; }
					case Variant::FLOAT: { PackedFloat32Array p = values; v = Variant(double(p[int32_t(idx)])); break; }
					case Variant::BOOL: { PackedByteArray p = values; v = Variant(bool(p[int32_t(idx)])); break; }
					case Variant::VECTOR2: { PackedVector2Array p = values; v = Variant(Vector2(p[int32_t(idx)])); break; }
					case Variant::VECTOR3: { PackedVector3Array p = values; v = Variant(Vector3(p[int32_t(idx)])); break; }
					case Variant::VECTOR4: { PackedVector4Array p = values; v = Variant(Vector4(p[int32_t(idx)])); break; }
					case Variant::COLOR: { PackedColorArray p = values; v = Variant(Color(p[int32_t(idx)])); break; }
					case Variant::STRING: { PackedStringArray p = values; v = Variant(p[int32_t(idx)]); break; }
					default: v = Variant();
				}
				++idx;
						col.set(r, v);
					}
					break;
				}
			}
		} else {
			for (int32_t r = 0; r < int32_t(a.entities.size()); ++r) {
				if (is_prefab_index(a.entities[r])) {
					continue;
				}
				Variant v;
				switch (values.get_type()) {
					case Variant::INT: { PackedInt32Array p = values; v = Variant(int64_t(p[int32_t(idx)])); break; }
					case Variant::FLOAT: { PackedFloat32Array p = values; v = Variant(double(p[int32_t(idx)])); break; }
					case Variant::BOOL: { PackedByteArray p = values; v = Variant(bool(p[int32_t(idx)])); break; }
					case Variant::VECTOR2: { PackedVector2Array p = values; v = Variant(Vector2(p[int32_t(idx)])); break; }
					case Variant::VECTOR3: { PackedVector3Array p = values; v = Variant(Vector3(p[int32_t(idx)])); break; }
					case Variant::VECTOR4: { PackedVector4Array p = values; v = Variant(Vector4(p[int32_t(idx)])); break; }
					case Variant::COLOR: { PackedColorArray p = values; v = Variant(Color(p[int32_t(idx)])); break; }
					case Variant::STRING: { PackedStringArray p = values; v = Variant(p[int32_t(idx)]); break; }
					default: v = Variant();
				}
				++idx;
				col.set(r, v);
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
	const int32_t erow = archetypes_[earch].row_of(entity);
	if (erow < 0) {
		return false;
	}
	const int cp = archetypes_[earch].comp_pos(oci);
	if (cp < 0) {
		return false;
	}
	++archetypes_[earch].row_ver[erow];
	auto &col = archetypes_[earch].cols[cp][ofi];
	switch (col.type) {
		case Variant::INT: {
			int32_t &w = col.i32[erow];
			switch (op) {
				case BATCH_ADD: w += int32_t(addend); break;
				case BATCH_MUL_ADD: w = int32_t(double(w) * factor + addend); break;
				case BATCH_SET: w = int32_t(addend); break;
				default: break;
			}
			break;
		}
		case Variant::FLOAT: {
			float &w = col.f32[erow];
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
				float &w = col.v2[erow][op_axis];
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
				float &w = col.v3[erow][op_axis];
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
	const int32_t erow = archetypes_[earch].row_of(entity);
	if (erow < 0) {
		return false;
	}
	const int cp = archetypes_[earch].comp_pos(oci);
	const int scp = archetypes_[earch].comp_pos(sci);
	if (cp < 0 || scp < 0) {
		return false;
	}
	++archetypes_[earch].row_ver[erow];
	auto &ocol = archetypes_[earch].cols[cp][ofi];
	const auto &scol = archetypes_[earch].cols[scp][sfi];
	if (ocol.type == Variant::FLOAT && (scol.type == Variant::FLOAT || scol.type == Variant::INT)) {
		const double sv = (scol.type == Variant::INT) ? double(scol.i32[erow]) : double(scol.f32[erow]);
		const float v = float(sv * factor + addend);
		float &w = ocol.f32[erow];
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
		const int32_t v = int32_t(double(scol.i32[erow]) * factor + addend);
		int32_t &w = ocol.i32[erow];
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
		Vector2 v = scol.v2[erow] * f;
		Vector2 &w = ocol.v2[erow];
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
		Vector3 v = scol.v3[erow] * f;
		Vector3 &w = ocol.v3[erow];
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
		const int32_t row = archetypes_[arch].row_of(entity);
		if (row < 0) {
			return false;
		}
		const int cp = archetypes_[arch].comp_pos(ci);
		if (cp < 0) {
			return false;
		}
		const auto &col = archetypes_[arch].cols[cp][c.field_idx];
		double val = 0.0;
		switch (col.type) {
			case Variant::INT: val = double(col.i32[row]); break;
			case Variant::FLOAT: val = double(col.f32[row]); break;
			case Variant::VECTOR2:
				if (c.axis >= 0 && c.axis < 2) val = double(col.v2[row][c.axis]);
				else return false;
				break;
			case Variant::VECTOR3:
				if (c.axis >= 0 && c.axis < 3) val = double(col.v3[row][c.axis]);
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
			archs[size_t(tgt_arch[0])].cols[size_t(tgt_cp[0])][size_t(fi)].type;
#define ECS_WRITE_CASE(ENUM, TYPE, WANT, MEMBER)                                                \
	case godot::Variant::ENUM: {                                                                \
		if (want == godot::Variant::WANT) {                                                     \
			const godot::TYPE p = src;                                                          \
			const auto *sp = p.ptr();                                                           \
			const int32_t sn = p.size();                                                        \
			for (size_t r = 0; r < n; ++r) {                                                    \
				const int32_t k = int32_t(r);                                                   \
				if (k < sn) {                                                                   \
					archs[size_t(tgt_arch[r])].cols[size_t(tgt_cp[r])][size_t(fi)]              \
							.MEMBER[size_t(tgt_row[r])] = sp[r];                                \
				}                                                                               \
			}                                                                                   \
			return;                                                                             \
		}                                                                                       \
	} break;
	switch (src.get_type()) {
		ECS_WRITE_CASE(PACKED_INT32_ARRAY, PackedInt32Array, INT, i32)
		ECS_WRITE_CASE(PACKED_FLOAT32_ARRAY, PackedFloat32Array, FLOAT, f32)
		ECS_WRITE_CASE(PACKED_BYTE_ARRAY, PackedByteArray, BOOL, b)
		ECS_WRITE_CASE(PACKED_VECTOR2_ARRAY, PackedVector2Array, VECTOR2, v2)
		ECS_WRITE_CASE(PACKED_VECTOR3_ARRAY, PackedVector3Array, VECTOR3, v3)
		ECS_WRITE_CASE(PACKED_VECTOR4_ARRAY, PackedVector4Array, VECTOR4, v4)
		ECS_WRITE_CASE(PACKED_COLOR_ARRAY, PackedColorArray, COLOR, col)
		default:
			break;
	}
#undef ECS_WRITE_CASE
	// 兜底: 字符串列 / 类型不符 / 缺列 → 逐行 set(默认值或源值), 不猜内存布局
	const bool from_src = src.get_type() == godot::Variant::PACKED_STRING_ARRAY;
	for (size_t r = 0; r < n; ++r) {
		const godot::Variant v = from_src ? agg_at(src, int32_t(r)) : fallback;
		archs[size_t(tgt_arch[r])].cols[size_t(tgt_cp[r])][size_t(fi)].set(size_t(tgt_row[r]),
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
				auto &ocol = a.cols[cp][ofi];
				auto &scol = a.cols[scp][sfi];
				if (ocol.type == Variant::VECTOR2 && scol.type == Variant::VECTOR2 && op == COL_ADD) {
					float *w = reinterpret_cast<float *>(ocol.v2.data());
					const float *s = reinterpret_cast<const float *>(scol.v2.data());
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
							ocol.v2[i] += scol.v2[i] * f;
						}
					}, 3.0);
					return cnt;
				}
				if (ocol.type == Variant::FLOAT && scol.type == Variant::FLOAT
						&& (op == COL_ADD || op == COL_SET)) {
					float *w = ocol.f32.data();
					const float *s = scol.f32.data();
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
					float *w = ocol.f32.data();
					const int32_t *s = scol.i32.data();
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
			auto &ocol = a.cols[cp][ofi];
			auto &scol = a.cols[scp][sfi];
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
				if (change_detection_) ++a.row_ver[erow];
				// 直接列间操作(参考 batch_apply_entity_col, 无 entity_arch_/row_of 间接)
				if (ocol.type == Variant::FLOAT && (scol.type == Variant::FLOAT || scol.type == Variant::INT)) {
					const double sv = (scol.type == Variant::INT) ? double(scol.i32[erow]) : double(scol.f32[erow]);
					const float v = float(sv * factor + addend);
					float &w = ocol.f32[erow];
					switch (op) {
						case COL_ADD: w += v; break;
						case COL_SUB: w -= v; break;
						case COL_MUL: w *= v; break;
						case COL_DIV: if (v != 0.0f) w /= v; break;
						case COL_SET: w = v; break;
						default: break;
					}
				} else if (ocol.type == Variant::INT && scol.type == Variant::INT) {
					const int32_t v = int32_t(double(scol.i32[erow]) * factor + addend);
					int32_t &w = ocol.i32[erow];
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
					Vector2 v = scol.v2[erow] * f;
					Vector2 &w = ocol.v2[erow];
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
					Vector3 v = scol.v3[erow] * f;
					Vector3 &w = ocol.v3[erow];
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
			const int32_t erow = archetypes_[earch].row_of(en);
			if (erow < 0) {
				continue;
			}
			const int cp = archetypes_[earch].comp_pos(oci);
			const int ncp = archetypes_[earch].comp_pos(nci);
			const int xcp = archetypes_[earch].comp_pos(xci);
			if (cp < 0 || ncp < 0 || xcp < 0) {
				continue;
			}
			auto &ocol = archetypes_[earch].cols[cp][ofi];
			const auto &minc = archetypes_[earch].cols[ncp][nfi];
			const auto &maxc = archetypes_[earch].cols[xcp][xfi];
			if (ocol.type == Variant::FLOAT && minc.type == Variant::FLOAT && maxc.type == Variant::FLOAT) {
				ocol.f32[erow] = std::clamp(ocol.f32[erow], minc.f32[erow], maxc.f32[erow]);
			} else if (ocol.type == Variant::INT && minc.type == Variant::INT && maxc.type == Variant::INT) {
				ocol.i32[erow] = std::clamp(ocol.i32[erow], minc.i32[erow], maxc.i32[erow]);
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
			const int32_t erow = archetypes_[earch].row_of(en);
			if (erow < 0) {
				continue;
			}
			const int pcp = archetypes_[earch].comp_pos(pci);
			const int vcp = archetypes_[earch].comp_pos(vci);
			if (pcp < 0 || vcp < 0) {
				continue;
			}
			auto &pcol = archetypes_[earch].cols[pcp][pfi];
			const auto &vcol = archetypes_[earch].cols[vcp][vfi];
			if (pcol.type == Variant::VECTOR2 && vcol.type == Variant::VECTOR2) {
				pcol.v2[erow] += vcol.v2[erow] * float(delta);
			} else if (pcol.type == Variant::VECTOR3 && vcol.type == Variant::VECTOR3) {
				pcol.v3[erow] += vcol.v3[erow] * float(delta);
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
			const int32_t row = archetypes_[arch].row_of(idx);
			const int32_t cp = archetypes_[arch].comp_pos(ci);
			if (row < 0 || cp < 0) {
				continue;
			}
			if (change_detection_) {
				++archetypes_[arch].row_ver[size_t(row)];
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
// ECSCore — Prefab 预制体
// ---------------------------------------------------------------------------

inline bool ECSCore::is_prefab_index(int32_t index) const {
	// 位图 O(1): 原先对 prefab_indices_ 线性扫, 而它在"每一行"上被调用 → O(N×P)
	return index >= 0 && index < int32_t(prefab_bitmap_.size()) && prefab_bitmap_[index] != 0;
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
	const int32_t prow = archetypes_[parch].row_of(pindex);
	if (prow < 0) {
		return result;
	}

	// 模板与实例组件组合相同 ⇒ 直接往**同一个 archetype 块**批量追加,
	// 不再"每实体一次 archetype 迁移 + 每字段一次字符串查找 + 每字段一次 Variant 装箱"。
	// (旧路径 5000 个实体要几万次字符串比较, 是刷怪/弹幕场景的真实瓶颈。)
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

	Archetype &dst = archetypes_[parch];
	const int32_t base = int32_t(dst.entities.size());
	dst.entities.resize(size_t(base + n));
	dst.row_ver.resize(size_t(base + n), 0);
	for (auto &comp_cols : dst.cols) {
		for (auto &col : comp_cols) {
			col.resize(size_t(base + n));
		}
	}

	// 行槽位: 实体索引 + 反向行号 + 所属块
	for (int32_t i = 0; i < n; ++i) {
		const int32_t idx = ecs_index_of(ids[i]);
		dst.entities[size_t(base + i)] = idx;
		if (int32_t(dst.row_map.size()) <= idx) {
			dst.row_map.resize(size_t(idx + 1), -1);
		}
		dst.row_map[size_t(idx)] = base + i;
		entity_arch_[size_t(idx)] = parch;
	}

	// 字段值: 按列整段拷模板行(同类型直拷, 不经过 Variant)
	for (int32_t cp = 0; cp < int32_t(dst.cols.size()); ++cp) {
		for (size_t fi = 0; fi < dst.cols[size_t(cp)].size(); ++fi) {
			ecs_copy_row_range(dst.cols[size_t(cp)][fi], size_t(prow), size_t(base), n);
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
				dst.cols[size_t(cp)][size_t(fi)].set(size_t(base + i), v);
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
	ClassDB::bind_method(D_METHOD("flush_commands"), &ECSCore::flush_commands);
	ClassDB::bind_method(D_METHOD("pending_command_count"), &ECSCore::pending_command_count);
	ClassDB::bind_method(D_METHOD("created_entity_at", "index"), &ECSCore::created_entity_at);
	ClassDB::bind_method(D_METHOD("row_of_entity", "comp", "entity"), &ECSCore::row_of_entity);
}
