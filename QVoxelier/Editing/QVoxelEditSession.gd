@tool
class_name QVoxelEditSession
extends RefCounted
## 编辑会话 —— 一次「手势 → 数据 → 撤销 → 刷新」的完整链路，**不依赖任何节点**。

## 被编辑的对象（手绘体素 + 修改器链，全项目唯一的常驻真值）。
var object: QVoxelModel

## 显示几何：视口渲染的那份数据层。
var data: QVoxelSource

## 撤销栈（会话内）。
var history := QVoxelUndoStack.new()

## 当前工具（模式 / 笔刷尺寸由界面直接设）。
var tool := QVoxelBrushTool.new()

## 选区（体素坐标的整数盒）。
var selection := QVoxelSelection.new()

## 快速选区的连通判据：true = 同材质（颜色相连，默认）；false = 任意实心（几何相连）。
var select_by_color := true

## 本次选区动作如何并入现有选区：0 = 替换；1 = 加选（Shift）；2 = 减选（Ctrl）。
var selection_combine := 0

## 剪贴板（复制 / 剪切 / 粘贴的载体）。
var clipboard := QVoxelClipboard.new()

## 选区变化（视口据此重画线框）。
signal selection_changed

## 数据层被改动后唤醒渲染器的回调（一般传 `renderer.request_update`）。
var request_render_update := Callable()

var _cmd: QVoxelEditCommand = null
## 当前手势累积的待写格（松手时一次性提交）。
var _stroke_cells: Array[Vector3i] = []

# 装配

## 按对象装配显示层（QVoxelSource + 调色板）并绑成一个会话。
static func create_for(obj: QVoxelModel, world: QVoxelWorld = null) -> QVoxelEditSession:
	var s := QVoxelEditSession.new()
	s.object = obj
	var d := QVoxelSource.new()
	# 节点就是数据源本身：手绘体素是链的输入，数据层每次求值直接读它。
	d.node = obj
	# 显示尺寸取**求值输出盒**而不是 object.grid_size：链里若有重排型修改器（镜像 / 旋转 / 平铺），
	d.grid_size = d.output_grid_size()
	if world != null:
		_copy_palette(world, d)
	s.data = d
	return s

## 从一条射线命中信息造拾取上下文（视口把 `VoxelRay.cast` 的结果直接丢进来）。
func pick_from_hit(info: Dictionary, op := QVoxelBrushTool.Op.ADD, material_id := 1) -> QVoxelBrushTool.Pick:
	var hit: Vector3i = info.get(VoxelRay.KEY_HIT, Vector3i.MIN)
	var normal: Vector3i = info.get(VoxelRay.KEY_NORMAL, Vector3i.ZERO)
	var pick := QVoxelBrushTool.Pick.new()
	pick.hit = hit
	pick.normal = normal
	pick.op = op
	# 添加 = 往法线那侧长一格；移除 / 上色 = 就作用在命中格本身。
	pick.place = VoxelRay.placement_of(hit, normal) if op == QVoxelBrushTool.Op.ADD else hit
	pick.material_id = material_id
	pick.grid = object.grid_size if object != null else Vector3i.ZERO
	if data != null:
		pick.solid = func(p: Vector3i) -> bool: return data.has_voxel(p)
		pick.material_at = func(p: Vector3i) -> int: return maxi(data.get_voxel(p), 0)
	return pick

# 手势（视口在输入事件里调用；顺序 begin → drag* → release）

## 按下。
func begin(pick: QVoxelBrushTool.Pick) -> bool:
	if object == null:
		return false
	if _cmd != null:
		# 上一笔没收尾（输入事件乱序 / 焦点切换）：先回滚。
		cancel()
	if not tool.begin(pick):
		return false
	if tool.selection_mode():
		# 选区手势不写任何格，故不建命令：产物是"框住了哪一块"，由 release() 从
		return true
	# 落笔的帧在**按下时**定死并写进命令：手势期间即使用户切帧（面板不会，但接口允许），
	_cmd = QVoxelEditCommand.begin(object, edit_frame())
	_stroke_cells.clear()
	return true

# 帧（§12.6）

## 切换"正在编辑 / 预览的帧"。
func set_active_frame(index: int) -> void:
	if object == null:
		return
	object.active_frame = maxi(0, index)

## 切帧并**同步**把该帧内容换进显示层（播放 / 点帧条走这条）。
func apply_frame(index: int) -> void:
	if object == null:
		return
	object.active_frame = maxi(0, index)
	if data == null:
		return
	data.apply_block_table(object.blocks_for(object.active_frame), false)
	_wake_renderer()

## 本会话落笔的目标帧：静态模型 = -1（静态源）；动画模型 = 当前帧（夹到有效范围）。
func edit_frame() -> int:
	if object == null or not object.is_animated():
		return -1
	return clampi(object.active_frame, 0, object.frames.size() - 1)

## 拖动：**只累积待写的格，不碰对象 / 显示层**。
func drag(pick: QVoxelBrushTool.Pick) -> int:
	if tool.selection_mode():
		# 选区手势没有命令，但**端点必须跟着拖动更新** —— 否则 release 拿到的一直是按下那一刻的
		tool.drag(pick)
		return 0
	if _cmd == null:
		return 0
	var cells := tool.drag(pick)
	if cells.is_empty():
		return 0
	_stroke_cells.append_array(cells)
	return cells.size()

## 松手：把整笔（拖动累积 + 松手增量）一次性写进对象并封口入栈。
func release() -> bool:
	if tool.selection_mode():
		# 角点必须在 tool.release() **之前**取：那一下会把手势状态清掉（选区手势的产物为空，
		var corners := tool.gesture_corners()
		var mode := tool.mode
		tool.release()
		if corners.size() < 2:
			return false
		if mode == QVoxelBrushTool.Mode.SELECT:
			# 没拖动 = 单击 → 快速选区（把与命中格连通的那一块自动框出来）；
			if corners[0] == corners[1]:
				return _select_connected(corners[0])
			return _set_box_selection(corners[0], corners[1])
		# 移动：没有选区时 move_selection 会默认整体（"直接拖一下就搬走全部"）。
		return move_selection(corners[1] - corners[0]) > 0
	if _cmd == null:
		return false
	var cmd := _cmd
	# 材质必须在 tool.release() 之前取（它会 cancel 掉手势状态）。
	var mat := tool.material()
	_stroke_cells.append_array(tool.release())
	_cmd = null
	_write_cells(cmd, _stroke_cells, mat)
	_stroke_cells.clear()
	if not cmd.commit():
		return false
	history.push(cmd)
	_refresh(cmd.dirty_bounds())
	return true

## 作废当前手势（Esc / 失焦）。
func cancel() -> void:
	_cmd = null
	_stroke_cells.clear()
	tool.cancel()

## 悬停预览：返回"若现在按下会画出哪些格"。
func hover(pick: QVoxelBrushTool.Pick) -> Array[Vector3i]:
	return tool.hover(pick)

## 手势中的完整预览：已累积的待写格 + 当前这一段的增量。
func preview_cells(pick: QVoxelBrushTool.Pick) -> Array[Vector3i]:
	var seg := tool.hover(pick)
	if _cmd == null or _stroke_cells.is_empty():
		return seg
	var out := _stroke_cells.duplicate()
	out.append_array(seg)
	return out

## 是否有进行中的手势。
func active() -> bool:
	return _cmd != null or tool.active()

# 选区与剪贴板（一次性操作，不走手势协议）

## 全选（"整个网格"）。
func select_all() -> bool:
	if object == null:
		return false
	var all := QVoxelSelection.all(object.grid_size)
	if all.equals(selection):
		return false
	_set_selection(all)
	return true

## 清掉选区（只清"框"，不碰数据）。
func deselect() -> bool:
	if selection.is_empty():
		return false
	_set_selection(QVoxelSelection.new())
	return true

## 复制选区里的体素到剪贴板。
func copy_selection() -> int:
	if selection.is_empty():
		return 0
	clipboard = QVoxelClipboard.capture(selection, _material_at)
	return clipboard.count()

## 剪切 = 复制 + 挖空。
func cut_selection() -> int:
	if object == null or selection.is_empty():
		return 0
	var clip := QVoxelClipboard.capture(selection, _material_at)
	if clip.is_empty():
		return 0
	clipboard = clip
	_clear_clip(clip, selection.lo(), "剪切")
	return clip.count()

## 挖空选区（保留剪贴板不动）。
func clear_selection() -> int:
	if object == null or selection.is_empty():
		return 0
	var clip := QVoxelClipboard.capture(selection, _material_at)
	if clip.is_empty():
		return 0
	return _clear_clip(clip, selection.lo(), "清空")

## 把剪贴板贴到 `at`（下角对齐）。
func paste(at: Vector3i) -> int:
	if object == null or clipboard.is_empty():
		return 0
	var target := clipboard.target(at)
	var clip := clipboard
	var n := _commit_once(func(cmd: QVoxelEditCommand) -> void:
		_stamp_into(cmd, clip, target.lo()), "粘贴")
	if n <= 0:
		return 0
	_set_selection(target)
	return n

## 把选区里的体素整体搬到 +delta。
func move_selection(delta: Vector3i) -> int:
	if object == null or delta == Vector3i.ZERO:
		return 0
	# 没有选区时默认整体（"直接拖一下 / 点一下轴，就搬走全部体素"）。
	if selection.is_empty():
		_set_selection(QVoxelSelection.all(object.grid_size))
	var clip := QVoxelClipboard.capture(selection, _material_at)
	if clip.is_empty():
		return 0
	var target := selection.offset_by(delta)
	var from := selection.lo()
	var n := _commit_once(func(cmd: QVoxelEditCommand) -> void:
		_clear_into(cmd, clip, from)
		_stamp_into(cmd, clip, target.lo()), "移动")
	if n <= 0:
		return 0
	_set_selection(target)
	return n

## 把选区里的体素绕**选区中心**旋转 axis 轴、quarters×90°（轴对齐整数旋转）。
func rotate_selection(axis: int, quarters: int) -> int:
	if object == null or quarters == 0:
		return 0
	if selection.is_empty():
		_set_selection(QVoxelSelection.all(object.grid_size))
	var clip := QVoxelClipboard.capture(selection, _material_at)
	if clip.is_empty():
		return 0
	var origin := selection.lo()
	var pivot := Vector3(origin) + (Vector3(selection.size()) - Vector3.ONE) * 0.5
	var basis := Basis([Vector3.RIGHT, Vector3.UP, Vector3.BACK][axis], float(quarters) * PI / 2.0)
	var cells := clip.cells()
	var mats := clip.materials()
	var old_abs: Array[Vector3i] = []
	var new_abs: Array[Vector3i] = []
	for i in cells.size():
		var abs := origin + cells[i]
		old_abs.append(abs)
		var rp := basis * (Vector3(abs) - pivot) + pivot
		new_abs.append(Vector3i(roundi(rp.x), roundi(rp.y), roundi(rp.z)))
	# 先挖空**全部**旧格，再落新格：新格与某个旧格重合时不会被旧格覆盖（与移动同一处置）。
	var n := _commit_once(func(cmd: QVoxelEditCommand) -> void:
		for i in old_abs.size():
			cmd.set_voxel(old_abs[i].x, old_abs[i].y, old_abs[i].z, 0)
		for i in new_abs.size():
			cmd.set_voxel(new_abs[i].x, new_abs[i].y, new_abs[i].z, mats[i]), "旋转")
	if n <= 0:
		return 0
	# 选区落到**旋转后的原选区盒**（而不是逐格集合的 AABB）：转的是"我框住的那块"，
	var box_lo := Vector3i(2147483647, 2147483647, 2147483647)
	var box_hi := Vector3i(-2147483648, -2147483648, -2147483648)
	var hi_inc := origin + selection.size() - Vector3i.ONE
	for cx in [origin.x, hi_inc.x]:
		for cy in [origin.y, hi_inc.y]:
			for cz in [origin.z, hi_inc.z]:
				var rp := basis * (Vector3(cx, cy, cz) - pivot) + pivot
				var q := Vector3i(roundi(rp.x), roundi(rp.y), roundi(rp.z))
				box_lo = Vector3i(mini(box_lo.x, q.x), mini(box_lo.y, q.y), mini(box_lo.z, q.z))
				box_hi = Vector3i(maxi(box_hi.x, q.x), maxi(box_hi.y, q.y), maxi(box_hi.z, q.z))
	_set_selection(QVoxelSelection.from_corners(box_lo, box_hi))
	return n

## 预览：选区绕中心旋转 axis/quarters 后的**绝对格**（不写数据）。
func preview_rotation(axis: int, quarters: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if object == null or selection.is_empty() or quarters == 0:
		return out
	var clip := QVoxelClipboard.capture(selection, _material_at)
	if clip.is_empty():
		return out
	var origin := selection.lo()
	var pivot := Vector3(origin) + (Vector3(selection.size()) - Vector3.ONE) * 0.5
	var basis := Basis([Vector3.RIGHT, Vector3.UP, Vector3.BACK][axis], float(quarters) * PI / 2.0)
	for c in clip.cells():
		var rp := basis * (Vector3(origin + c) - pivot) + pivot
		out.append(Vector3i(roundi(rp.x), roundi(rp.y), roundi(rp.z)))
	return out

# 撤销 / 重做

func can_undo() -> bool:
	return history.can_undo()

func can_redo() -> bool:
	return history.can_redo()

## 【为什么撤销之后也要刷新】命令只把**对象**恢复到 before 态，显示层仍是旧内容。
func undo() -> bool:
	var cmd := history.undo()
	if cmd == null:
		return false
	_refresh(cmd.dirty_bounds())
	return true

func redo() -> bool:
	var cmd := history.redo()
	if cmd == null:
		return false
	_refresh(cmd.dirty_bounds())
	return true

# 刷新

## 把一次改动落到屏幕上。
func _refresh(bounds: Array[Vector3i]) -> void:
	if object == null:
		return
	if data != null:
		data.invalidate()
		var size := output_size()
		var whole := bounds.size() < 2
		var lo := Vector3i.ZERO if whole else bounds[0]
		var hi := size - Vector3i.ONE if whole else bounds[1]
		# 【分辨率变了（链里加了 / 改了 / 撤了重排型修改器）必须在此同步】数据层的 grid_size 同时是
		if data.grid_size != size:
			hi = Vector3i(maxi(hi.x, data.grid_size.x - 1), maxi(hi.y, data.grid_size.y - 1),
					maxi(hi.z, data.grid_size.z - 1))
			data.grid_size = size
		data.invalidate_chunk_source_range(lo, hi)
	_wake_renderer()

## 输出盒尺寸。
func output_size() -> Vector3i:
	if object == null:
		return Vector3i.ZERO
	return object.grid_size

## 结构性改动之后的整体重算：分辨率与体素都可能全变（整对象变换），没有"局部"可言。
func rebuild() -> void:
	_refresh([])

## 程序化写入一批格子(供脚本 / MCP 调用): 与"粘贴/清空"等一次性操作等价 —— 建命令、写格、
func apply_cells(cells: Array[Vector3i], material: int, label := "脚本写入") -> int:
	return _commit_once(func(cmd: QVoxelEditCommand) -> void:
		for c in cells:
			cmd.set_voxel(c.x, c.y, c.z, material), label)

# 内部

## 把整笔的格写进对象（权威）。
func _write_cells(cmd: QVoxelEditCommand, cells: Array[Vector3i], mat: int) -> int:
	if cmd == null or cells.is_empty():
		return 0
	var written := 0
	for c in cells:
		if cmd.set_voxel(c.x, c.y, c.z, mat):
			written += 1
	return written

## 供移动预览用：把当前选区里的体素抓成剪贴板（相对选区下角 + 材质）。
func capture_selection() -> QVoxelClipboard:
	return QVoxelClipboard.capture(selection, _material_at)

## 显示层的材质读取（0 = 空）。
func _material_at(p: Vector3i) -> int:
	if data == null:
		return 0
	return maxi(data.get_voxel(p), 0)

func _set_selection(sel: QVoxelSelection) -> void:
	selection = sel
	selection_changed.emit()

## 把一次框选 / 快速选区的产物按当前组合方式（替换 / 加选 / 减选）并入选区。
func _apply_selection(new_sel: QVoxelSelection) -> bool:
	var result := new_sel
	if not selection.is_empty():
		if selection_combine == 1:
			result = selection.union_with(new_sel)
		elif selection_combine == 2:
			result = selection.subtract(new_sel)
	if result.equals(selection):
		return false
	_set_selection(result)
	return true

## 把一次框选落到选区上。
func _set_box_selection(a: Vector3i, b: Vector3i) -> bool:
	if object == null:
		return false
	var top := object.grid_size - Vector3i.ONE
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z)).clamp(Vector3i.ZERO, top)
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z)).clamp(Vector3i.ZERO, top)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return false
	return _apply_selection(QVoxelSelection.from_corners(lo, hi))

## 快速选区：从 seed 出发，把**连通**的体素整块选中（逐格集合，不是包围盒）。
func _select_connected(seed: Vector3i) -> bool:
	if object == null:
		return false
	var want := _material_at(seed)
	if want <= 0:
		return false
	var g := object.grid_size
	var visited := {}
	var stack: Array[Vector3i] = [seed]
	var cells: Array[Vector3i] = []
	while not stack.is_empty():
		var p: Vector3i = stack.pop_back()
		if visited.has(p):
			continue
		if p.x < 0 or p.y < 0 or p.z < 0 or p.x >= g.x or p.y >= g.y or p.z >= g.z:
			continue
		var m := _material_at(p)
		if m <= 0 or (select_by_color and m != want):
			continue
		visited[p] = true
		cells.append(p)
		for d in VoxelPrimitives.neighbors6():
			stack.append(p + d)
	return _apply_selection(QVoxelSelection.from_cells(cells))

## 一次性写入的公共流程：建命令 → 由 `build` 填格 → 封口 → 入栈 → 刷新。
func _commit_once(build: Callable, label: String) -> int:
	if object == null:
		return 0
	var cmd := QVoxelEditCommand.begin(object, edit_frame())
	cmd.label_override = label
	build.call(cmd)
	if not cmd.commit():
		return 0
	history.push(cmd)
	_refresh(cmd.dirty_bounds())
	return cmd.changed_voxels()

## 把剪贴板里的格从 `origin` 处挖空（写 0）。
func _clear_into(cmd: QVoxelEditCommand, clip: QVoxelClipboard, origin: Vector3i) -> void:
	var cells := clip.cells()
	for i in cells.size():
		var p := origin + cells[i]
		cmd.set_voxel(p.x, p.y, p.z, 0)

## 把剪贴板里的格贴到 `at`，每格带上它原来的材质。
func _stamp_into(cmd: QVoxelEditCommand, clip: QVoxelClipboard, at: Vector3i) -> void:
	var cells := clip.cells()
	var mats := clip.materials()
	for i in cells.size():
		var p := at + cells[i]
		cmd.set_voxel(p.x, p.y, p.z, mats[i])

## 挖空一份剪贴板（剪切 / 清空共用）。
func _clear_clip(clip: QVoxelClipboard, origin: Vector3i, label: String) -> int:
	return _commit_once(func(cmd: QVoxelEditCommand) -> void:
		_clear_into(cmd, clip, origin), label)

func _wake_renderer() -> void:
	if request_render_update.is_valid():
		request_render_update.call()

## 世界的材质表 → 显示层的调色板。
static func _copy_palette(world: QVoxelWorld, data: QVoxelSource) -> void:
	for i in range(1, world.materials.size()):
		data.add_material(VoxelMaterial.from_mate(world.materials[i], i))
