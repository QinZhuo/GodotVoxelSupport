## 数组视图的公共实现（三类视图共用，算法只此一份）：
##   - ArrayView：流式布局，视图 = 子节点，数量可变
##   - SlotArrayView2D / SlotArrayView3D：槽位 = 场景里预置的子节点，数量固定
## 视图的创建 / 释放 / 重绑 / 定位统一在这里；`slot_*` 系列由槽位类委托调用（传 [code]self[/code]）。
class_name ArrayViewTool

## 获取数据项的视图名（= 视图的节点名）。
## 名字**只用于 Scene Tree 可读**，不承担定位职责（数组视图按「视图当前的 data」比对定位）
## ⇒ 数据项**不必**实现 `get_view_name()`；没实现时退化为「类名_索引」（Card_0 / Dictionary_3）。
## [param item] 数据项
## [param index] 数据项在 data 中的索引（无 get_view_name() 时用来保证节点名唯一）；<0 = 未知
static func get_item_name(item, index: int = -1) -> String:
	var suffix := "" if index < 0 else "_%d" % index
	if item == null:
		return "empty" + suffix
	if item is Object:
		if "get_view_name" in item:
			var view_name := str(item.get_view_name())
			if not view_name.is_empty():
				return view_name
		return _class_name_of(item) + suffix
	## 值类型（Dictionary / bool / int...）：可读且合法的标识符直接当名字，否则退回类型名
	var text := str(item)
	return (text if text.is_valid_identifier() else type_string(typeof(item))) + suffix

## 安全的等值判断：保留 `==` 的**值语义**（内容相同的 Dictionary 仍能配上），但类型不同时返回 false
## ⚠️ 不能直接写 `a == b`：GDScript 的 `==` 在类型不同时会**直接抛错**（如 bool vs String），
## 而"视图是否显示某项"这种比对本该是"不匹配"而不是崩。只要"同一个实例"请用引擎的 `is_same()`。
static func same_data(a, b) -> bool:
	if typeof(a) != typeof(b):
		return false
	return a == b

## 该视图是否正在显示 item —— 数组视图「按数据找视图」的**唯一入口**
## （ArrayView / SlotArrayView2D / SlotArrayView3D 都走这里，对应规则只有一份，不会各自分叉）
static func shows(view: Node, item) -> bool:
	if view == null or not is_instance_valid(view):
		return false
	if not ("data" in view):
		return false
	return same_data(view.data, item)

## 安全写入视图的 data：类型不兼容时**跳过并告警**，而不是让引擎抛错中断流程。
## 视图的 data 声明成具体类型（如 `var data: bool`）时，塞进别的类型会直接报
## "Invalid assignment..." ⇒ 写入前先按属性声明的类型判一次（与 shows() 是一对读写入口）。
## [returns] 是否写入成功
static func set_data(view: Node, item) -> bool:
	if view == null or not is_instance_valid(view) or not ("data" in view):
		return false
	if not _data_accepts(view, item):
		LogTool.warn("数组视图", "%s 的 data 装不下 %s 类型的数据项，已跳过赋值" % [
			view.name, type_string(typeof(item))])
		return false
	view.data = item
	return true

## 视图的 data 能否装下 item：声明成 Variant（未声明类型 / TYPE_OBJECT）时一律可以
static func _data_accepts(view: Node, item) -> bool:
	for p in view.get_property_list():
		if str(p.name) != "data":
			continue
		var t: int = p.type
		if t == TYPE_NIL or t == TYPE_OBJECT or t >= TYPE_MAX:
			return true
		return typeof(item) == t
	return true

## ---- 视图列表的通用操作 ----
## ArrayView / SlotArrayView2D / SlotArrayView3D 共用，避免各自实现出细微差别

## 取第 index 个视图（越界 / 空位返回 null）
static func get_view(views: Array, index: int) -> Node:
	if index < 0 or index >= views.size() or not is_instance_valid(views[index]):
		return null
	return views[index]

## 释放第 index 个视图并在列表里置空（**不改 data**）。走 tween_free 的视图会先淡出再消失
static func free_at(views: Array, index: int, pool) -> void:
	if index < 0 or index >= views.size():
		return
	if is_instance_valid(views[index]):
		free_view(views[index], pool)
	views[index] = null

## 把视图列表的长度对齐到 count（多出来的直接释放）
static func resize_views(views: Array, count: int, pool) -> void:
	while views.size() < count:
		views.append(null)
	while views.size() > count:
		var view = views.pop_back()
		if is_instance_valid(view):
			free_view(view, pool)

## 数据项在 data 里的索引（data 空间；data 为空 / 未收录返回 -1）
static func index_in_data(data: Array, item) -> int:
	return data.find(item) if data else -1

## 定位数据项：先查 data，查不到再扫描视图。
## ⚠️ 返回值**可能来自两个不同的索引空间**（data 索引 或 views 索引）——只适合"删一项 / 取位置"
## 这类两个空间都合法的场景；⛔ 要拿索引去读 data（refresh_at 等）必须用 index_in_data()
static func index_of_item(data: Array, views: Array, item) -> int:
	var i := index_in_data(data, item)
	return i if i >= 0 else index_of_view(views, item)

## 数据项只在视图里（不在 data 中）时：就地重绑该视图并返回它；没有则 null。
## ⚠️ 别换成 refresh_at —— 它会重新读 data[index]，而这类项不在 data 里（下标可能越界）⇒ 返回 null
static func rebind_view(views: Array, index: int, item) -> Node:
	var view := get_view(views, index)
	if view:
		rebind(view, item, index)
	return view

## ---- 按数据项操作（ArrayView / SlotArrayView2D / SlotArrayView3D 共用同一份骨架）----
## 骨架只此一处：三个宿主类各自只实现"执行"，避免分支结构各写一遍、改一处漏一处。
## ⚠️ 宿主协议（全部是已有的公开接口，不额外要求新方法）：
## `data` / `views`（两个索引空间的数组）、`refresh_at(index)`（①分支的执行，各族自己定强度：
## Slot 会整体重排、ArrayView 只刷那一格）、`add_item(item)`（③分支）、`remove_at(index)`（删除）

## 刷新某个数据项的视图：① data 里有 ⇒ 按索引；② 只有视图里有 ⇒ 就地重绑；③ 都没有 ⇒ 当作新增
static func refresh_item(host, item) -> Node:
	var data_index := index_in_data(host.data, item)
	if data_index >= 0:
		## ① 的交给出宿主刷那一格；返回 null（下标越界 / 空数据位）就继续往 ②③ 走
		var in_data: Node = host.refresh_at(data_index)
		if in_data:
			return in_data
	var view_index := index_of_view(host.views, item)
	if view_index >= 0:
		return rebind_view(host.views, view_index, item)
	return host.add_item(item)

## 删除某个数据项的视图。
## ⚠️ item 为 null 时什么都不做：null 是"空槽位"的合法值，靠扫视图找 null 会误删空位视图
static func remove_item(host, item) -> void:
	if item == null:
		return
	var index := index_of_item(host.data, host.views, item)
	if index >= 0:
		host.remove_at(index)

## 哪个视图正在显示 item（不在 data 里的项靠它定位，如 add_item 加进来的）
static func index_of_view(views: Array, item) -> int:
	for i in views.size():
		if shows(views[i], item):
			return i
	return -1

## 把已有视图重新绑到 item（只改 data / 名字，不重建节点）；视图无效或装不下时返回 false
static func rebind(view: Node, item, index: int) -> bool:
	if view == null or not is_instance_valid(view):
		return false
	if not set_data(view, item):
		return false
	view.name = get_item_name(item, index)
	return true

## 空槽显隐（auto_hide_empty）：只让"有视图"的槽位显示
static func update_slot_visibility(slots: Array, views: Array, enabled: bool) -> void:
	if not enabled:
		return
	for i in slots.size():
		slots[i].visible = i < views.size() and is_instance_valid(views[i])

## 数据项的类名：优先取脚本的 class_name（Card / Equip），没有脚本时退回引擎原生类名
static func _class_name_of(item: Object) -> String:
	var script := item.get_script()
	if script:
		var cls: StringName = script.get_global_name()
		if not cls.is_empty():
			return cls
	return item.get_class()

## 创建并配置一个数据项的视图实例。
## 池空时自动回退为 view_scene 现场实例化(不再返回 null), pool_push 对外来节点会 queue_free 释放。
## [param view_scene] 用于实例化的 PackedScene(pool 为空/池不足时的兜底, 必填)
## [param pool] 可选的 BakedPool 对象池
## [param item] 数据项
## [param index] 数据项索引（仅用于生成可读的视图名）
## [returns] 配置好的视图节点，失败返回 null
static func create_view(view_scene: PackedScene, pool, item, index: int = -1) -> Node:
	var view: Node
	if pool:
		view = pool.pool_get()
	if view == null:
		if not view_scene:
			LogTool.error("数组视图", "view_scene 未赋值!")
			return null
		view = view_scene.instantiate()
	if item is Node and not item.get_parent():
		view.add_child(item)
	set_data(view, item)
	view.name = get_item_name(item, index)
	return view

## 释放一个视图节点。
## 优先使用对象池回收，否则尝试 tween_free，最后 queue_free。
## [param view] 要释放的视图节点
## [param pool] 可选的 BakedPool 对象池
static func free_view(view: Node, pool):
	if not is_instance_valid(view):
		return
	if pool:
		pool.pool_push(view)
	else:
		if "tween_free" in view:
			view.tween_free()
		else:
			## queue_free 是**延迟**释放：不先摘除，节点会在槽位里多留一帧。
			## 若同一帧又往该槽位放新视图，新节点会因重名被引擎改名为 @Xxx@N，
			## 且两个视图重叠一帧（闪现）。因此先摘除再释放。
			if view.get_parent() != null:
				view.get_parent().remove_child(view)
			view.queue_free()

## ---- 槽位操作（SlotArrayView2D / SlotArrayView3D 共用同一份实现）----
## 两个槽位类只有"节点类型"不同（Godot 无法共享基类），算法全部收在这里，改一处即可。
## ⚠️ 宿主协议：`data` / `views` / `view_scene` / `pool` / `auto_hide_empty`、
## `_get_slots()` / `_resize_views()` / `_update_slot_visibility()`

## 按 data 重建全部槽位视图
static func slot_refresh(host) -> void:
	host._resize_views()
	slot_clear(host)
	var slots: Array = host._get_slots()
	if not host.data or host.data.is_empty() or slots.is_empty():
		return
	var last_index := slots.size() - 1
	for i in host.data.size():
		if host.data[i] == null:
			continue
		if i > last_index:
			## 槽位不够：多余项直接丢弃并报错（不是叠在最后一格上，那样看不出配置错了）
			LogTool.error("数组视图", "%s 的 data(%d 项) 多于槽位(%d 个)，多余的项已丢弃" % [
				host.name, host.data.size(), slots.size()])
			break
		set_slot_view(host, i, host.data[i])
	host._update_slot_visibility()

## 清空所有槽位视图（不改 data）
static func slot_clear(host) -> void:
	for i in host.views.size():
		free_at(host.views, i, host.pool)
	host._update_slot_visibility()

## 按 data 重新对齐：保证 views[i] 显示 data[i]。
## 复用已有视图实例（只改 data / 名字，不重建节点 ⇒ 不闪烁）；视图跟不上数据时才换新实例。
## 删除 / 排序 / 中间插入后**必须**走这里 —— 槽位索引与 data 索引错位会让显示顺序乱掉。
static func slot_resync(host) -> void:
	host._resize_views()
	for i in host.views.size():
		var item = host.data[i] if (host.data and i < host.data.size()) else null
		var view = host.views[i]
		if item == null:
			if is_instance_valid(view):
				free_at(host.views, i, host.pool)
		elif is_instance_valid(view) and "data" in view:
			if not shows(view, item):
				set_data(view, item)
			view.name = get_item_name(item, i)
		else:
			if is_instance_valid(view):
				free_at(host.views, i, host.pool)
			set_slot_view(host, i, item)
	host._update_slot_visibility()

## 刷第 index 项：对齐后返回该槽位的视图（越界 / 空数据位返回 null）
static func slot_refresh_at(host, index: int) -> Node:
	slot_resync(host)
	return get_view(host.views, index)

## 追加一项到第一个空槽（满槽则落到最后一格，表现型视图靠它回收最后一格）
static func slot_add_item(host, item) -> Node:
	host._resize_views()
	var view := set_slot_view(host, find_slot_index(host.views), item)
	host._update_slot_visibility()
	return view

## 把 item 硬放到指定槽位（**不读 data**，用于"这一格改显示别的东西"）；越界返回 null
static func slot_set_item(host, slot_index: int, item) -> Node:
	host._resize_views()
	var view := set_slot_view(host, slot_index, item)
	host._update_slot_visibility()
	return view

## 移除第 index 个视图（**不改 data**）并补洞重排
static func slot_remove_at(host, index: int) -> void:
	host._resize_views()
	if index < 0 or index >= host.views.size():
		return
	free_at(host.views, index, host.pool)
	slot_resync(host)

## 在指定槽位放一个视图：先释放旧视图（不然同槽两个视图重叠 + 旧节点永久泄漏）再创建、挂载
static func set_slot_view(host, slot_index: int, item) -> Node:
	var slots: Array = host._get_slots()
	if slot_index < 0 or slot_index >= slots.size():
		return null
	free_at(host.views, slot_index, host.pool)
	var view := create_view(host.view_scene, host.pool, item, slot_index)
	if view:
		slots[slot_index].add_child(view)
		host.views[slot_index] = view
	return view

## 第一个空槽的索引；全满则返回最后一个（溢出兜底）；没有槽位返回 -1
static func find_slot_index(views: Array) -> int:
	if views.is_empty():
		return -1
	for i in views.size():
		if not is_instance_valid(views[i]):
			return i
	return views.size() - 1

## 编辑器预览：每个槽位铺一个空视图（owner 为空 ⇒ 不会存进场景）
static func slot_preview_setup(host) -> void:
	if not Engine.is_editor_hint():
		return
	host._resize_views()
	slot_clear(host)
	var slots: Array = host._get_slots()
	if not host.view_scene or slots.is_empty():
		return
	for i in slots.size():
		set_slot_view(host, i, null)
	host._update_slot_visibility()
