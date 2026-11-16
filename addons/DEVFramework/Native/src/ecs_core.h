#ifndef DECS_ECS_CORE_H
#define DECS_ECS_CORE_H

#include <godot_cpp/classes/ref_counted.hpp>
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
	std::vector<int32_t> i32;   // INT
	std::vector<float> f32;     // FLOAT
	std::vector<uint8_t> b;     // BOOL (bool 位打包不利多线程写, 用 uint8)
	std::vector<Vector2> v2;    // VECTOR2
	std::vector<Vector3> v3;    // VECTOR3
	std::vector<Vector4> v4;    // VECTOR4
	std::vector<Color> col;     // COLOR
	std::vector<String> s;      // STRING (引用计数, 列并行写不适用; 低频字段用)

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
	std::vector<std::vector<ECSColumn>> cols; // [comp_pos][field]
	std::vector<int32_t> entities;            // 实体 index
	std::vector<int32_t> row_map;             // 实体 index -> 行号(-1)
	std::vector<uint32_t> row_ver;            // 每行写版本(变更检测: 写时递增)
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
	inline int32_t row_of(int32_t entity) const {
		return (int32_t(entity) < int32_t(row_map.size())) ? row_map[entity] : -1;
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
	PackedInt32Array get_changed(const StringName &comp, uint32_t since) const;
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
	// 组件名 -> components_ 下标(注册时填一次, 之后只读 —— 并行系统里查也安全)
	std::unordered_map<uint64_t, int32_t> component_index_;
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
