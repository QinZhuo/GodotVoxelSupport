@tool
## DefTable 顶部 Main Screen: 按 Def 类型目录加载 Def 资源(.tres),
## 以只读表格展示, 支持选择/复制/粘贴(批量赋值)/Inspector 联动/排序。
## 参照 resources_spreadsheet_view 的表格交互, 但去掉单元格内编辑, 只做展示+复制粘贴。
class_name DefTableView
extends Control

const DefTableGridClass := preload("res://addons/DEVFramework/DefTable/DefTableGrid.gd")
const DefTableCellClass := preload("res://addons/DEVFramework/DefTable/DefTableCell.gd")
const ROW_HEIGHT := 24.0
const DEFS_BASE := "res://Assets/Def/"
const MAX_COL_WIDTH := 600.0
## 单元格内容左右内边距(与 DefTableCell 的 CELL_MARGIN_L/R 一致):
## 列宽测量/行高测量都减此值得到"渲染可用宽", 保证测量与渲染同一口径
const CELL_PADDING := 8.0
## 行高垂直余量: 叠加在字体实测高度上, 给文字上下留呼吸感(单行与多行行高共用)
const ROW_V_PADDING := 8.0
## [img] 列宽补贴: 内联图标按此近似宽度计入列宽(实际渲染尺寸随资源而定)
const IMG_PREVIEW_MIN_WIDTH := 22.0
## 表头排序箭头预留宽: 排序后列名会追加 ▲/▼, 度量时统一预留避免裁字
const HEADER_ARROW_RESERVE := 18.0

var editor_interface: Object
var editor_plugin: EditorPlugin

@onready var dir_tree: Tree = %DirTree
@onready var refresh_btn: Button = %RefreshBtn
@onready var count_label: Label = %CountLabel
@onready var header_scroll: ScrollContainer = %HeaderScroll
@onready var header_row: HBoxContainer = %HeaderRow
@onready var grid_scroll: ScrollContainer = %GridScroll
@onready var grid: Container = %Grid
@onready var frozen_header_row: HBoxContainer = %FrozenHeaderRow
@onready var frozen_grid_scroll: ScrollContainer = %FrozenGridScroll
@onready var frozen_grid: Container = %FrozenGrid
@onready var frozen_spacer: Control = %FrozenSpacer
@onready var sel_label: Label = %SelLabel
@onready var hint_label: Label = %HintLabel

## 当前加载数据
var rows: Array = []                 # Array[Resource]
var columns: Array[StringName] = []
var column_types: Array[int] = []
var column_hints: Array[int] = []
var column_hint_strings: Array[PackedStringArray] = []
var column_writable: Array[bool] = []
var column_widths: Array[float] = []

## 选中单元格 (单列限制, 同 resources_spreadsheet_view)
var edited_cells: Array[Vector2i] = []

## 可见行范围(虚拟化)
var first_row := 0
var last_row := 0

## 排序
var sorting_by := &"name"
var sorting_reverse := false

var _dirs: Array[String] = []
var _current_dir := ""
var _loaded := false
var _syncing_scroll := false

## 测量缓存(性能): 复用单个 RichTextLabel 测 BBCode 高度, 缓存文本宽度
var _measure_rtl: RichTextLabel
var _width_cache: Dictionary = {}

## 单元格文本缓存(性能): Resource -> 按列的展示文本。
## 计算型 getter 属性(tr_desc 等)访问即全量重建, 必须缓存避免布局/渲染重复计算
var _text_cache: Dictionary = {}

## 行染色缓存(B1 row stylization): 每行取首个有效 Color 值作为整行染色
var _row_tints: Array[Color] = []


func _ready() -> void:
	if editor_interface == null:
		return
	# 表头横向滚动由主网格驱动: 隐藏滚动条(SHOW_NEVER), 避免用户单独拖动表头错位;
	# 不用 DISABLED, 否则 ScrollContainer 的 minimum 会包含子节点总宽, 撑爆整个布局。
	header_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	hint_label.text = "点击选中 · Ctrl+点击多选 · Shift+点击连选 · Ctrl+C 复制 · Ctrl+V 粘贴"
	_refresh_dir_list()
	if _dirs.size() > 0:
		# 默认选中第一个(最深层目录优先展示, 否则选中根级首个)
		var first_item := _select_first_dir_item()
		if first_item != null:
			_on_dir_selected()
	_loaded = true
	grid_scroll.get_v_scroll_bar().value_changed.connect(_on_v_scroll)
	grid_scroll.get_h_scroll_bar().value_changed.connect(_on_h_scroll)
	# 双向锁定: 表头横向滚动由主网格驱动, 反向变化也同步回去, 防止表头独立滚动错位
	header_scroll.get_h_scroll_bar().value_changed.connect(_on_header_h_scroll)
	grid_scroll.resized.connect(_update_visible_rows)
	frozen_grid_scroll.get_v_scroll_bar().value_changed.connect(_on_frozen_v_scroll)
	# 主网格横向滚动条出现/消失时, 同步冻结列底部高度, 避免 name 列与其它列产生高度差
	grid_scroll.get_h_scroll_bar().visibility_changed.connect(_sync_frozen_spacer)
	grid_scroll.resized.connect(_sync_frozen_spacer)
	_sync_frozen_spacer()
	if editor_interface != null and editor_interface.get_resource_filesystem() != null:
		editor_interface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed)
	refresh_btn.pressed.connect(_on_refresh_pressed)
	dir_tree.item_selected.connect(_on_dir_selected)
	_setup_hover_highlight()
	# 用 _shortcut_input 处理快捷键(Ctrl+C/V 在编辑器里可能先被编辑器自身的快捷键消费,
	# _shortcut_input 比 _unhandled_input 更早触发, 能可靠捕获)
	set_process_shortcut_input(true)
	set_process_unhandled_input(true)


## 递归收集 base 下的所有子目录(含子孙), 返回完整 res:// 路径(带尾部 /)
func _list_dirs(base: String) -> Array[String]:
	var out: Array[String] = []
	var stack: Array[String] = [base]
	while stack.size() > 0:
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if d.current_is_dir() and not f.begins_with("."):
				var sub := dir.path_join(f)
				out.append(sub + "/")
				stack.append(sub + "/")
			f = d.get_next()
		d.list_dir_end()
	out.sort()
	return out


## 刷新左侧目录树: 按 DEFS_BASE 下的目录层级构建 Tree(父目录可折叠, 选中加载整个子树)
func _refresh_dir_list() -> void:
	_dirs = _list_dirs(DEFS_BASE)
	dir_tree.clear()
	var root := dir_tree.create_item()
	root.set_text(0, DEFS_BASE.trim_suffix("/").get_file())
	root.set_icon(0, _folder_icon())
	# 每个目录路径拆段, 按父子关系挂到 Tree; 节点 metadata 存完整目录路径
	# _dirs 已按字典序排序, 保证父目录先于子目录处理
	var parents := {}  # 目录路径 -> TreeItem
	parents[DEFS_BASE] = root
	for d in _dirs:
		var rel := d.trim_prefix(DEFS_BASE).trim_suffix("/")
		var segments := rel.split("/")
		var item := root
		var path := DEFS_BASE
		for seg in segments:
			path = path.path_join(seg) + "/"
			if parents.has(path):
				item = parents[path]
				continue
			var child := item.create_child()
			child.set_text(0, seg)
			child.set_icon(0, _folder_icon())
			child.set_metadata(0, path)
			parents[path] = child
			item = child
	root.collapsed = false


## 获取编辑器文件夹图标(与 FileSystem 停靠面板一致的 Folder 图标)
func _folder_icon() -> Texture2D:
	if editor_interface == null:
		return null
	return editor_interface.get_base_control().get_theme_icon("Folder", "EditorIcons")


func _select_first_dir_item() -> TreeItem:
	# 深度优先取第一个带完整路径的目录节点(最深层级优先), 便于默认展示具体分类
	var found: TreeItem = null
	var stack: Array = []
	if dir_tree.get_root() != null:
		stack.append(dir_tree.get_root())
	while stack.size() > 0:
		var item := stack.pop_back() as TreeItem
		var path: Variant = item.get_metadata(0)
		if path is String and (path as String).ends_with("/"):
			item.select(0)
			item.set_collapsed(false)
			found = item
			break
		for ch in item.get_children():
			stack.append(ch)
	return found


func _on_dir_selected() -> void:
	var item := dir_tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not (meta is String):
		return
	_current_dir = meta as String
	if not _current_dir.ends_with("/"):
		_current_dir += "/"
	_load_dir(_current_dir)


func _on_refresh_pressed() -> void:
	_load_dir(_current_dir)


func _on_filesystem_changed() -> void:
	if not _loaded:
		return
	# 文件系统变化时刷新目录树(新增/删除目录), 并保持当前选中项
	var prev_path := _current_dir
	_refresh_dir_list()
	var found: TreeItem = null
	var stack: Array = []
	if dir_tree.get_root() != null:
		stack.append(dir_tree.get_root())
	while stack.size() > 0 and found == null:
		var item := stack.pop_back() as TreeItem
		var meta: Variant = item.get_metadata(0)
		if str(meta) == prev_path:
			found = item
			break
		for ch in item.get_children():
			stack.append(ch)
	if found != null:
		found.select(0)
		_load_dir(prev_path)
	else:
		_load_dir(_current_dir)


func _load_dir(path: String) -> void:
	if path == "":
		return
	var all_tres := _collect_tres_recursive(path)
	var loaded: Array[Resource] = []
	for p in all_tres:
		if ResourceLoader.exists(p):
			var res: Resource = load(p)
			if res != null and _is_def(res):
				loaded.append(res)
	rows = loaded
	_build_columns()
	_sort_rows()
	_compute_row_tints()
	# 目录/列结构变化时清空旧单元格, 避免复用旧列类型的 cell 导致类型错位
	_clear_grid_cells()
	_clear_measure_cache()
	_compute_layout()
	_rebuild_header()
	_update_visible_rows(true)
	count_label.text = "共 %d 个 Def" % rows.size()
	sel_label.text = "未选中"
	edited_cells.clear()


## 清空网格中所有单元格节点(目录切换/列结构变化时调用)。
## 行身份模型: 全部回收入池而非销毁(池按 Kind 分桶, 跨目录复用类型安全)
func _clear_grid_cells() -> void:
	_recycle_all_rows()
	first_row = 0
	last_row = 0


func _collect_tres_recursive(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var stack: Array[String] = [path]
	while stack.size() > 0:
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if d.current_is_dir() and not f.begins_with("."):
				stack.append(dir.path_join(f) + "/")
			elif f.ends_with(".tres") or f.ends_with(".res"):
				out.append(dir.path_join(f))
			f = d.get_next()
		d.list_dir_end()
	return out


func _is_def(res: Resource) -> bool:
	var script: Script = res.get_script()
	if script == null:
		return false
	if res is Def:
		return true
	return script.resource_path.begins_with("res://") and script.get_global_name().ends_with("Def")


func _build_columns() -> void:
	columns.clear()
	column_types.clear()
	column_hints.clear()
	column_hint_strings.clear()
	column_writable.clear()

	var seen := {&"name": true}

	# 固定列: name(Def 名) —— 不显示 resource_path, 名字即可
	columns.append(&"name")
	column_types.append(TYPE_STRING)
	column_hints.append(PROPERTY_HINT_NONE)
	column_hint_strings.append(PackedStringArray())
	column_writable.append(false)

	# 固定列: tr_name(翻译名) —— 紧跟 name 之后
	seen[&"tr_name"] = true
	columns.append(&"tr_name")
	column_types.append(TYPE_STRING)
	column_hints.append(PROPERTY_HINT_NONE)
	column_hint_strings.append(PackedStringArray())
	column_writable.append(false)

	# 其余导出属性取并集(保持 get_property_list 默认顺序), 来自多个脚本时兼容
	for res in rows:
		for p in res.get_property_list():
			if not can_display_property(p):
				continue
			var pname: StringName = p["name"]
			if seen.has(pname):
				continue
			seen[pname] = true
			columns.append(pname)
			column_types.append(p["type"])
			column_hints.append(p["hint"])
			column_hint_strings.append(str(p["hint_string"]).split(","))
			column_writable.append(bool(p["usage"] & PROPERTY_USAGE_READ_ONLY) == false)


func can_display_property(p: Dictionary) -> bool:
	var pname: String = p["name"]
	var ptype: int = p["type"]
	if ptype == TYPE_CALLABLE or ptype == TYPE_SIGNAL:
		return false
	if int(p["usage"]) & PROPERTY_USAGE_EDITOR == 0:
		return false
	if pname == "script" or pname == "resource_local_to_scene" or pname == "resource_scene_unique_id":
		return false
	if pname == "resource_path" or pname == "resource_name" or pname.begins_with("metadata"):
		return false
	return true


func _is_derived_col(col: int) -> bool:
	return col < 1


func _get_value(res: Resource, col: int) -> Variant:
	if col == 0:
		return res.get("name") if "name" in res else res.resource_path.get_file().get_basename()
	var pname: StringName = columns[col]
	return res.get(pname)


func _to_text(value, col: int) -> String:
	if value == null:
		return ""
	match column_types[col]:
		TYPE_STRING:
			return str(value)
		TYPE_INT, TYPE_FLOAT:
			return str(value)
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_COLOR:
			return (value as Color).to_html(false)
		TYPE_OBJECT:
			if value is Resource:
				return _resource_display_text(value)
			return str(value)
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for item in value:
				parts.append(_array_item_name(item))
			return "、".join(parts)
		TYPE_DICTIONARY:
			var dstr := var_to_str(value)
			return dstr if dstr.length() <= 40 else "%s…" % dstr.substr(0, 40)
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return _packed_array_to_text(value)
		TYPE_NIL:
			return ""
		_:
			if column_hints[col] == PROPERTY_HINT_ENUM:
				var opts := column_hint_strings[col]
				if value is int and value >= 0 and value < opts.size():
					return opts[value]
			return str(value)


## 打包数组转展示文本(PackedStringArray 等)
func _packed_array_to_text(value) -> String:
	var items: Array = []
	for item in value:
		items.append(_array_item_name(item))
	return "、".join(items)


func _array_item_name(item) -> String:
	if item is Resource:
		return _resource_display_text(item)
	return str(item)


## 资源引用显示 tostring 内容; 若未重写 _to_string 则回退到文件名
func _resource_display_text(value: Resource) -> String:
	var s := str(value)
	# 重写了 _to_string 的资源返回自定义文本(不含 res:// 路径标记)
	if not s.begins_with("res://") and not s.contains("(res://") and not s.contains(":<"):
		return s
	if value.resource_path != "":
		return value.resource_path.get_file().get_basename()
	return s


## 解析粘贴文本为列值。返回 {ok: bool, value: Variant, error: String}
## 校验类型并给出具体错误(如"期望 int, 得到 'abc'"), 失败时 ok=false 且 value 无效
func _from_text(text: String, col: int) -> Dictionary:
	var type_name := _type_display_name(column_types[col])
	if text == "":
		return {"ok": true, "value": null, "error": ""}
	match column_types[col]:
		TYPE_STRING:
			var v = str_to_var(text)
			return _ok(v if v != null else text)
		TYPE_INT:
			if column_hints[col] == PROPERTY_HINT_ENUM:
				var opts := column_hint_strings[col]
				var idx := opts.find(text)
				if idx >= 0:
					return _ok(idx)
				if text.is_valid_int():
					return _ok(text.to_int())
				return _err("期望枚举 %s, 得到 '%s'" % [type_name, text])
			if text.is_valid_int():
				return _ok(text.to_int())
			var iv = str_to_var(text)
			if iv is int:
				return _ok(iv)
			return _err("期望 int, 得到 '%s'" % text)
		TYPE_FLOAT:
			if text.is_valid_float():
				return _ok(text.to_float())
			var fv = str_to_var(text)
			if fv is float:
				return _ok(fv)
			return _err("期望 float, 得到 '%s'" % text)
		TYPE_BOOL:
			var bv = str_to_var(text)
			if bv is bool:
				return _ok(bv)
			if text == "true" or text == "1" or text.to_lower() == "yes":
				return _ok(true)
			if text == "false" or text == "0" or text.to_lower() == "no":
				return _ok(false)
			return _err("期望 bool(true/false/1/0), 得到 '%s'" % text)
		TYPE_COLOR:
			var cv = str_to_var(text)
			if cv is Color:
				return _ok(cv)
			var c = Color.from_string(text, Color(-1, -1, -1, -1))
			if c.a >= 0.0:
				return _ok(c)
			return _err("期望颜色(如 #ff0000), 得到 '%s'" % text)
		TYPE_OBJECT:
			if text.begins_with("res://") and ResourceLoader.exists(text):
				return _ok(load(text))
			return _err("期望资源路径(res://), 得到 '%s'" % text)
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			# 数组: 优先按 _cell_copy_text 的 JSON 格式还原(含资源路径), 兼容 var_to_str 的手写格式
			var parsed = JSON.parse_string(text)
			if parsed is Array:
				return _ok(_jsonable_to_value(parsed))
			return _err("期望数组(JSON), 得到 '%s'" % text)
		TYPE_DICTIONARY:
			var parsed_dict = JSON.parse_string(text)
			if parsed_dict is Dictionary:
				return _ok(_jsonable_to_value(parsed_dict))
			var sv = str_to_var(text)
			if sv is Dictionary:
				return _ok(sv)
			return _err("期望字典(JSON), 得到 '%s'" % text)
		_:
			return _ok(str_to_var(text))


func _ok(value) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


func _err(msg: String) -> Dictionary:
	return {"ok": false, "value": null, "error": msg}


func _type_display_name(t: int) -> String:
	match t:
		TYPE_STRING: return "string"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_BOOL: return "bool"
		TYPE_COLOR: return "color"
		TYPE_OBJECT: return "resource"
		TYPE_ARRAY: return "array"
		TYPE_DICTIONARY: return "dictionary"
		_:
			return "value"


## 将序列化的 JSON 值还原为实际值(资源路径 -> load, 数组/字典递归)
func _jsonable_to_value(v) -> Variant:
	if v is Dictionary and v.has("__res"):
		var p = v["__res"]
		if p is String and ResourceLoader.exists(p):
			return load(p)
		return null
	if v is Array:
		var arr := []
		for e in v:
			arr.append(_jsonable_to_value(e))
		return arr
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _jsonable_to_value(v[k])
		return d
	return v


## 将实际值转为可 JSON 序列化的形式(资源 -> {__res: 路径}, 数组/字典递归)
func _value_to_jsonable(v) -> Variant:
	if v is Resource:
		return {"__res": v.resource_path}
	if v is Array:
		var arr := []
		for e in v:
			arr.append(_value_to_jsonable(e))
		return arr
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _value_to_jsonable(v[k])
		return d
	if v is PackedByteArray or v is PackedInt32Array or v is PackedInt64Array or v is PackedFloat32Array or v is PackedFloat64Array or v is PackedStringArray:
		var arr2 := []
		for e in v:
			arr2.append(_value_to_jsonable(e))
		return arr2
	return v


func _sort_rows() -> void:
	var sort_col := columns.find(sorting_by)
	if sort_col < 0:
		sort_col = 0
	var sort_val: Callable = func(a: Resource, b: Resource) -> bool:
		var va = _get_value(a, sort_col)
		var vb = _get_value(b, sort_col)
		return _compare_values(va, vb)
	rows.sort_custom(sort_val)
	if sorting_reverse:
		rows.reverse()


func _compare_values(a, b) -> bool:
	if a == null and b == null:
		return false
	if a == null:
		return true
	if b == null:
		return false
	if (a is int or a is float) and (b is int or b is float):
		return a < b
	if a is Color and b is Color:
		return a.h < b.h if a.h != b.h else a.v < b.v
	if a is Resource and b is Resource:
		return a.resource_path < b.resource_path
	return str(a).filenocasecmp_to(str(b)) < 0


## 计算列宽 + 行高 (单次遍历, 缓存文本测量结果)
## 参考 jospic/dynamicdatatable: 列宽 = 全量遍历 font.get_string_size 取最大值;
## 参考 don-tnowe: 行高 = 内容驱动(超长文本换行后扩展)。
## 性能约定:
##   · 文本经 _cell_text 缓存, 布局与渲染共享一份(计算型 getter 只算一次)
##   · 仅含显式换行的内容做 RTL 实测撑行; 单行内容(BBCode 与否)固定行高,
##     由 RichTextLabel 在单元格内自动换行+裁剪 —— 避免 O(单元格数) 次 RTL 全排版卡帧
func _compute_layout() -> void:
	var font := get_theme_font("font", "Label")
	var fsize := get_theme_font_size("font", "Label")
	if font == null:
		font = ThemeDB.fallback_font
	column_widths.clear()
	for col in columns.size():
		column_widths.append(90.0)

	var line_height := _measure_line_height()
	# 第一遍: 表头宽度 —— 必须用 Button 实际渲染字体度量(Label 字体可能不同号),
	# 并预留排序箭头位, 否则列名会被 clip_text 裁掉尾巴
	var hfont := get_theme_font("font", "Button")
	if hfont == null:
		hfont = font
	var hfsize := get_theme_font_size("font_size", "Button")
	if hfsize <= 0:
		hfsize = fsize
	for col in columns.size():
		var hw := _measure_text_width("H:" + _column_header_text(col), hfont, hfsize) + HEADER_ARROW_RESERVE
		if hw + CELL_PADDING >= column_widths[col]:
			column_widths[col] = hw + CELL_PADDING

	var heights: Array[float] = []
	for r in rows.size():
		var row_h := line_height
		for col in columns.size():
			var text := _cell_text(rows[r], col)
			if text == "":
				continue
			var is_bb := _is_bbcode(text)
			var measure_text := _strip_bbcode(text) if is_bb else text
			# 列宽按"可见文本"计: BBCode 标签零宽不计入, 每个 [img] 补贴固定图标宽
			var tw := _measure_text_width(measure_text, font, fsize)
			if is_bb:
				tw += text.count("[img]") * IMG_PREVIEW_MIN_WIDTH
			# 列宽扩到能容纳单行文本: 留足 CELL_PADDING 余量,
			# 使"渲染可用宽(列宽-8)" >= 文本宽, 避免单行内容因边距差意外换行/裁切
			if tw + CELL_PADDING >= column_widths[col] and column_widths[col] < MAX_COL_WIDTH:
				column_widths[col] = minf(tw + CELL_PADDING, MAX_COL_WIDTH)
			# 自动行高: 仅显式多行内容(字典/数组/多段描述)按实际渲染高度撑行;
			# 单行内容(BBCode 含 [img])固定行高, 超出部分由单元格裁剪, 完整内容见 tooltip
			if measure_text.contains("\n"):
				var lh := _measure_bbcode_height(text, column_widths[col] - CELL_PADDING)
				if lh > row_h:
					row_h = lh
		heights.append(row_h)
	grid.set_row_heights(heights)
	frozen_grid.set_row_heights(heights)
	# 冻结首列宽度跟随 name 列
	frozen_grid.custom_minimum_size = Vector2(column_widths[0], 0)


## 用复用 RichTextLabel(进树 + reset_size 同步测量)计算 BBCode 文本高度
## 复用同一实例避免反复 new/free, 提升大数据量布局性能
## 用 get_content_height() 而非 fit_content 的 get_minimum_size():
##   · fit_content 模式在隐藏控件上测出的最小尺寸异常虚高(短文本也可能返回 90+px)
##   · 固定宽度 + get_content_height 与单元格实际渲染一致
## 测量用 RTL 必须与单元格渲染同口径: 清除默认 stylebox 的 32px 内容边距,
## 否则"测量可用宽 = 列宽-32"而"渲染可用宽 = 列宽", 导致单行文本被误判为需换行/行高虚高。
func _ensure_measure_rtl() -> RichTextLabel:
	if not is_instance_valid(_measure_rtl):
		_measure_rtl = RichTextLabel.new()
		_measure_rtl.bbcode_enabled = true
		_measure_rtl.fit_content = false
		_measure_rtl.scroll_active = false
		_measure_rtl.visible = false
		# 与 DefTableCell 的 label cell 一致: 空 stylebox, 无内容边距
		_measure_rtl.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		add_child(_measure_rtl)
	return _measure_rtl


func _measure_bbcode_height(text: String, width: float) -> float:
	if not is_inside_tree():
		return _measure_line_height()
	var rtl := _ensure_measure_rtl()
	rtl.custom_minimum_size = Vector2(maxf(width, 50.0), 0)
	rtl.size = Vector2(maxf(width, 50.0), 0)
	rtl.text = text
	rtl.reset_size()
	return rtl.get_content_height() + ROW_V_PADDING


## 测量当前主题下单行文本实际高度 + 垂直余量(替代硬编码 ROW_HEIGHT, 适配不同编辑器字号;
## 余量给文字上下留呼吸感, 避免字体撑满行高显得拥挤)
func _measure_line_height() -> float:
	if not is_inside_tree():
		return ROW_HEIGHT
	var rtl := _ensure_measure_rtl()
	rtl.custom_minimum_size = Vector2(200.0, 0)
	rtl.size = Vector2(200.0, 0)
	rtl.text = "Ag"
	rtl.reset_size()
	return rtl.get_content_height() + ROW_V_PADDING


## 粗略检测 BBCode(如 [img]/[color]/[font]), 此类文本不参与行高扩展
func _is_bbcode(text: String) -> bool:
	return text.contains("[img]") or text.contains("[color") or text.contains("[font") or text.contains("[icon")


static var _re_img: RegEx
static var _re_tag: RegEx

## 去除 BBCode 标签, 保留纯文本内容(含 [img]..[/img] 与带参标签整体移除)
func _strip_bbcode(text: String) -> String:
	var out := text
	# 正则一次性编译(热路径: 布局阶段每格调用, 逐次 new+compile 开销显著)
	if _re_img == null:
		_re_img = RegEx.new()
		_re_img.compile("\\[img[^\\]]*\\][^\\[]*\\[/img\\]")
		_re_tag = RegEx.new()
		_re_tag.compile("\\[[^\\]]+\\]")
	out = _re_img.sub(out, "", true)
	out = _re_tag.sub(out, "", true)
	return out


## 用纯 Font 测量单行文本宽度(纯文本宽, 不含内边距; 调用方自行加 CELL_PADDING)
## 按文本缓存结果, 大量重复文本(同列同值)时显著提速
func _measure_text_width(text: String, font: Font, fsize: int) -> float:
	if text == "" or font == null:
		return 0.0
	if _width_cache.has(text):
		return _width_cache[text]
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	_width_cache[text] = w
	return w


func _clear_measure_cache() -> void:
	_width_cache.clear()
	_text_cache.clear()
	_cell_fill_cache.clear()


func _column_header_text(col: int) -> String:
	var text := String(columns[col])
	if sorting_by == columns[col]:
		text += " ▲" if not sorting_reverse else " ▼"
	return text


func _rebuild_header() -> void:
	for child in header_row.get_children().duplicate():
		header_row.remove_child(child)
		child.queue_free()
	for child in frozen_header_row.get_children().duplicate():
		frozen_header_row.remove_child(child)
		child.queue_free()
	var header_h := _measure_line_height()
	header_scroll.custom_minimum_size = Vector2(0, header_h)
	# 冻结表头容器同样跟随实际表头高度
	var frozen_header_sc := frozen_header_row.get_parent() as ScrollContainer
	if frozen_header_sc != null:
		frozen_header_sc.custom_minimum_size = Vector2(0, header_h)
	# 冻结首列(列 0)不随横向滚动
	if columns.size() > 0:
		frozen_header_row.add_child(_make_header_button(0))
	frozen_header_row.custom_minimum_size = Vector2(column_widths[0] if columns.size() > 0 else 0, header_h)
	# 可滚动列(列 1..n-1)
	for col in range(1, columns.size()):
		header_row.add_child(_make_header_button(col))
	header_row.custom_minimum_size = Vector2(_scroll_total_width(), header_h)


func _make_header_button(col: int) -> Button:
	var btn := Button.new()
	btn.flat = true
	# 列名超列宽由 clip_text 原生裁剪(渲染层职责), tooltip 已有完整列名
	btn.text = _column_header_text(col)
	btn.clip_text = true
	btn.custom_minimum_size = Vector2(column_widths[col], _measure_line_height())
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.pressed.connect(_on_header_pressed.bind(col))
	btn.tooltip_text = String(columns[col])
	# 表头分隔线。去掉主题默认内容边距, 让按钮宽度=列宽,
	# 避免"列名驱动的窄列"因 Button 自带 padding 比内容列宽, 导致表头与数据错位。
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.16, 0.18, 0.35)
	sb.set_border_width_all(0)
	sb.set_content_margin_all(0)
	sb.border_width_right = 1
	sb.border_color = Color(0, 0, 0, 0.25)
	btn.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate() as StyleBoxFlat
	sbh.bg_color = Color(0.25, 0.28, 0.32, 0.5)
	btn.add_theme_stylebox_override("hover", sbh)
	var sbp := sb.duplicate() as StyleBoxFlat
	sbp.bg_color = Color(0.3, 0.33, 0.38, 0.6)
	btn.add_theme_stylebox_override("pressed", sbp)
	return btn


func _scroll_total_width() -> float:
	var w := 0.0
	for col in range(1, columns.size()):
		w += column_widths[col]
	return w


func _on_header_pressed(col: int) -> void:
	var col_name: StringName = columns[col]
	if sorting_by == col_name:
		sorting_reverse = not sorting_reverse
	else:
		sorting_by = col_name
		sorting_reverse = false
	_sort_rows()
	_update_header_arrows()
	_update_visible_rows(true)


func _update_header_arrows() -> void:
	if frozen_header_row.get_child_count() > 0:
		var fb := frozen_header_row.get_child(0) as Button
		if fb != null:
			fb.text = _column_header_text(0)
	for col in header_row.get_child_count():
		var btn := header_row.get_child(col) as Button
		if btn != null:
			btn.text = _column_header_text(col + 1)


## 可滚动列(列 1..n-1)的宽度数组, 供 scroll grid 布局
func _scroll_column_widths() -> Array[float]:
	var w: Array[float] = []
	for col in range(1, columns.size()):
		w.append(column_widths[col])
	return w


## 滚动防抖 + 脏标记 + 延迟 tooltip/预览
var _scroll_frame_pending := false
var _fill_count := 0          # 本帧实际填充的格子数(诊断用)
var _scroll_settle_frame := -1  # 滚动停止后的帧号(延迟预览用)
## 单元格上次填充指纹: node instance_id → "row:col:res_path"
var _cell_fill_cache := {}


func _update_visible_rows(force_rebuild: bool = false) -> void:
	var t_start := Time.get_ticks_usec()
	_fill_count = 0
	if columns.size() == 0 or rows.size() == 0:
		_recycle_all_rows()
		# 无类型 [] 字面量无法赋给 Array[float] 形参, 必须显式构造(见 _scroll_column_widths)
		grid.configure(_scroll_column_widths(), 0)
		var fw: Array[float] = []
		if columns.size() > 0:
			fw.append(column_widths[0])
		frozen_grid.configure(fw, 0)
		return

	var view_h := maxf(grid_scroll.size.y, 1.0)
	var new_first: int = grid.row_index_at(grid_scroll.scroll_vertical)
	# 累加起点必须是首行的绝对偏移 row_offsets[new_first], 而非 scroll_vertical:
	# 当滚动停在高行中部时(scroll_y > row_offsets[new_first]), 从 scroll_y 累加会把
	# 已滚过该行的像素虚增进去, 使 acc 提前触底 —— 窗口过早收窄, 视口下方行不被物化
	# ("下面的数据没更新")。从首行真实顶部开始累加才能精确覆盖完整视口。
	var acc := 0.0
	if grid.row_offsets.size() > 0:
		acc = grid.row_offsets[new_first]
	var vis_count := 0
	while new_first + vis_count < rows.size() and acc < grid_scroll.scroll_vertical + view_h:
		acc += grid.row_heights[new_first + vis_count]
		vis_count += 1
	var new_last := mini(new_first + vis_count + 1, rows.size())
	# 列窗口先于早退计算: 纯水平滚动不改行窗口, 仍需走列增删
	var cols_changed := _compute_visible_cols()
	if not force_rebuild and new_first == first_row and new_last == last_row and not cols_changed:
		return

	first_row = new_first
	last_row = new_last

	# 网格总行数/列宽配置(供滚动定位与布局); 冻结列宽需显式构造类型化数组
	grid.column_offset = 1
	grid.configure(_scroll_column_widths(), rows.size())
	frozen_grid.column_offset = 0
	var frozen_widths: Array[float] = [column_widths[0]]
	frozen_grid.configure(frozen_widths, rows.size())

	# 双轴虚拟化: 出窗行整行回收入池; 进场行物化(收编池行携带格); 水平变化时逐行增删列
	for row in _live_rows.keys():
		if int(row) < first_row or int(row) >= last_row:
			_recycle_row(int(row))
	for row in range(first_row, last_row):
		var created := not _live_rows.has(row)
		if created:
			_materialize_row(row)
		elif cols_changed:
			_sync_row_cells(row)
		if created or force_rebuild:
			_fill_row(row)

	_update_selection_visuals()


## ======= 行容器 + 双轴虚拟化 + 两级对象池 =======
## 垂直: 每行一个行容器(Control), 进出窗口只做 1 次节点停泊/摆位(194 格 → 1 节点)
## 水平: 列窗口化, 仅物化与水平视口相交的列(194 列不再全量建格)
## 行池: 整行回收时其格子原样随行入池(零逐格开销), 复用时按新窗口收编/裁剪/校验类型
## 格池: 列窗口收缩拆出的散格(已脱离父节点), 供任意行补格; Kind 分桶防跨目录类型错位
##
## ⚠ 尺寸钳制陷阱(曾导致快速滚动后格子重叠的伪影):
##   Control.size 赋值会被 custom_minimum_size 向上钳制(effective = max(size, minsize))。
##   池化格子在上一任行可能被 _fill_cell 写入大行高的 minsize; 复用到矮行时
##   先设 size 再由 _fill_cell 修正 minsize 的顺序来不及 —— size 已被顶成旧大值,
##   格子溢出压到相邻行, 视觉上"部分重叠"。
##   约定: 任何对池化格子的 size 赋值前, 必须先把 custom_minimum_size 归零
##   (见 _attach_cell / _fill_row), minsize 由随后的 _fill_cell 写入正确行高。

## 已物化行: row -> {"ctl": Control行容器, "frozen": DefTableCell, "cells": Dictionary(col->cell)}
var _live_rows := {}
var _row_pool: Array = []      # 空闲行容器(携带上次生命周期的格子)
var _cell_pool := {}           # key m{kind}/f{kind} -> Array[DefTableCell](已脱离父节点)
const CELL_POOL_MAX_PER_KIND := 512
const ROW_POOL_MAX := 48
## 停泊 X: ScrollContainer 裁剪区之外(无绘制无输入); Y 同理由整行停泊复用
const CELL_PARK_X := -100000.0

var _first_col := 0   # 水平可见全局列范围 [_first_col, _last_col)
var _last_col := 0


func _pool_key(frozen: bool, kind: int) -> StringName:
	return StringName(("f" if frozen else "m") + str(kind))


## 散格入池(脱离父节点): 打停泊标记+移出裁剪区, 复用时由调用方重新挂载摆位
func _pool_give_cell(cell: DefTableCellClass, frozen: bool) -> void:
	cell.set_meta(&"cell_parked", true)
	cell.position = Vector2(CELL_PARK_X, CELL_PARK_X)
	var p := cell.get_parent()
	if p != null:
		p.remove_child(cell)
	var key := _pool_key(frozen, cell.kind)
	var bucket: Array = _cell_pool.get(key, [])
	if bucket.is_empty():
		_cell_pool[key] = bucket
	if bucket.size() < CELL_POOL_MAX_PER_KIND:
		bucket.append(cell)
	else:
		cell.queue_free()


## 取散格(池空则新建); 由调用方提供目标父节点完成挂载
func _pool_take_cell(col: int, frozen: bool, target_parent: Node) -> DefTableCellClass:
	var bucket: Array = _cell_pool.get(_pool_key(frozen, _display_kind(col)), [])
	while not bucket.is_empty():
		var c: DefTableCellClass = bucket.pop_back()
		if is_instance_valid(c) and c.get_parent() == null:
			c.set_meta(&"cell_parked", false)
			target_parent.add_child(c)
			return c
	var cell := _make_cell(Vector2i(col, 0))
	target_parent.add_child(cell)
	return cell


func _recycle_all_rows() -> void:
	for row in _live_rows.keys():
		_recycle_row(int(row))


func _recycle_row(row: int) -> void:
	var entry: Dictionary = _live_rows.get(row, {})
	if entry.is_empty():
		return
	var ctl: Control = entry.get("ctl")
	if ctl != null and is_instance_valid(ctl):
		# 整行停泊: 格子随行原样保留(零逐格开销), 复用时按新窗口收编/裁剪
		ctl.set_meta(&"cell_parked", true)
		ctl.position = Vector2(CELL_PARK_X, CELL_PARK_X)
		if _row_pool.size() < ROW_POOL_MAX:
			_row_pool.append(ctl)
		else:
			ctl.queue_free()
	var f: DefTableCellClass = entry.get("frozen")
	if f != null and is_instance_valid(f):
		_pool_give_cell(f, true)
	_live_rows.erase(row)


## 取行容器(池中行携带的旧格子由本函数后继流程收编或裁剪)
func _take_row() -> Control:
	while not _row_pool.is_empty():
		var c: Control = _row_pool.pop_back()
		if is_instance_valid(c):
			c.set_meta(&"cell_parked", false)
			return c
	var ctl := Control.new()
	ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(ctl)
	return ctl


func _materialize_row(row: int) -> void:
	var ctl := _take_row()
	var rh: float = grid.row_heights[row] if row < grid.row_heights.size() else 32.0
	grid.fit_child_in_rect(ctl, Rect2(
		Vector2(0.0, grid.row_offsets[row] if row < grid.row_offsets.size() else 0.0),
		Vector2(_scroll_total_width(), rh)))
	ctl.set_meta(&"row_index", row)
	var fcell := _pool_take_cell(0, true, frozen_grid)
	frozen_grid.fit_child_in_rect(fcell, Rect2(
		Vector2(0.0, frozen_grid.row_offsets[row] if row < frozen_grid.row_offsets.size() else 0.0),
		Vector2(column_widths[0], frozen_grid.row_heights[row] if row < frozen_grid.row_heights.size() else 32.0)))
	var cells := {}
	_live_rows[row] = {"ctl": ctl, "frozen": fcell, "cells": cells}
	# 收编行容器携带的旧格子: 列在新窗口内且类型匹配 → 直接复用(内容稍后统一填充)
	for child in ctl.get_children():
		var c := child as DefTableCellClass
		if c == null:
			continue
		var pc: Vector2i = c.get_meta(&"cell_pos", Vector2i(-1, -1))
		if pc.x >= _first_col and pc.x < _last_col and c.kind == _display_kind(pc.x):
			cells[pc.x] = c
		else:
			_pool_give_cell(c, false)
	for col in range(_first_col, _last_col):
		if not cells.has(col):
			cells[col] = _pool_take_cell(col, false, ctl)


## 确保行内 col 列有正确类型的格子并摆位(类型不符=跨目录旧格 → 换新)
func _attach_cell(ctl: Control, cells: Dictionary, row: int, col: int) -> DefTableCellClass:
	var cell: DefTableCellClass = cells.get(col)
	var want_kind: int = _display_kind(col)
	if cell != null and (not is_instance_valid(cell) or cell.kind != want_kind):
		_pool_give_cell(cell, false)
		cell = null
	if cell == null:
		cell = _pool_take_cell(col, false, ctl)
	# 先解除上一任行高遗留的 minsize 钳制, 否则 size 会被向上钳成旧值(重叠伪影根因)
	cell.custom_minimum_size = Vector2.ZERO
	cell.position = Vector2(grid.column_offsets[col - 1], 0.0)
	cell.size = Vector2(column_widths[col], ctl.size.y)
	return cell


## 水平窗口变化: 对既有行做列增删(新增格立即填充)。返回新增数
func _sync_row_cells(row: int) -> int:
	var entry: Dictionary = _live_rows.get(row, {})
	if entry.is_empty():
		return 0
	var ctl: Control = entry.get("ctl")
	var cells: Dictionary = entry.get("cells")
	var added := 0
	for col in cells.keys():
		if int(col) < _first_col or int(col) >= _last_col:
			_pool_give_cell(cells[col], false)
			cells.erase(col)
	for col in range(_first_col, _last_col):
		if cells.has(col):
			continue
		cells[col] = _attach_cell(ctl, cells, row, col)
		_fill_cell(cells[col], Vector2i(int(col), row), _row_tint_for(row))
		added += 1
	return added


## 填充一行的全部在窗单元格(行容器定点摆位一次; 格子在行内静态 x 偏移)
func _fill_row(row: int) -> void:
	var entry: Dictionary = _live_rows.get(row, {})
	if entry.is_empty() or row >= rows.size():
		return
	var tint := _row_tint_for(row)
	var ctl: Control = entry.get("ctl")
	var rh: float = grid.row_heights[row] if row < grid.row_heights.size() else 32.0
	ctl.set_meta(&"row_index", row)
	ctl.size = Vector2(_scroll_total_width(), rh)
	grid.fit_child_in_rect(ctl, Rect2(
		Vector2(0.0, grid.row_offsets[row] if row < grid.row_offsets.size() else 0.0),
		Vector2(_scroll_total_width(), rh)))
	var f: DefTableCellClass = entry.get("frozen")
	if f != null and is_instance_valid(f):
		f.custom_minimum_size = Vector2.ZERO
		frozen_grid.fit_child_in_rect(f, Rect2(
			Vector2(0.0, frozen_grid.row_offsets[row] if row < frozen_grid.row_offsets.size() else 0.0),
			Vector2(column_widths[0], frozen_grid.row_heights[row] if row < frozen_grid.row_heights.size() else 32.0)))
		_fill_cell(f, Vector2i(0, row), tint)
	var cells: Dictionary = entry.get("cells")
	for col in cells:
		var cell: DefTableCellClass = cells[col]
		if not is_instance_valid(cell):
			continue
		var ci: int = int(col)
		# 同 _attach_cell: 先清 minsize 钳制再设尺寸
		cell.custom_minimum_size = Vector2.ZERO
		cell.position = Vector2(grid.column_offsets[ci - 1], 0.0)
		cell.size = Vector2(column_widths[ci], rh)
		_fill_cell(cell, Vector2i(ci, row), tint)


## 计算水平可见列窗口。返回是否变化
func _compute_visible_cols() -> bool:
	var prev_first := _first_col
	var prev_last := _last_col
	_first_col = 0
	_last_col = 0
	if columns.size() <= 1:
		_first_col = 1
		_last_col = 1
		return prev_first != 1 or prev_last != 1
	var hx := float(grid_scroll.scroll_horizontal)
	var vw := maxf(grid_scroll.size.x, 1.0)
	var offs: Array = grid.column_offsets   # 局部索引 0..n-2, 已含末端累计值
	for i in range(offs.size() - 1):
		if float(offs[i + 1]) <= hx:
			continue
		if float(offs[i]) >= hx + vw:
			break
		if _first_col == 0:
			_first_col = i + 1
		_last_col = i + 2
	# 左右各留 1 列缓冲, 平滑水平滚动
	_first_col = clampi(_first_col - 1, 1, maxi(columns.size() - 1, 1))
	_last_col = clampi(_last_col + 1, _first_col + 1, columns.size())
	return _first_col != prev_first or _last_col != prev_last


## 滚动停止后补拉可见 RESOURCE 格预览(滚动中延迟的请求在此统一发出)
func _backfill_resource_previews() -> void:
	if editor_interface == null or editor_interface.get_resource_previewer() == null:
		return
	var res_cols := {}
	for col in range(1, columns.size()):
		if _display_kind(col) == DefTableCellClass.Kind.RESOURCE:
			res_cols[col] = true
	if res_cols.is_empty():
		return
	for row in _live_rows:
		if int(row) >= rows.size():
			continue
		var cells: Dictionary = _live_rows[row].get("cells")
		for col in cells:
			if not res_cols.has(col):
				continue
			var cell: DefTableCellClass = cells[col]
			if not is_instance_valid(cell) or str(cell.get_meta(&"preview_path", "")) != "":
				continue
			var v = _get_value(rows[int(row)], int(col))
			if v is Resource:
				_request_resource_preview(cell, v)


## 行染色(don-tnowe row stylization): 取该行首个有效 Color 值, 低透明度染整行;
## 无颜色值则全透明(保持斑马纹)。_load_dir 后预计算, 避免逐格扫描
func _compute_row_tints() -> void:
	_row_tints.clear()
	for r in rows.size():
		var tint := Color(0, 0, 0, 0)
		for col in columns.size():
			if col < column_types.size() and column_types[col] == TYPE_COLOR:
				var v = _get_value(rows[r], col)
				if v is Color:
					tint = Color(v.r, v.g, v.b, 0.4)
					break
		_row_tints.append(tint)


func _row_tint_color(row: int) -> Color:
	return _row_tints[row] if row >= 0 and row < _row_tints.size() else Color(0, 0, 0, 0)


## 行染色 + 斑马纹调制: 颜色列的值染整行, 但奇数行对染色 RGB 轻微压暗,
## 让斑马纹在带色行上仍可感知(否则强色行的底纹明暗差会被完全盖掉)
func _row_tint_for(row: int) -> Color:
	var tint := _row_tint_color(row)
	if row % 2 == 1 and tint.a > 0.0:
		tint = Color(tint.r * 0.82, tint.g * 0.82, tint.b * 0.82, tint.a)
	return tint


## 悬停行高亮(B3, Excel crosshair 风格): 由 DefTableGrid 自绘(hover_row 属性),
## 主网格与冻结首列同步; 离开网格或滚动时清除
func _setup_hover_highlight() -> void:
	grid.mouse_exited.connect(func() -> void: _set_hover_row(-1))
	frozen_grid.mouse_exited.connect(func() -> void: _set_hover_row(-1))
	# 垂直滚动时鼠标下的行已变化, 清除避免高亮错位
	grid_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _set_hover_row(-1))


func _set_hover_row(row: int) -> void:
	grid.hover_row = row
	frozen_grid.hover_row = row


func _on_cell_mouse_entered(cell: DefTableCellClass) -> void:
	if cell == null or not is_instance_valid(cell):
		return
	var pos: Vector2i = cell.get_meta(&"cell_pos", Vector2i(-1, -1))
	_set_hover_row(pos.y)
	# 延迟 tooltip：hover 时按需构建(替代 fill 阶段的全量预构建)
	if pos.y < rows.size() and pos.x < columns.size():
		var tip := String(_cell_text(rows[pos.y], pos.x))
		var file_name: String = rows[pos.y].resource_path.get_file()
		cell.tooltip_text = "%s\n%s\n---\n%s" % [file_name, String(columns[pos.x]), tip]
	else:
		cell.tooltip_text = ""


func _make_cell(pos: Vector2i) -> DefTableCellClass:
	var kind := _display_kind(pos.x)
	var cell := DefTableCellClass.make_cell(kind)
	cell.custom_minimum_size = Vector2(column_widths[pos.x], 0)
	cell.set_meta(&"cell_pos", pos)
	cell.gui_input.connect(_on_cell_gui_input.bind(cell))
	# 悬停行高亮: 回调动态读取 cell_pos meta, 虚拟化复用单元格时定位仍正确
	cell.mouse_entered.connect(_on_cell_mouse_entered.bind(cell))
	return cell


## 列 -> 显示类型(参考 resources_spreadsheet_view 的类型化单元格)
func _display_kind(col: int) -> int:
	if col < 1:
		return DefTableCellClass.Kind.TEXT
	match column_types[col]:
		TYPE_COLOR:
			return DefTableCellClass.Kind.COLOR
		TYPE_OBJECT:
			return DefTableCellClass.Kind.RESOURCE
		TYPE_INT, TYPE_FLOAT:
			if column_hints[col] == PROPERTY_HINT_ENUM:
				return DefTableCellClass.Kind.ENUM
			return DefTableCellClass.Kind.NUMBER
		TYPE_BOOL:
			return DefTableCellClass.Kind.BOOL
		TYPE_ARRAY:
			return DefTableCellClass.Kind.ARRAY
		TYPE_DICTIONARY:
			return DefTableCellClass.Kind.DICT
	return DefTableCellClass.Kind.TEXT


func _fill_cell(cell: DefTableCellClass, pos: Vector2i, tint: Color = Color(1, 1, 1, 0)) -> void:
	_fill_count += 1
	# 脏标记：同 node 同 row 且资源未变则跳过重填(滚动微偏移时大量格子内容不变)
	var res_path: String = rows[pos.y].resource_path if pos.y < rows.size() else ""
	var fingerprint := "%d:%d:%s" % [pos.x, pos.y, res_path]
	var cache_key := cell.get_instance_id()
	if _cell_fill_cache.get(cache_key, "") == fingerprint:
		# 仅更新位置相关的最小属性(尺寸/选中态), 跳过文本/tooltip/预览重建
		cell.custom_minimum_size = Vector2(column_widths[pos.x], grid.row_heights[pos.y] if pos.y < grid.row_heights.size() else 24.0)
		cell.set_selected(pos in edited_cells)
		return
	_cell_fill_cache[cache_key] = fingerprint
	cell.set_meta(&"cell_pos", pos)
	cell.custom_minimum_size = Vector2(column_widths[pos.x], grid.row_heights[pos.y] if pos.y < grid.row_heights.size() else _measure_line_height())
	cell.bg_color = Color(1, 1, 1, 0.02) if pos.y % 2 == 0 else Color(0, 0, 0, 0.18)
	cell.row_tint = tint
	cell.set_selected(pos in edited_cells)
	var text := ""
	var is_empty := false
	if pos.y < rows.size() and pos.x < columns.size():
		text = _cell_text(rows[pos.y], pos.x)
		if text == "":
			is_empty = true
			text = "[color=#6e6e6e]—[/color]"
		elif cell.kind == DefTableCellClass.Kind.BOOL:
			var raw = _get_value(rows[pos.y], pos.x)
			text = "[color=#7bd88f]✓[/color]" if raw else "[color=#c25555]✗[/color]"
		cell.set_value_text(text)
		match cell.kind:
			DefTableCellClass.Kind.COLOR:
				var cval = _get_value(rows[pos.y], pos.x)
				if cval is Color:
					cell.set_color_value(cval)
			DefTableCellClass.Kind.RESOURCE:
				cell.set_meta(&"preview_path", "")
				cell.set_resource_preview(null)
				# 延迟预览：滚动中不请求，停止后统一补
				if not _scroll_frame_pending:
					var rval = _get_value(rows[pos.y], pos.x)
					if rval is Resource:
						_request_resource_preview(cell, rval)
		# 延迟 tooltip：不在 fill 阶段构建多行字符串，hover 时按需生成
	else:
		is_empty = true
		cell.set_value_text("")
	# 对齐
	cell.set_content_align(HORIZONTAL_ALIGNMENT_CENTER if (is_empty or cell.kind == DefTableCellClass.Kind.BOOL) else HORIZONTAL_ALIGNMENT_LEFT)


## 取单元格展示文本(带缓存): 计算型 getter 属性(如 EntityDef.tr_desc 递归构建整棵
## effect 树的描述)每次 res.get() 都全量重算, 布局+渲染两阶段至少访问两次,
## 按 Resource 实例缓存一份文本, 排序/滚动复用不受行序影响。
## 缓存在 _clear_measure_cache(目录切换)与粘贴提交后失效。
func _cell_text(res: Resource, col: int) -> String:
	var arr: PackedStringArray = _text_cache.get(res, PackedStringArray())
	if arr.size() <= col:
		while arr.size() < columns.size():
			arr.append(_to_text(_get_value(res, arr.size()), arr.size()))
		_text_cache[res] = arr
	return arr[col]


## 请求资源预览图(参考 resources_spreadsheet_view 的 cell_editor_resource)
func _request_resource_preview(cell: DefTableCellClass, res: Resource) -> void:
	if res is Texture2D:
		cell.set_meta(&"preview_path", res.resource_path)
		cell.set_resource_preview(res)
		return
	if editor_interface == null or editor_interface.get_resource_previewer() == null:
		return
	if res.resource_path == "":
		return
	cell.set_meta(&"preview_path", res.resource_path)
	editor_interface.get_resource_previewer().queue_resource_preview(
		res.resource_path, self, &"_on_preview_loaded", cell)


func _on_preview_loaded(path: String, preview: Texture2D, thumbnail: Texture2D, cell) -> void:
	if cell == null or not is_instance_valid(cell):
		return
	var target := cell as DefTableCellClass
	if target == null:
		return
	# 校验异步回调的路径与单元格当前内容一致, 拒绝虚拟化复用后残留的过期回调
	if str(target.get_meta(&"preview_path", "")) != path:
		return
	target.set_resource_preview(preview)


func _on_cell_gui_input(event: InputEvent, cell: Control) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var pos: Vector2i = cell.get_meta(&"cell_pos")
	if event.pressed:
		if event.is_command_or_control_pressed():
			_toggle_cell(pos)
		elif Input.is_key_pressed(KEY_SHIFT):
			_select_cells_to(pos)
		else:
			_deselect_all()
			_select_cell(pos)
		_update_sel_label()
		# Inspector 联动
		if pos.y < rows.size() and editor_interface != null:
			editor_interface.edit_resource(rows[pos.y])


## 定向更新单个单元格选中态(仅当该单元格当前可见), 替代全量遍历
func _set_cell_selected(cell_pos: Vector2i, selected: bool) -> void:
	var node := _get_cell_node(cell_pos)
	if node != null:
		node.set_selected(selected)


## 定位单元格节点(冻结列或滚动网格), 不可见返回 null。
## 行容器+列虚拟化模型: 从 _live_rows 按行取, 主格查 cells 字典(仅物化列存在)
func _get_cell_node(cell_pos: Vector2i) -> DefTableCellClass:
	if not _live_rows.has(cell_pos.y):
		return null
	var entry: Dictionary = _live_rows[cell_pos.y]
	if cell_pos.x == 0:
		var f: DefTableCellClass = entry.get("frozen")
		return f if is_instance_valid(f) else null
	var c = entry.get("cells", {}).get(cell_pos.x)
	if c != null and is_instance_valid(c):
		return c
	return null


func _deselect_all() -> void:
	for c in edited_cells:
		_set_cell_selected(c, false)
	edited_cells.clear()


func _select_cell(pos: Vector2i) -> void:
	if edited_cells.size() > 0 and edited_cells[0].x != pos.x:
		_deselect_all()
	if pos not in edited_cells:
		edited_cells.append(pos)
		_set_cell_selected(pos, true)
	_update_sel_label()


func _toggle_cell(pos: Vector2i) -> void:
	if edited_cells.size() > 0 and edited_cells[0].x != pos.x:
		_deselect_all()
	if pos in edited_cells:
		edited_cells.erase(pos)
		_set_cell_selected(pos, false)
	else:
		edited_cells.append(pos)
		_set_cell_selected(pos, true)
	_update_sel_label()


func _select_cells_to(pos: Vector2i) -> void:
	if edited_cells.size() == 0:
		edited_cells.append(pos)
		_set_cell_selected(pos, true)
		_update_sel_label()
		return
	var col := edited_cells[0].x
	if col != pos.x:
		return
	var last_row_idx := edited_cells[-1].y
	var lo := mini(last_row_idx, pos.y)
	var hi := maxi(last_row_idx, pos.y)
	for r in range(lo, hi + 1):
		var c := Vector2i(col, r)
		if c not in edited_cells:
			edited_cells.append(c)
			_set_cell_selected(c, true)
	_update_sel_label()


func _update_selection_visuals() -> void:
	# 空选早退(最常见路径); 非空时按 _live_rows 行身份遍历(仅物化列存在)
	if edited_cells.is_empty():
		return
	for row in _live_rows:
		var entry: Dictionary = _live_rows[row]
		var f = entry.get("frozen")
		if f != null and is_instance_valid(f):
			f.set_selected(Vector2i(0, row) in edited_cells)
		var cells: Dictionary = entry.get("cells")
		for col in cells:
			var c = cells[col]
			if is_instance_valid(c):
				c.set_selected(Vector2i(int(col), row) in edited_cells)


func _update_sel_label() -> void:
	if edited_cells.size() == 0:
		sel_label.text = "未选中"
		return
	var col := edited_cells[0].x
	var col_name := String(columns[col])
	var rows_in_sel: Array[int] = []
	for pos in edited_cells:
		if pos.y not in rows_in_sel:
			rows_in_sel.append(pos.y)
	sel_label.text = "选中 %d 个单元格 (列: %s, %d 行)" % [edited_cells.size(), col_name, rows_in_sel.size()]


func _on_v_scroll(_v: float) -> void:
	if not _syncing_scroll:
		_syncing_scroll = true
		frozen_grid_scroll.scroll_vertical = grid_scroll.scroll_vertical
		_syncing_scroll = false
	_schedule_scroll_update()


func _on_frozen_v_scroll(v: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	grid_scroll.scroll_vertical = frozen_grid_scroll.scroll_vertical
	_syncing_scroll = false
	_schedule_scroll_update()


## 滚动统一入口: 防抖合并同帧多次事件(下一帧统一重建), 并安排"停止检测"补拉预览。
## 原实现 _scroll_frame_pending 只置位不复位, 首次滚动后预览请求被永久禁用(bug), 此处一并修复。
var _scroll_seq := 0

func _schedule_scroll_update() -> void:
	_scroll_frame_pending = true
	_scroll_seq += 1
	var seq := _scroll_seq
	_update_visible_rows.call_deferred()
	await get_tree().create_timer(0.12).timeout
	if seq == _scroll_seq and _scroll_frame_pending:
		# 120ms 内无新滚动事件: 视为已停止, 复位标志并补拉可见资源格预览
		_scroll_frame_pending = false
		_backfill_resource_previews()


func _on_h_scroll(v: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	header_scroll.set_h_scroll(int(v))
	_syncing_scroll = false
	# 水平滚动 → 列窗口增删(经统一防抖, 与垂直共用一次重建)
	_schedule_scroll_update()


## 表头横向滚动反向同步(兜底: 任何表头滚动变化都回到主网格, 保证表头与数据列不错位)
func _on_header_h_scroll(v: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	grid_scroll.set_h_scroll(int(v))
	_syncing_scroll = false


## 同步冻结列底部高度: 主网格显示横向滚动条时, 冻结列底部补等高的占位, 使 name 列与其它列底部对齐
func _sync_frozen_spacer() -> void:
	if frozen_spacer == null or grid_scroll == null:
		return
	var hbar := grid_scroll.get_h_scroll_bar()
	var h := 0.0
	if hbar != null and hbar.visible and hbar.get_parent() == grid_scroll:
		h = hbar.get_minimum_size().y
	frozen_spacer.custom_minimum_size = Vector2(0, h)


func _copy_selected() -> void:
	if edited_cells.size() == 0:
		return
	var lines := PackedStringArray()
	var sorted := edited_cells.duplicate()
	sorted.sort()
	for pos in sorted:
		if pos.y < rows.size():
			lines.append(_cell_copy_text(_get_value(rows[pos.y], pos.x), pos.x))
	DisplayServer.clipboard_set("\n".join(lines))

	# 复制反馈: 显示首个单元格的行/列/内容
	var first: Vector2i = sorted[0] if sorted.size() > 0 else Vector2i()
	if first.y < rows.size() and first.x < columns.size():
		var row_name: String = rows[first.y].resource_path.get_file().get_basename()
		var col_name: String = String(columns[first.x])
		var content: String = _cell_copy_text(_get_value(rows[first.y], first.x), first.x)
		if content.length() > 40:
			content = content.substr(0, 40) + "…"
		sel_label.text = "已复制 %s · %s = %s" % [row_name, col_name, content]
	elif sorted.size() > 0:
		sel_label.text = "已复制 %d 个单元格" % sorted.size()


## 复制用文本: 保证能与 _from_text 往返还原(原始值序列化)
## 资源复制路径, 数组/字典用 JSON(含资源路径), 其余用 var_to_str(可被 str_to_var 还原)
func _cell_copy_text(value, col: int) -> String:
	if value == null:
		return ""
	var t := column_types[col]
	if t == TYPE_OBJECT:
		if value is Resource and value.resource_path != "":
			return value.resource_path
		return ""
	if t == TYPE_COLOR and value is Color:
		return "#" + (value as Color).to_html(false)
	if t == TYPE_ARRAY or t == TYPE_DICTIONARY or t == TYPE_PACKED_STRING_ARRAY or t == TYPE_PACKED_BYTE_ARRAY or t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_INT64_ARRAY or t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_FLOAT64_ARRAY:
		return JSON.stringify(_value_to_jsonable(value))
	return var_to_str(value)


func _paste_to_selected() -> void:
	if edited_cells.size() == 0:
		return
	if not DisplayServer.clipboard_has():
		printerr("DefTable: 剪贴板为空, 无法粘贴")
		return
	var col := edited_cells[0].x
	if not column_writable[col]:
		printerr("DefTable: 列 %s 只读, 无法粘贴" % String(columns[col]))
		return

	var clip := DisplayServer.clipboard_get().replace("\r", "")
	var lines := clip.split("\n")
	var values: Array = []
	var parse_failed: Array[bool] = []
	var first_error := ""
	var paste_each_line := lines.size() == edited_cells.size()
	var failed := 0
	for i in edited_cells.size():
		var src := lines[i] if paste_each_line else lines[0]
		var result: Dictionary = _from_text(src, col)
		values.append(result["value"])
		# 解析失败: 标记跳过, 防止把属性误清空成 null; 记录首个具体错误
		var bad := not bool(result["ok"])
		parse_failed.append(bad)
		if bad:
			failed += 1
			if first_error == "":
				first_error = String(result["error"])

	var undo_redo: Object = editor_interface.get_editor_undo_redo()
	if undo_redo == null:
		printerr("DefTable: 无法获取 EditorUndoRedoManager, 粘贴失败")
		return
	undo_redo.create_action("DefTable 粘贴赋值")
	var edited_resources := {}
	var changed := 0
	for i in edited_cells.size():
		var pos := edited_cells[i]
		if pos.y >= rows.size():
			continue
		if parse_failed[i]:
			continue
		var res: Resource = rows[pos.y]
		var pname: StringName = columns[pos.x]
		var old = res.get(pname)
		var newv = values[i]
		if old == newv:
			continue
		changed += 1
		undo_redo.add_do_property(res, pname, newv)
		undo_redo.add_undo_property(res, pname, old)
		edited_resources[res] = res.resource_path
	undo_redo.add_do_method(self, "_persist_resources", edited_resources.keys(), edited_resources.values())
	undo_redo.add_undo_method(self, "_persist_resources", edited_resources.keys(), edited_resources.values())
	undo_redo.commit_action()

	# 粘贴改值后文本/列宽/行高都可能变化: 失效缓存并整体重算布局
	_text_cache.clear()
	_compute_layout()
	_update_visible_rows(true)
	_update_sel_label()

	if failed > 0:
		printerr("DefTable: %d 个值无法解析(%s 列), 已跳过: %s" % [failed, String(columns[col]), first_error])
		sel_label.text += " (粘贴: %d 项无法解析: %s)" % [failed, first_error]
	elif changed > 0:
		sel_label.text += " (已粘贴 %d 项)" % changed
	else:
		sel_label.text += " (粘贴: 值与原数据相同, 未变更)"


func _persist_resources(res_list: Array, path_list: Array) -> void:
	for i in res_list.size():
		var res: Resource = res_list[i]
		var path: String = path_list[i]
		if path != "":
			ResourceSaver.save(res, path)
	if editor_interface != null and editor_interface.get_resource_filesystem() != null:
		editor_interface.get_resource_filesystem().scan()


func _shortcut_input(event: InputEvent) -> void:
	# 仅当 DefTable 是当前激活的 Main Screen(可见)时才处理快捷键, 避免误吞编辑器其他处的 Ctrl+C/V
	if not visible or not is_inside_tree():
		return
	# 处理 Ctrl+C / Ctrl+V 复制粘贴(在编辑器里 _shortcut_input 比 _unhandled_input 更早触发,
	# 能避开编辑器自身对 Ctrl+C 的节点复制快捷键消费)
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed:
			return
		var is_ctrl: bool = key_event.is_command_or_control_pressed()
		var keycode: Key = key_event.keycode
		if is_ctrl and keycode == KEY_C:
			_copy_selected()
			accept_event()
			return
		if is_ctrl and keycode == KEY_V:
			_paste_to_selected()
			accept_event()
			return
	# 兼容系统内置 ui_copy / ui_paste 动作
	elif event.is_action_pressed(&"ui_copy"):
		_copy_selected()
		accept_event()
		return
	elif event.is_action_pressed(&"ui_paste"):
		_paste_to_selected()
		accept_event()
		return


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed:
		return
	var keycode: Key = key_event.keycode
	if keycode == KEY_UP or keycode == KEY_DOWN:
		_navigate_vertical(1 if keycode == KEY_DOWN else -1)
		accept_event()
	elif keycode == KEY_LEFT or keycode == KEY_RIGHT:
		_navigate_horizontal(1 if keycode == KEY_RIGHT else -1)
		accept_event()


func _navigate_vertical(delta: int) -> void:
	if edited_cells.size() == 0:
		return
	var col := edited_cells[0].x
	var target_y := edited_cells[-1].y + delta
	target_y = clampi(target_y, 0, rows.size() - 1)
	_deselect_all()
	edited_cells.append(Vector2i(col, target_y))
	_ensure_row_visible(target_y)
	# ensure 可能触发虚拟化重建, 此处全量刷新选中态
	_update_selection_visuals()
	_update_sel_label()
	if editor_interface != null:
		editor_interface.edit_resource(rows[target_y])


func _navigate_horizontal(delta: int) -> void:
	if edited_cells.size() == 0:
		return
	var current_y := edited_cells[-1].y
	var col := clampi(edited_cells[0].x + delta, 0, columns.size() - 1)
	_deselect_all()
	var new_pos := Vector2i(col, current_y)
	edited_cells.append(new_pos)
	_set_cell_selected(new_pos, true)
	_update_sel_label()


func _ensure_row_visible(row: int) -> void:
	if row < first_row or row >= last_row:
		if row < grid.row_offsets.size():
			grid_scroll.scroll_vertical = grid.row_offsets[row]
# touch to trigger godot reload
