class_name ECSSyncSystem
extends ECSSystem

## ECSSyncSystem —— 批量把 ECS 字段同步到 Godot 节点属性。
##   - NodeLink 只保存 实体↔节点 关联(node_path)
##   - **同步哪些字段由 add_field_rule 注册的规则决定**(位置也是规则, 如 pos → position)
##   - 每帧: 遍历带 NodeLink 的实体, 按 comp 分组, 每 comp 一次 query_aligned + 一次实体遍历,

## 场景根节点(查找 NodeLink.node_path 用)。若未设置, 默认取当前场景根。
var scene_root: Node = null

## 渲染开关: false 时跳过全部同步(纯数值逻辑), 由持有方(如 World 节点 / 渲染对比)控制。
var render_enabled := true

## 服务器直连开关(默认 false): true 时 position/transform/modulate/self_modulate/visible/z_index
## 注意: 直连**只改渲染**, 对应节点属性不更新, 依赖节点 transform 的碰撞与拾取会失准。
var server_direct := false

## 节点缓存: NodeLink 行号 -> Node(数组索引 O(1))。NodeLink 实体数变化时重建。
var _nl_nodes: Array = []
## 上次重建时用的行集: 只比 size 会漏掉"销毁 N 个又创建 N 个"(数量不变但实体全换), 节点会指向旧对象。
var _nl_rows := PackedInt32Array()
## node_path 列缓存(结构变化时更新, 免每帧 get_column 复制 10000 路径)
var _nl_paths: PackedStringArray = []

## 同步规则(预编译为数组, 避免每实体 dict 遍历)。
var _rule_items: Array = []

## 对齐行号缓存: comp -> {result, struct_v, comp_v}。NodeLink 行集不变也可能有组件增删,
## 所以按"全局结构版本 + 该组件版本"双判, 只比行集会把旧行号对到新节点上。
var _aligned_cache := {}


## 注册一条字段同步规则: 把 ECS 组件 comp 的 field 字段同步到关联节点的 node_prop 属性。
func add_field_rule(comp, field: StringName, node_prop: StringName) -> void:
	for item in _rule_items:
		if item.comp == comp:
			item.fields.append(field)
			item.props.append(node_prop)
			return
	var new_item := {
		"comp": comp,
		"fields": PackedStringArray([field]),
		"props": PackedStringArray([node_prop]),
	}
	_rule_items.append(new_item)


func required_components() -> Array[Script]:
	return [NodeLink]

## 访问场景树/节点 → 必须主线程串行, 不可并行。
func can_run_parallel() -> bool:
	return false


func _run(ctx: ECSSystemContext, _delta: float) -> void:
	if not render_enabled:
		return
	var w := ctx.world
	if w == null or _rule_items.is_empty():
		return
	if server_direct != w.native().get_sync_direct():
		w.native().set_sync_direct(server_direct)
	if scene_root == null:
		var tree := Engine.get_main_loop() as SceneTree
		scene_root = tree.current_scene if tree else null
	if scene_root == null:
		return

	var rows: PackedInt32Array = w.query_rows(NodeLink, [], [])
	if rows.is_empty():
		return

	# 节点缓存(行号 -> node) + node_path 列缓存, 行集变化时重建并清空对齐缓存
	if _nl_rows != rows:
		_nl_rows = rows
		_aligned_cache.clear()
		_nl_paths = w.get_column(NodeLink, &"node_path")
		var max_row := -1
		for e in rows:
			max_row = maxi(max_row, int(e))
		_nl_nodes.resize(max_row + 1)
		for e in rows:
			_nl_nodes[e] = scene_root.get_node_or_null(_nl_paths[e])

	for item in _rule_items:
		var comp = item.comp
		var fields: PackedStringArray = item.fields
		var props: PackedStringArray = item.props
		# 对齐行号(缓存): aligned[0]=NodeLink 行号, aligned[1]=comp 行号(同一 k 索引)
		var sv := w.struct_version()
		var cv := w.comp_version(comp)
		var entry: Variant = _aligned_cache.get(comp)
		if entry == null or entry.struct_v != sv or entry.comp_v != cv:
			entry = {"result": w.query_aligned(NodeLink, [comp]), "struct_v": sv, "comp_v": cv}
			_aligned_cache[comp] = entry
		var aligned: Variant = entry.result
		if aligned.size() < 2:
			continue
		var nl_rows_a: PackedInt32Array = aligned[0]
		var comp_rows_a: PackedInt32Array = aligned[1]
		# 兜底: 行号必须落在 _nl_nodes 内(缓存意外过期时宁可本帧跳过, 也不越界写节点)
		if not nl_rows_a.is_empty() and int(nl_rows_a[nl_rows_a.size() - 1]) >= _nl_nodes.size():
			_aligned_cache.clear()
			continue
		# C++ 批量同步(内层循环下沉到原生库): 读列 + 写节点属性
		w.native().call(&"sync_fields", nl_rows_a, comp_rows_a, _nl_nodes,
				w.component_name(item.comp), fields, props)
