#ifndef DECS_ECS_CORE_H
#define DECS_ECS_CORE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector4.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace godot {

// 实体 ID 打包: 低 20 位 index + 高 11 位版本号(代数)。
// 最高位必须保持 0 —— GDScript 侧用 `entity >= 0` 判有效/判命令占位句柄(负数)。
// 上限: 1,048,575 个同时存在的实体; 同一 index 复用 2048 次后版本号回绕(EnTT 同为有限位代数)。
constexpr int32_t ECS_INDEX_BITS = 20;   // 上限 1,048,575 个实体
constexpr int32_t ECS_INDEX_MASK = (1 << ECS_INDEX_BITS) - 1;
constexpr int32_t ECS_VERSION_MASK = (1 << (31 - ECS_INDEX_BITS)) - 1;

inline int32_t ecs_index_of(int32_t entity) { return entity & ECS_INDEX_MASK; }
inline int32_t ecs_version_of(int32_t entity) {
	return (entity >> ECS_INDEX_BITS) & ECS_VERSION_MASK;
}

// ---------------------------------------------------------------------------
// 稀疏集已于 2026-11 删除: 存储改用 architectural 原型分块(见下方 Archetype),
// 该结构只剩实现无调用方, 留着只会误导后续优化。
// ---------------------------------------------------------------------------
// SoA 列存储: 每组件每字段一块连续裸内存 (C++ std::vector)。
// 用自管裸内存而非 Godot PackedArray —— 多线程并行写不同行天然安全(无共享引用计数),
// 为"系统级 + 实体级并行"铺路(路径 A)。对外 get_column/set_column 时再转换 PackedArray(拷贝)。
// 列下标 = dense 行号 (0..拥有该组件的实体数-1, 紧凑连续, 缓存友好)。
// 实体 ID 需经 sparse[entity] 映射为行号 (O(1)), 由 ECSCore 内部处理。
// ---------------------------------------------------------------------------
struct ECSColumn {
	Variant::Type type = Variant::NIL;
	// 单块字节缓冲: 元素按 type 紧排(stride 由 type 决定)。
	// 早先是 8 个 std::vector 的联合体 —— 每个列常驻 8×24B 的空头部, 8 个字段的组件就是 1.5KB
	// 纯空转, 且访问要过 8 个分支。现在只剩一个指针 + 长度, 访问器按类型 reinterpret。
	std::vector<uint8_t> bytes;
	// STRING 是非平凡类型(String 有构造/析构), 不能塞进字节缓冲, 单独一列。
	std::vector<String> s;

	static size_t stride(Variant::Type t);

	template <typename T>
	T *ptr() {
		return reinterpret_cast<T *>(bytes.data());
	}
	template <typename T>
	const T *ptr() const {
		return reinterpret_cast<const T *>(bytes.data());
	}
	template <typename T>
	T &at(size_t row) {
		return ptr<T>()[row];
	}
	template <typename T>
	const T &at(size_t row) const {
		return ptr<T>()[row];
	}

	void resize(size_t n);
	void push_default(const Variant &value);
	void pop();                 // 移除末尾行(swap-remove 时同步)
	Variant get(size_t row) const;
	void set(size_t row, const Variant &value);
	size_t size() const;
	// 裸写指针(供 batch 并行写不同行; 与 PackedArray 的 ptrw 语义对齐)
	void *write_ptr();
	// 裸读指针
	const void *read_ptr() const;
};

struct ECSField {
	StringName name;
	Variant::Type type;
};

struct ECSComponentData {
	StringName name;
	std::vector<ECSField> fields;
	std::vector<Variant> defaults; // 每字段默认值, 迁移/新增组件时填充

	int field_index(const StringName &f) const;
};

// 条件过滤项(batch 条件用, 组件组合过滤)
struct ECSFilterCond {
	const ECSComponentData *comp = nullptr;
	int field_idx = -1;
	int32_t op = 0;
	double value = 0.0;
	int axis = -1;
	int32_t comp_idx = -1; // 组件注册索引(parse 后填充, 供快路径避免逐次 comp_index 扫描)
};

// ---------------------------------------------------------------------------
// Archetype: 按组件组合分块的存储(archetype ECS, 参考 Flecs/Bevy/Unity DOTS)。
// 每个 archetype 拥有"组件组合相同"的实体, 列数据独立成块(SoA, 块内行连续)。
//  - comps: 升序组件索引(components_ 下标)
//  - cols:  [comp_pos][field] 的列, 行号 = 实体在块内的行(0..entities.size()-1)
//  - entities: 实体 index(行号 = 下标); row_map: 实体 index -> 行号(-1)
// 查询只遍历匹配的 archetype 块 → O(结果数) + 块内连续(缓存友好) + 块级并行。
// ---------------------------------------------------------------------------
struct Archetype {
	std::vector<int32_t> comps;
	// 扁平列存储: cols[col_off[cp] + fi]。早先是 vector<vector<ECSColumn>>(两层):
	// 每块每组件一次小分配, 且每次字段访问多一次指针追逐。
	std::vector<ECSColumn> cols;
	std::vector<int32_t> col_off;            // 每组件起始下标; size = comps.size()+1(末位=总列数)
	std::vector<int32_t> entities;            // 实体 index
	// 注: 行号映射已上移到 ECSCore::entity_row_(全局一张表)。
	// 这里是 std::vector<int32_t> row_map(每块按最大实体下标开的稀疏表), 内存是 4 × 块数 × 池大小,
	// 20 个块 + 池涨到 100 万就是 80MB, 且只写 -1 从不缩容 —— 长会话里的泄漏型增长。
	std::vector<uint64_t> row_ver;            // 每行写版本(变更检测: 写时递增; 64 位避免回绕)
	uint64_t bits = 0;                        // 组件位集(comp < 64, 参考 Flecs/Bevy 位匹配)

	// 组件位置(升序 comps): 用位集 popcount O(1)(comp<64), 超 64 fallback 二分
	inline int comp_pos(int32_t comp) const {
		if (comp < 64 && ((bits >> comp) & 1)) {
			return __builtin_popcountll(bits & ((1ULL << comp) - 1));
		}
		auto it = std::lower_bound(comps.begin(), comps.end(), comp);
		if (it != comps.end() && *it == comp) {
			return int(it - comps.begin());
		}
		return -1;
	}
	inline bool has_comp(int32_t comp) const {
		if (comp < 64) {
			return ((bits >> comp) & 1) != 0;
		}
		return std::binary_search(comps.begin(), comps.end(), comp);
	}
	inline int32_t col_count(int cp) const { return col_off[size_t(cp) + 1] - col_off[size_t(cp)]; }
	// 带边界检查的列访问。**越界不再返回野指针**: 打一条错误, 返回一个空列(写=丢弃, 读=默认值)。
	// 上次崩溃就是"把总字段数当组件数"导致 cp 越界读 col_off —— 有这层检查就只会红不会崩。
	inline ECSColumn &col_at(int cp, int fi) {
		if (cp < 0 || size_t(cp) + 1 >= col_off.size() || fi < 0 || fi >= col_count(cp)) {
			ERR_PRINT("ECS: col_at() 越界 (cp/fi 超出该块的组件与字段范围)");
			static ECSColumn dummy;
			return dummy;
		}
		return cols[size_t(col_off[size_t(cp)] + size_t(fi))];
	}
	inline const ECSColumn &col_at(int cp, int fi) const {
		if (cp < 0 || size_t(cp) + 1 >= col_off.size() || fi < 0 || fi >= col_count(cp)) {
			ERR_PRINT("ECS: col_at() 越界 (cp/fi 超出该块的组件与字段范围)");
			static ECSColumn dummy;
			return dummy;
		}
		return cols[size_t(col_off[size_t(cp)] + size_t(fi))];
	}
};

// ---------------------------------------------------------------------------
// ECSCore — 唯一对外原生类 (GDScript 侧经 ECSNative 桥接访问)
// ---------------------------------------------------------------------------
class ECSCore : public RefCounted {
	GDCLASS(ECSCore, RefCounted)

protected:
	static void _bind_methods();

public:
	// ---- 组件注册 ----
	// name: 组件类名; fnames: 字段名; ftypes: 字段 Variant::Type; fdefaults: 默认值
	int32_t register_component(const StringName &name, const PackedStringArray &fnames,
			const PackedInt32Array &ftypes, const Array &fdefaults);

	// 内部标记组件(名字以 "__" 开头, 对 GDScript 隐藏, 不进存档)。
	// 用途: 让 prefab 实体落在**独立 archetype 块**里 —— 否则模板与实例同块, 每次聚合/批量写
	// 都会因为"块内有 prefab"退化到逐行 Variant 装箱(实测 20k 单列 30µs → 块内纯 memcpy 2µs)。
	int32_t prefab_tag();
	bool is_internal_comp(int32_t ci) const;

	// ---- 实体 ----
	int32_t create_entity();
	bool is_alive(int32_t entity) const;
	void destroy_entity(int32_t entity);

	// ---- 组件增删查 ----
	bool add_component(int32_t entity, const StringName &comp);
	bool has_component(int32_t entity, const StringName &comp) const;
	void remove_component(int32_t entity, const StringName &comp);
	int32_t count_entities(const StringName &comp) const;
	// 枚举实体的全部组件名(低频: destroy 前收集钩子信息用)
	PackedStringArray get_entity_components(int32_t entity) const;
	// 按 archetype(组件组合)分组枚举实体(调试/查看器用): Array[Dictionary{comps, entities}]。
	Array get_archetype_groups() const;
	// 当前 archetype 块数量(含空块)。
	int32_t archetype_count() const;
	// 压缩空块: 长跑游戏反复刷怪/死亡会让"已经没有实体的组件组合块"越积越多,
	// 聚合与遍历每帧都要跳过它们。移除后会重建块下标与匹配/迁移缓存, 返回移除数量。
	int32_t compact_archetypes();

	// ---- 查询 ----
	// 返回匹配实体的实体 ID 列表(可直接 get_field/set_field, archetype 下最直观的查询)。
	PackedInt32Array query_entities(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	// 返回匹配实体的聚合行号(该组件 get_column 的索引, 供列索引/对齐用)。
	PackedInt32Array query_rows(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	// 对齐行号查询: 一次返回多组件的对齐 dense 行号数组。
	// 返回 Array: [0] = anchor 组件的 dense 行号, [1..] = 对应 must[i] 的组件行号。
	// 第 k 个匹配实体在 anchor 的第 rows[0][k] 行、在 must[i] 的第 rows[1+i][k] 行,
	// 可直接用同一索引 k 并行索引各组件列(免去逐实体跨组件行号转换)。
	Array query_rows_aligned(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without) const;
	// 对齐行号 + 条件过滤: 同 query_rows_aligned, 但只返回满足 conditions 的实体,
	// 且对齐输出的组件由 comps 显式指定(不必是 must 子集)。
	// 返回 Array: [0] = anchor 行号(已过滤), [1..] = 对应 comps[i] 的对齐行号。
	Array query_rows_aligned_where(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without, const Array &conditions,
			const PackedStringArray &comps) const;
	int32_t entity_of_row(const StringName &comp, int32_t row) const;
	// 聚合行号(某组件的 get_column 索引) -> 实体 ID(archetype 下跨块聚合顺序)。
	int32_t get_entity_at(const StringName &comp, int32_t row) const;
	// 变更检测: 返回该组件所有"行版本 > since"的聚合行号(增量同步/系统用)。
	// 全局写入序号: 每次写把一个**全局自增**的值盖到该行的 row_ver 上(而不是每行自增)。
	// 这样 get_changed(comp, since) 的 since 才是"时间点"而不是"该行被写过几次"。
	int64_t write_tick() const { return int64_t(write_tick_); }

	// 查询级变更过滤(Bevy Changed<T> / flecs changed 的等价物):
	// 返回 row_ver > since 的行, 行序与 columns_of 一致 → 渲染/UI 只处理变化的行。
	// since 用 int64(与 64 位 row_ver 同宽, 不会回绕); 传 0 等于全量。
	PackedInt32Array get_changed(const StringName &comp, int64_t since) const;
	// 变更检测开关(默认关: 避免全量写标记开销; 开启后 batch 写递增行版本, 供 get_changed 增量查询)。
	void set_change_detection(bool enabled);
	bool is_change_detection() const;

	// ---- 单实体字段访问 (低频路径) ----
	Variant get_field(int32_t entity, const StringName &comp, const StringName &field) const;
	void set_field(int32_t entity, const StringName &comp, const StringName &field, const Variant &value);

	// ---- 列访问: 读用 get_columns(一次跨语言取多列), 写用 set_columns ----
	// 单列版保留为便捷封装(内部同一条聚合路径), 逐帧多列请用 get_columns。
	Variant get_column(const StringName &comp, const StringName &field) const;
	void set_column(const StringName &comp, const StringName &field, const Variant &values);
	// 一次取多组件多列, 减少跨语言调用次数。
	// comps_fields: Array[{comp: name, fields: PackedStringArray}]
	// 返回 {compName: {fieldName: PackedArray}}
	Dictionary get_columns(const Array &comps_fields) const;
	// 一次写回多组件多列: values = {compName: {fieldName: PackedArray}}
	// (与 get_columns 返回结构一致), 一次跨语言替代 N 次 set_column。
	void set_columns(const Dictionary &values);

	// ---- 空间索引(统一网格): RTS/弹幕的"附近"查询, 避免每帧全表扫 ----
	// 业界做法(flecs 无内置, 常见是格子哈希/四叉树; Bevy 靠 avian 等插件): 网格最省事且 O(1) 插删。
	// 启用: 指定"位置组件 + 位置字段(必须是 VECTOR2) + 格子边长"。
	// 维护: 结构变更/该列写入时标脏, 下一次查询时**整表重建**(O(n), 20k 约 100µs) ——
	// 比"每次 set_field 增量更新"简单且不会漏; 无写入的帧不会重建。
	void spatial_enable(const StringName &comp, const StringName &field, double cell_size);
	void spatial_disable();
	// 标脏(由 GDScript 在 _mark_dirty(该组件) 时调用): 结构变化走这条(整表重建)。
	void spatial_invalidate() { spatial_mark_dirty(); }
	// 单实体增量更新: 只把该实体从旧格子挪到新格子(O(1))。
	// 逐帧"每个单位都动"的场景下, 整表重建(O(n)+哈希)比全表扫还慢(实测 0.110ms vs 0.056ms);
	// 走增量后, 值写入不再触发重建, 只有增删组件/实体才重建。
	void spatial_update_entity(int32_t id);
	// 返回落在矩形/圆内的**实体 id**(升序, 保证确定性; 不含 prefab)。
	PackedInt32Array spatial_query_rect(const Vector2 &min_pos, const Vector2 &max_pos);
	PackedInt32Array spatial_query_radius(const Vector2 &center, double radius);
	// {enabled, cells, entities, dirty, cell_size}
	Dictionary spatial_stats();

	// 内部 prefab 标记组件: 世界初始化时调用一次(幂等, 组件名 `__prefab`)。
	// 作用是让模板落到独立 archetype; is_internal_comp 已在上面声明。
	void set_prefab_tag(const StringName &comp);

	// ---- 层级索引(原生反向表 parent → children) ----
	// 组件语义(ECSParent.target)仍由 GDScript 维护, 这里只承担**索引**:
	// 上万子节点时 Dictionary 的逐次数组分配与线性 erase 是主要开销。
	// 与列存储无耦合(不碰 cols/col_off), 所以是重构中最安全的一块。
	void hierarchy_set_parent(int32_t child, int32_t parent);
	// 批量挂父: 组件(target)与反向索引都在原生侧一次做完。
	// 单独 set_parent 每次要 4 次跨语言(get_parent/set_field|add_component/hierarchy_set_parent),
	// 实测 1 万个 = 81.7ms; 批量版只 1 次跨语言。
	// ⚠ 不逐实体触发组件 hook(与其它 batch_* 一致的取舍), 需要 hook 请用单条 set_parent。
	void set_parent_bulk(const PackedInt32Array &children, int32_t parent, const StringName &parent_comp);
	void hierarchy_remove_child(int32_t parent, int32_t child);
	PackedInt32Array hierarchy_children(int32_t parent) const;
	// 销毁前调用: 返回并清空该实体的子列表(调用方负责把子实体的父置 -1)。
	PackedInt32Array hierarchy_detach(int32_t entity);
	int32_t hierarchy_child_count(int32_t parent) const;

	// ---- 确定性查询: 按字段值排序的行集 ----
	// 联机/回放要求"同样的输入 → 同样的遍历顺序"。行集本身按块内行号稳定,
	// 但需要按业务键(如距离/血量)排序时必须有确定性的并列规则 → 这里以实体 id 作次键。
	PackedInt32Array query_rows_sorted(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without, const StringName &field, bool descending = false);

	// ---- Tier 0: 原生批量运算 (纯 C++ 循环, 无 GDScript 解释开销) ----
	enum BatchOp { BATCH_ADD = 0, BATCH_MUL_ADD = 1, BATCH_SET = 2, BATCH_CLAMP = 3 };
	// 条件比较符
	enum CondOp { COND_LT = 0, COND_LE = 1, COND_GT = 2, COND_GE = 3, COND_EQ = 4, COND_NE = 5 };
	// batch_apply 带条件版本: conditions 为 Array[Dictionary], 每项 {comp, field, op, value}
	// 仅对满足全部条件的实体执行 op。返回处理的实体数。
	int64_t batch_apply_where(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend, const Array &conditions);
	// 统计满足条件的实体数(纯查询, 不修改)
	int64_t batch_count(const StringName &anchor, const PackedStringArray &must,
			const Array &conditions) const;
	int64_t batch_apply(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend);
	int64_t batch_clamp(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field,
			const StringName &min_comp, const StringName &min_field,
			const StringName &max_comp, const StringName &max_field);
	int64_t batch_vec_add(const StringName &anchor, const PackedStringArray &must,
			const StringName &pos_comp, const StringName &pos_field,
			const StringName &vel_comp, const StringName &vel_field, double delta);

	// ---- Tier 0 扩展: 列间运算 (col = col OP (src * factor) + addend) ----
	enum ColOp { COL_ADD = 0, COL_SUB = 1, COL_MUL = 2, COL_DIV = 3, COL_SET = 4 };
	// 对满足条件的实体: 用 src 组件字段列对 op 组件字段列做运算。
	// ADD/SUB/MUL/DIV: col OP= (src*factor+addend); SET: col = src*factor+addend。
	// 支持 INT/FLOAT/VECTOR2/VECTOR3(Vector 忽略 addend, 用 factor 标量缩放)。
	int64_t batch_apply_col(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field,
			const StringName &src_comp, const StringName &src_field,
			int64_t op, double factor, double addend, const Array &conditions);
	// 带条件过滤的列钳制: col = clamp(col, min, max)(仅满足 conditions 的实体)。
	int64_t batch_clamp_where(const StringName &anchor, const PackedStringArray &must,
			const StringName &op_comp, const StringName &op_field,
			const StringName &min_comp, const StringName &min_field,
			const StringName &max_comp, const StringName &max_field,
			const Array &conditions);



	// ---- Tier 0 优化: 批量收集 + 行集动作(一次扫描多组条件, 动作复用行集) ----
	// 单次遍历匹配签名实体, 同时判定多组条件, 产出多组 anchor 行号(复用 rows 缓冲)。
	// groups: Array, 每组 = Array[Dictionary](conditions, 同 batch_apply_where 格式, 空=无条件)。
	// 返回 Array[PackedInt32Array], 第 i 组对应 groups[i] 满足条件的实体 anchor 行号。
	// 相比逐查询各自 collect, 同一 anchor 的多组条件只需一次遍历(条件解析也只做一次)。
	Array batch_collect(const StringName &anchor, const PackedStringArray &must,
			const PackedStringArray &without, const Array &groups) const;
	// 对预收集的行集做标量批量动作(跳过收集): rows 为 anchor 行号。
	// 支持向量分量字段(如 "vel.x")。与 batch_apply_where 的 op/factor/addend 语义一致。
	int64_t batch_apply_rows(const StringName &anchor, const PackedInt32Array &rows,
			const StringName &op_comp, const StringName &op_field, int64_t op,
			double factor, double addend);
	// 对预收集的行集做列间动作(跳过收集): col = col OP (src*factor+addend)。
	int64_t batch_apply_col_rows(const StringName &anchor, const PackedInt32Array &rows,
			const StringName &op_comp, const StringName &op_field,
			const StringName &src_comp, const StringName &src_field,
			int64_t op, double factor, double addend);
	// 批量执行多个动作(一次跨语言, 免逐动作跨语言调用)。
	// actions: Array[Dictionary], 每项 {t:0=col,1=scalar, of, sf, sc?, op, f, v/add}。
	int64_t batch_apply_actions(const StringName &anchor, const PackedInt32Array &rows,
			const Array &actions);

	// 内存统计(调试)
	Dictionary debug_stats() const;

	// ---- 序列化/反序列化 (对接 SaveTool 存档) ----
	// 序列化整个世界: 返回 {components: [{name, fields:[{name,type}], defaults:[...],
	//   entities: [{entity, values:[...]}]}], pool_size}
	// 字段值按注册顺序排列; 无组件实体不参与(仅组件数据)。
	Dictionary serialize() const;
	// 反序列化: 重建组件注册 + 实体 + 数据。
	// 返回 Array[int]: 新建实体的真实实体 ID 列表(调用方用它绑定 EntityView 等)。
	// 注意: 需先 register_component 同名的组件(名称一致), 否则忽略该组件数据。
	Array deserialize(const Dictionary &data);

	// ---- Prefab 预制体 (模板实体 + 批量实例化) ----
	// 创建 prefab 模板实体(普通实体 + 内部模板标记, 不参与普通查询/序列化)
	int32_t create_prefab();
	// 该实体是否为 prefab 模板
	bool is_prefab(int32_t entity) const;
	// 给 prefab 模板添加组件并设置初始字段值。
	// values: Dictionary {field_name: value}
	bool prefab_add(int32_t prefab, const StringName &comp, const Dictionary &values);
	// 批量实例化: 复制 prefab 的组件结构与字段值到 count 个新实体。
	// overrides: Dictionary {comp_name: {field_name: value}} 字段覆盖(可选)
	// 返回新实体 ID 数组。
	Array instantiate(int32_t prefab, int32_t count, const Dictionary &overrides);


	// 供条件过滤解析内部使用
	const ECSComponentData *find_comp(const StringName &name) const;

	// ---- Command Buffer 延迟结构变更 ----
	// 系统内排队 create/destroy/add/remove, flush_commands() 时统一执行。
	// 好处: 系统遍历中不直接改结构(无重入/迭代失效), 为系统并行执行铺路。
	enum CmdType { CMD_CREATE = 0, CMD_DESTROY = 1, CMD_ADD_COMP = 2, CMD_REMOVE_COMP = 3 };
	void cmd_create();                             // 排队创建(返回实体在 flush 时生成, 这里返回占位 -2)
	void cmd_destroy(int32_t entity);
	void cmd_add_component(int32_t entity, const StringName &comp);
	void cmd_remove_component(int32_t entity, const StringName &comp);
	// 批量入队: 逐条 cmd_* 在 GDScript 里是 N 次跨语言调用(2000 实体 = 4000 次),
	// 实测比"直接改结构"还慢 70% —— defer 一旦变慢就会被绕开, 而绕开会在遍历中改结构。
	// 这几个接口把 N 次调用压成 1 次, flush 语义完全不变。
	PackedInt32Array cmd_create_many(int32_t count);
	void cmd_add_many(const PackedInt32Array &entities, const StringName &comp);
	void cmd_destroy_many(const PackedInt32Array &entities);
	void flush_commands();                        // 执行全部排队命令(帧末调用)
	int32_t pending_command_count() const;
	int32_t created_entity_at(int32_t index) const; // 查询第 index 个 create 生成的实体

	// 行号 -> 实体 / 实体 -> 行号 (dense 紧凑存储的转换)
	int32_t row_of_entity(const StringName &comp, int32_t entity) const;

private:
	// ---- 内部 ----
	ECSComponentData *find_comp(const StringName &name);
	int32_t comp_index(const StringName &name) const;
	inline bool is_prefab_index(int32_t index) const;

	// archetype 内部: 组件组合分块(替代原签名索引)
	int32_t find_archetype(const std::vector<int32_t> &comps);
	int32_t allocate_entity_id();
	void release_entity_id(int32_t index);
	// 把实体迁移到新 archetype(拷贝列数据; 新组件填默认值)。
	void migrate_entity(int32_t index, int32_t src_arch, int32_t dst_arch);
	// 从 archetype 移除实体(swap-remove + 列同步)。
	void remove_from_archetype(int32_t arch, int32_t index);
	// 在已排序 comps 中插入 comp(保持升序, 已存在则忽略)。
	static void sorted_insert(std::vector<int32_t> &comps, int32_t comp);
	// 收集匹配 archetype(含 anchor+must, 不含 without), 返回缓存中的 archetype 索引列表。
	// archetype 只增不删 ⇒ 缓存按"已扫描到哪"增量补齐, 结构变更时无需整体清空。
	const std::vector<int32_t> &collect_archs(int32_t ai, const int32_t *mi, int32_t m,
			const int32_t *wi, int32_t w) const;
	// 含某组件的全部 archetype(无 must/without 过滤), 供行号聚合/变更检测复用同一缓存。
	const std::vector<int32_t> &archs_with(int32_t ci) const;
	// 收集满足 must/without/conditions 的 anchor 聚合行号(batch 用)。
	void collect_agg(int32_t ai, const int32_t *mi, int32_t m,
			const int32_t *wi, int32_t w, const Array &conditions,
			std::vector<int32_t> &out) const;
	// 跨块列聚合(get_column/borrow 用): 含 ci 的 archetype 块按序拼接非 prefab 实体值。
	Variant column_aggregate(int32_t ci, int32_t fi) const;
	// 跨块列拆回(set_column/return 用): 聚合 PackedArray 按序写回各块。
	void column_scatter(int32_t ci, int32_t fi, const Variant &values);
	// 单实体标量/分量列操作(batch 用): 实体拥有的 op 组件列按 op/factor/addend 修改。
	bool batch_apply_entity(int32_t entity, int32_t oci, int32_t ofi, int32_t op_axis,
			int64_t op, double factor, double addend);
	// 单实体列间操作: op 列 = op 列 OP (src 列*factor+addend)。
	bool batch_apply_entity_col(int32_t entity, int32_t oci, int32_t ofi, int32_t sci, int32_t sfi,
			int64_t op, double factor, double addend);
	// 单实体是否满足全部条件(直接读 archetype 列, 快路径)。
	bool cond_matches_entity(int32_t entity, const std::vector<ECSFilterCond> &conds) const;

	// ---- 存储(archetype 分块) ----
	std::vector<ECSComponentData> components_;   // 组件注册元数据(无数据列)
	std::vector<Archetype> archetypes_;          // 组件组合分块存储
	// 实体池: index | (version << 24), 复用防悬垂
	std::vector<uint32_t> versions_;
	std::vector<int32_t> free_list_;
	// 实体 index -> 所属 archetype(-1 = 无组件)
	std::vector<int32_t> entity_arch_;
	// 实体 index -> 所在块内的行号(全局一张表, 与 entity_arch_ 同步维护)。
	// 取代了原先"每块一张按最大实体下标开的稀疏 row_map": 内存从 4×块数×池大小 降到 4×池大小,
	// 且少一次间接寻址(row_of 一次索引, 原来要先按 index 查块内稀疏表)。
	std::vector<int32_t> entity_row_;
	uint64_t write_tick_ = 0;   // 全局写入序号(见 write_tick())
	inline int32_t row_of(int32_t index) const {
		return (index >= 0 && index < int32_t(entity_row_.size())) ? entity_row_[size_t(index)] : -1;
	}
	// 查询缓存: 查询签名(anchor+must+without 组件索引) -> 匹配 archetype 列表。
	// scanned = 已扫描到的 archetypes_ 下标: archetype 只增不删, 新查询只需补扫新增部分。
	struct ArchMatch {
		uint32_t scanned = 0;
		std::vector<int32_t> ids;
	};
	mutable std::unordered_map<uint64_t, ArchMatch> _arch_cache;
	// 变更检测开关
	bool change_detection_ = false;
	// prefab 模板标记: 按实体 index 的位图(O(1) 判定, 取代原先的线性扫描)
	std::vector<uint8_t> prefab_bitmap_;
	// 内部 prefab 标记组件(注册索引; -1 = 尚未注册)
	int32_t prefab_tag_comp_ = -1;
	// 块内"是否含 prefab 行"的缓存(按 struct_version_ 失效)。
	// 聚合/散射是**每列**调用一次, 若每次都扫一遍块(20k 行), 5 列就要扫 10 万次 ——
	// 实测 5 列 128µs vs 1 列 15µs, 多出来的全是这个扫描。
	mutable std::vector<int8_t> prefab_flag_;   // -1 未知 / 0 无 / 1 有
	mutable uint64_t prefab_flag_ver_ = ~uint64_t(0);
	// 组件名 -> components_ 下标(注册时填一次, 之后只读 —— 并行系统里查也安全)
	std::unordered_map<uint64_t, int32_t> component_index_;
	// 块内是否含 prefab 行(带 struct_version_ 缓存): 聚合/散射按列调用, 不能每列都扫全块。
	// 实测 5 列 128µs → 78µs(去掉的是 5 × 2 万行的重复扫描)。
	bool arch_has_prefab(int32_t arch, const Archetype &a) const;

	// prefab 行位置缓存(按 struct_version_ 失效)。
	// 聚合/散射是**每列**调用一次; 早先每次都做两趟 O(行数) 扫描(数非 prefab 行 + 逐行判 prefab),
	// 20k × 5 列 = 20 万次判定 —— 实测 5 列 68µs 里绝大部分是这个。缓存后每列只剩纯 memcpy。
	struct ArchPrefabInfo {
		int32_t non_prefab = 0;      // 非 prefab 行数(聚合总长直接累加它)
		std::vector<int32_t> rows;   // prefab 行号(升序, 拷贝时按它切段)
	};
	const ArchPrefabInfo &arch_prefab_info(int32_t arch, const Archetype &a) const;
	mutable std::vector<ArchPrefabInfo> prefab_info_;
	mutable uint64_t prefab_info_ver_ = ~uint64_t(0);
	mutable std::mutex arch_cache_mutex_;   // 并行批量算子也会读这些缓存 → 串行化

	// 空间索引状态: 统一网格(格子 → 实体 id 列表)。dirty 时下次查询整表重建。
	int32_t spatial_comp_ = -1;
	int32_t spatial_field_ = -1;
	float spatial_cell_ = 0.0f;
	bool spatial_dirty_ = true;
	bool spatial_enabled_ = false;
	std::unordered_map<int64_t, std::vector<int32_t>> spatial_cells_;
	// 实体 id → 所在格子。增量更新时用它 O(1) 找到旧格子, 避免全表扫描。
	std::unordered_map<int32_t, int64_t> spatial_owner_;
	// 层级反向索引: parent → children(原生, 取代 GDScript 的 Dictionary)
	std::unordered_map<int32_t, std::vector<int32_t>> children_;
	int32_t spatial_built_entities_ = 0;
	void spatial_mark_dirty();
	void spatial_rebuild();
	static int64_t spatial_key(int32_t cx, int32_t cy);

	// archetype 迁移图(flecs 的 "edge" 缓存): (源块, 组件) → 目标块。
	// find_archetype 是线性扫全部块, 每次 add/remove 都扫一遍; 组件组合一多(100+ 块)会退化。
	// 块只增不删 ⇒ 边一旦算出永远有效, 无需失效。
	std::unordered_map<uint64_t, int32_t> arch_edge_add_;
	std::unordered_map<uint64_t, int32_t> arch_edge_remove_;

	// ---- 并行线程池 (batch 分片并行) ----
	mutable std::vector<std::thread> workers_;
	mutable std::mutex task_mutex_;
	mutable std::condition_variable task_cv_;
	mutable std::vector<std::function<void()>> tasks_;
	mutable bool workers_stop_ = false;
	mutable int active_tasks_ = 0;
	mutable bool workers_started_ = false;
	int thread_count_ = 0;

	// ---- Command Buffer 队列 ----
	std::vector<int32_t> cmd_types_;         // CmdType
	std::vector<int32_t> cmd_entities_;      // 实体ID(占位或真实)
	std::vector<StringName> cmd_comps_;      // 组件名(add/remove 用)
	std::vector<int32_t> cmd_created_;       // flush 时生成的新实体 ID
	// 一批命令的第一个操作入队时清空上一批的 cmd_created_(否则占位序号会错位)
	void ensure_cmd_batch();

	void ensure_workers();
	void stop_workers();
	// 设置线程数(0=自动按硬件, 1=单线程/串行, 用于调试对比)
	void set_thread_count(int count);
	// 并行执行: 把 [0, n) 切成 slices 片, 每片一个线程执行 fn(work_begin, work_end)
	// cost_per_item: 每项工作量权重(高成本操作更早并行), 默认 1.0。
	template <typename F>
	void parallel_for(size_t n, F &&fn, double cost_per_item = 1.0);
	// 系统批并行执行(复用持久 worker 池, 免每帧临时建线程)。
	// systems: Array[Callable](无参, 已 bind 系统+上下文)。主线程执行第一个, worker 池并行其余。
	void run_systems_parallel(const Array &systems);

	// 批量把 ECS 组件字段列写入节点属性(ECSSyncSystem 的 C++ 内层, 省 GDScript 循环解释)。
	// nl_rows: NodeLink 行号(dense); comp_rows: 与 nl_rows 对齐的 comp 组件行号;
	// nodes: Array[Node], 索引 = NodeLink 行号(允许 null);
	// comp: 组件名; fields: 字段名; props: 节点属性名(与 fields 等长)。
	// ---- MultiMesh 批量渲染(调用方**显式**选择的视图后端) ----
	// 一次跨语言把"实体列(pos/rot/scale/color)"写进多个 MultiMesh, 按 `layer` 字段分组:
	//   meshes[layer] = MultiMesh(或 null)。
	// 逐实例 set_instance_transform_2d 仍在 C++ 内完成 —— 省掉"GDScript 逐节点写 property"
	// 那一层(后者在 10k 实例时是主要瓶颈)。每帧调用一次即可。
	// 返回**实际写入的实例数**: 调用方用它判断有无实体落在未绑定 layer 上(诊断用, 不做隐式回退)。
	int64_t multimesh_sync(const StringName &comp, const PackedInt32Array &entities,
			const StringName &f_layer, const StringName &f_pos, const StringName &f_rot,
			const StringName &f_scale, const StringName &f_color, const Array &meshes);

	void sync_fields(const PackedInt32Array &nl_rows, const PackedInt32Array &comp_rows,
			const Array &nodes, const StringName &comp,
			const PackedStringArray &fields, const PackedStringArray &props);
	// 服务器直连总开关(set_sync_direct)。false 时全部走节点 setter(节点属性同步, 稍慢)。
	void set_sync_direct(bool v);
	bool get_sync_direct() const;

	// sync_fields 缓存: 结构版本变化时重建(cref 聚合行号 / 节点指针 / 字段索引)。
	struct SyncRuleCache {
		uint32_t version = 0;
		int32_t comp = -1;
		std::vector<std::pair<int32_t, int32_t>> cref;  // comp 聚合行号 -> (arch,row)
		std::vector<Object *> nodes;                    // nl_row -> Node*(与 nodes Array 对齐)
		std::vector<int32_t> field_idx;                 // fields -> 组件字段索引
		std::vector<StringName> props;                  // 写属性名
		std::vector<int32_t> direct_kind;               // 每字段服务器直连类型(0=无, 见 sync_direct_kind)
	};
	// 结构版本号: 实体/组件增删时自增, 使结构相关缓存失效。
	uint32_t struct_version_ = 0;
	// 按组件索引的 sync 缓存(懒建)。
	std::vector<SyncRuleCache> sync_cache_;
	// 服务器直连总开关: true 时 position/transform/modulate/visible/z_index 走 RenderingServer 直连
	// (跳过节点 setter/transform 标记, 更快)。默认 false: 直连只改渲染, 节点属性不更新,
	// 会导致碰撞(基于节点 transform)、拾取、依赖属性读取的逻辑拿到旧值而异常。需要时显式开启。
	bool sync_direct_ = false;

public:
	~ECSCore();
};

} // namespace godot

#endif // DECS_ECS_CORE_H
