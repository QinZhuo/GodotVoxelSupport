@tool
class_name QVoxelEditSession
extends RefCounted
## 编辑会话 —— 一次「手势 → 数据 → 撤销 → 刷新」的完整链路，**不依赖任何节点**。
## 【为什么把这条链收在一个类里】它横跨四个模块：工具的纯几何（QVoxelBrushTool）、命令与撤销
## （QVoxelEditCommand / QVoxelUndoStack）、插件的数据层（QVoxelSource）、
## 以及渲染器。每个环节的接口都很窄，但**接线本身**有语义，散在视口脚本里的话：
##   ① 视口要同时懂"手势协议""命令封口""chunk 键换算""渲染器刷新"四件事 —— 一个只该翻译
##      输入的角色被撑成全能类；
##   ② 这条链无法无头测试（要建窗口、要跑帧），而它恰恰是最容易写错的地方（顺序错了不报错，
##      只表现为"画了没反应"或"撤销后贴图残留"）。
## 收进来之后视口只剩 `session.drag(pick)` 一句，而本类可以在 TestCase 里跑完整条链。
## 【依赖方向】QVoxelier → {VoxelSupport, DEVFramework}。本类只用插件的数据层与框架的命令基类，
## 反过来插件完全不认识它（见 QVoxelCommand 的分层说明）。
## 【刷新用回调，而不是持一个 VoxelRenderer】渲染器是节点（要进场景树、要跑帧），而本类要在
## 无头测试里跑。传一个 Callable（视口传 `renderer.request_update`）就够了：
## "让数据源作废"是**真逻辑**，"通知渲染器"只是**唤醒**。

## 被编辑的对象（手绘体素 + 修改器链，全项目唯一的常驻真值）。
var object: QVoxelModel

## 显示几何：视口渲染的那份数据层。对象改动后由本类负责让它按需重新取数。
var data: QVoxelSource

## 撤销栈（会话内）。刻意叫 history 而不是 undo：本类另有 undo() 方法，同名成员与方法冲突。
var history := QVoxelUndoStack.new()

## 当前工具（模式 / 笔刷尺寸由界面直接设）。
var tool := QVoxelBrushTool.new()

## 选区（体素坐标的整数盒）。空 = 没框任何东西。
## 【为什么选区住在会话里，而不是视口里】它是"编辑操作的输入"（复制 / 剪切 / 清空 / 移动都要
## 读它），而编辑的唯一入口是会话。放视口里的话，每个用到它的操作都得先把视口的盒子翻译一遍，
## 而无头测试也就没法构造"先框一块再复制"这类场景。
var selection := QVoxelSelection.new()

## 快速选区的连通判据：true = 同材质（颜色相连，默认）；false = 任意实心（几何相连）。
var select_by_color := true

## 剪贴板（复制 / 剪切 / 粘贴的载体）。跨对象、跨会话共用一份 —— 这就是"复制到另一个模型"。
var clipboard := QVoxelClipboard.new()

## 选区变化（视口据此重画线框）。粘贴 / 移动会连带改选区，故它不是一个只被"框选"触发的信号。
signal selection_changed

## 数据层被改动后唤醒渲染器的回调（一般传 `renderer.request_update`）。
## 为空 = 只作废数据源、不通知渲染（无头测试与"离线批量改数据"都走这条路）。
var request_render_update := Callable()

var _cmd: QVoxelEditCommand = null
## 当前手势累积的待写格（松手时一次性提交）。拖动期间不改对象，避免"踩着自己往上画"。
var _stroke_cells: Array[Vector3i] = []


# 装配

## 按对象装配显示层（QVoxelSource + 调色板）并绑成一个会话。
## 【为什么要有这个工厂】"对象 → 可渲染数据层"的接线步骤固定但零散（分辨率、块尺寸、材质表、
## 节点指向），漏一步的表现是"画了没反应"或"颜色全错"，而不是报错。收在这里之后，
## 视口与测试走的是同一条装配路径 —— 测试里绿的接线，运行时也一定是同一条。
## world 只用来取调色板（材质表就是它的 materials），可为 null（不渲染颜色的场合）。
static func create_for(obj: QVoxelModel, world: QVoxelWorld = null) -> QVoxelEditSession:
	var s := QVoxelEditSession.new()
	s.object = obj
	var d := QVoxelSource.new()
	# 节点就是数据源本身：手绘体素是链的输入，数据层每次求值直接读它。旧 QVoxelModelGenerator
	# 只是"把对象接到旧生成器接口上"的桥，接口收成 node 之后它没有存在理由了。
	d.node = obj
	# 显示尺寸取**求值输出盒**而不是 object.grid_size：链里若有重排型修改器（镜像 / 旋转 / 平铺），
	# 渲染出来的尺寸与手绘种子的尺寸不同（见 QVoxelSource.output_grid_size）。
	d.grid_size = d.output_grid_size()
	if world != null:
		_copy_palette(world, d)
	s.data = d
	return s


## 从一条射线命中信息造拾取上下文（视口把 `VoxelRay.cast` 的结果直接丢进来）。
## 【几何判据取自显示层，而不是对象】对象里只有**手绘种子**；修改器链的产出（风化 / 染色 /
## 程序化生成）只存在于显示层。拿对象判"实心"会让面笔与填充看不见链生成出来的那部分几何
## —— 表现为"点得中却刷不动"。这也是 Pick 把判据做成闭包的原因（工具层不必认识 QVoxelSource）。
func pick_from_hit(info: Dictionary, op := QVoxelBrushTool.Op.ADD, material_id := 1) -> QVoxelBrushTool.Pick:
	var hit: Vector3i = info.get(VoxelRay.KEY_HIT, Vector3i.MIN)
	var normal: Vector3i = info.get(VoxelRay.KEY_NORMAL, Vector3i.ZERO)
	var pick := QVoxelBrushTool.Pick.new()
	pick.hit = hit
	pick.normal = normal
	pick.op = op
	# 添加 = 往法线那侧长一格；移除 / 上色 = 就作用在命中格本身。
	# 这是 Pick 的既定约定（见 QVoxelBrushTool.Pick.place 的注释），也是唯一区分三态的地方。
	pick.place = VoxelRay.placement_of(hit, normal) if op == QVoxelBrushTool.Op.ADD else hit
	pick.material_id = material_id
	pick.grid = object.grid_size if object != null else Vector3i.ZERO
	if data != null:
		pick.solid = func(p: Vector3i) -> bool: return data.has_voxel(p)
		pick.material_at = func(p: Vector3i) -> int: return maxi(data.get_voxel(p), 0)
	return pick


# 手势（视口在输入事件里调用；顺序 begin → drag* → release）

## 按下。返回 false = 这次无处落笔（视口据此不改数据、不入撤销栈）。
func begin(pick: QVoxelBrushTool.Pick) -> bool:
	if object == null:
		return false
	if _cmd != null:
		# 上一笔没收尾（输入事件乱序 / 焦点切换）：先回滚。两条命令同时握着一批块，
		# 撤销时会互相盖掉对方的 after 快照。
		cancel()
	if not tool.begin(pick):
		return false
	if tool.selection_mode():
		# 选区手势不写任何格，故不建命令：产物是"框住了哪一块"，由 release() 从
		# tool.gesture_corners() 取走。省下这条命令，也让 release() 的封口逻辑对选区完全无感。
		return true
	# 落笔的帧在**按下时**定死并写进命令：手势期间即使用户切帧（面板不会，但接口允许），
	# 这一笔的撤销也仍然只回滚它真正改过的那一帧（见 QVoxelEditCommand.frame）。
	_cmd = QVoxelEditCommand.begin(object, edit_frame())
	_stroke_cells.clear()
	return true


# 帧（§12.6）

## 切换"正在编辑 / 预览的帧"。**只动游标**，不重渲染 —— 调用方接着调 `rebuild()`
## （时间轴面板把"切帧 + 重渲染"合成一步，见 QVoxelierTimelineSection）。
func set_active_frame(index: int) -> void:
	if object == null:
		return
	object.active_frame = maxi(0, index)


## 切帧并**同步**把该帧内容换进显示层（播放 / 点帧条走这条）。
## 【为什么不能走 _refresh 的"作废 + 异步重取"】那条路会让受影响 chunk 先作废、再等流式泵
## 按帧率去重新取数 —— 播放（每秒十几帧）根本来不及，表现为"播着播着体素不变了"。
## 去链后显示内容恒等于该帧的块表（块边长恒等于 chunk 边长），直接 `apply_block_table`
## 换缓冲即可：同步、只重建变化过的块。
func apply_frame(index: int) -> void:
	if object == null:
		return
	object.active_frame = maxi(0, index)
	if data == null:
		return
	data.apply_block_table(object.blocks_for(object.active_frame), false)
	_wake_renderer()


## 本会话落笔的目标帧：静态模型 = -1（静态源）；动画模型 = 当前帧（夹到有效范围）。
## 【为什么不另存一个 session.frame 字段】编辑的帧与渲染的帧**必须是同一个**（用户改的正是他看到的），
## 存两份迟早会分叉 —— 而分叉的表现是"画在第 2 帧、屏幕上第 5 帧多了几个体素"，极难自查。
## `object.active_frame` 已经是那份唯一游标，这里只是把它翻译成命令要的帧号。
func edit_frame() -> int:
	if object == null or not object.is_animated():
		return -1
	return clampi(object.active_frame, 0, object.frames.size() - 1)


## 拖动：**只累积待写的格，不碰对象 / 显示层**。
## 【为什么不在拖动中写】若边拖边写，刚画下的体素会立刻成为下一段拾取的"碰撞体"——同一笔里
## 画笔会踩着自己往上叠，越画越乱。整笔在松手时一次性提交，则整笔都作用在**落笔前的那张面**上。
## 拖动中的即时反馈由悬停预览（ghost）承担，用户照样看得见笔迹。
func drag(pick: QVoxelBrushTool.Pick) -> int:
	if tool.selection_mode():
		# 选区手势没有命令，但**端点必须跟着拖动更新** —— 否则 release 拿到的一直是按下那一刻的
		# 锚点，框永远是 1×1×1、移动永远是零位移。tool.drag 只更新端点、不产格。
		tool.drag(pick)
		return 0
	if _cmd == null:
		return 0
	var cells := tool.drag(pick)
	if cells.is_empty():
		return 0
	_stroke_cells.append_array(cells)
	return cells.size()


## 松手：把整笔（拖动累积 + 松手增量）一次性写进对象并封口入栈。返回是否真的改了东西。
func release() -> bool:
	if tool.selection_mode():
		# 角点必须在 tool.release() **之前**取：那一下会把手势状态清掉（选区手势的产物为空，
		# 调用它只为收摊）。
		var corners := tool.gesture_corners()
		var mode := tool.mode
		tool.release()
		if corners.size() < 2:
			return false
		if mode == QVoxelBrushTool.Mode.SELECT:
			# 没拖动 = 单击 → 快速选区（把与命中格连通的那一块自动框出来）；
			# 拖动 = 画一个矩形框选区。两种都在同一个「选择」工具里。
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


## 作废当前手势（Esc / 失焦）。拖动期间没写对象，故只需丢掉待提交的格，无需回滚。
func cancel() -> void:
	_cmd = null
	_stroke_cells.clear()
	tool.cancel()


## 悬停预览：返回"若现在按下会画出哪些格"。与落笔共用工具内的同一条形状分派 ——
## 所见即所画由构造保证，不靠预览与落笔两处对齐。
func hover(pick: QVoxelBrushTool.Pick) -> Array[Vector3i]:
	return tool.hover(pick)


## 手势中的完整预览：已累积的待写格 + 当前这一段的增量。
## 【为什么需要它】拖动期间不写对象（避免踩着自己画），于是显示层看不到笔迹；把"累积 + 增量"
## 一起交给预览，用户拖动时能看到**完整笔迹**，松手前就与落盘结果一致。
func preview_cells(pick: QVoxelBrushTool.Pick) -> Array[Vector3i]:
	var seg := tool.hover(pick)
	if _cmd == null or _stroke_cells.is_empty():
		return seg
	var out := _stroke_cells.duplicate()
	out.append_array(seg)
	return out


## 是否有进行中的手势。选区手势没有命令，故不能只看 _cmd —— 否则"正在框选"会被报成空闲。
func active() -> bool:
	return _cmd != null or tool.active()


# 选区与剪贴板（一次性操作，不走手势协议）

## 全选（"整个网格"）。已有相同选区时返回 false，让调用方不必自己比对。
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


## 复制选区里的体素到剪贴板。返回复制的体素数（0 = 选区里什么都没有）。
func copy_selection() -> int:
	if selection.is_empty():
		return 0
	clipboard = QVoxelClipboard.capture(selection, _material_at)
	return clipboard.count()


## 剪切 = 复制 + 挖空。剪贴板内容与"复制"完全一致（故用户可以连剪两处再贴两次）。
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


## 把剪贴板贴到 `at`（下角对齐）。返回真正落下的格数。
## 【为什么贴完要把选区落到新片上】用户粘完几乎必然接着要移动它 / 再复制它。选区留在原处
## 的话，下一次"移动"会作用在源位置上，而用户刚看到的是新位置 —— 那是个必然踩的坑。
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
## 【源与目标必须写进同一条命令】否则"挖空"与"落位"会变成两次独立撤销 —— 用户按一次 Ctrl+Z
## 只回滚一半，剩下的半截留在画面上，看着像撤销坏了。
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


# 撤销 / 重做

func can_undo() -> bool:
	return history.can_undo()


func can_redo() -> bool:
	return history.can_redo()


## 【为什么撤销之后也要刷新】命令只把**对象**恢复到 before 态，显示层仍是旧内容。
## 刷新粒度由命令自己给出（见 QVoxelCommand.dirty_bounds）：体素编辑只重算受影响的那几块。
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

## 把一次改动落到屏幕上。三步顺序不可换，每一步都在回答一个不同的问题：
##   ① 求值体积作废 —— 手绘体素是链的**输入**，输入变了整块体积必须重求值。
##      （求值精度仍由引擎的签名比对兜底：没变的链段一次遍历都不做。）
##   ② 只让受影响范围的 chunk 重新取数 —— 范围外的缓冲内容对未编辑区域**仍然正确**，
##      整对象重算纯属浪费（256³ 是 16M 格）。
##   ③ 唤醒渲染器 —— 数据层失效不发信号（那是"内容变更"事件，而失效是"缓存作废"），
##      重建的真实粒度由数据层的 mesh 脏账本给出。
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
		# **可生成范围**（见 QVoxelSource.can_generate_chunk）：落后一步，新长出来的区域就永远
		# 不渲染。作废范围取**新旧并集** —— 若分辨率缩了，旧的缓存 chunk 会落到新范围之外，不纳入
		# 作废就会以鬼影形式留在画面上。撤销 / 重做与首次施展都经过本函数，故这一处就够。
		if data.grid_size != size:
			hi = Vector3i(maxi(hi.x, data.grid_size.x - 1), maxi(hi.y, data.grid_size.y - 1),
					maxi(hi.z, data.grid_size.z - 1))
			data.grid_size = size
		data.invalidate_chunk_source_range(lo, hi)
	_wake_renderer()


## 输出盒尺寸。去链后恒等于模型的 grid_size。
func output_size() -> Vector3i:
	if object == null:
		return Vector3i.ZERO
	return object.grid_size


## 结构性改动之后的整体重算：分辨率与体素都可能全变（整对象变换），没有"局部"可言。
## 【为什么另给一个公开入口，而不是让调用方写 _refresh([])】空数组"影响整对象"是 QVoxelCommand
## 的默认语义，直接对外暴露一个空参调用只会让人猜"为什么是空数组"；给它一个名字，意图自明。
func rebuild() -> void:
	_refresh([])


# 内部

## 把整笔的格写进对象（权威）。显示层不在这里镜像 —— 松手后由 _refresh 按权威重新取数。
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


## 显示层的材质读取（0 = 空）。选区与剪贴板的取数**一律走显示层**：用户框的是他看得见的东西，
## 而看得见的那份含修改器链的产出（手绘种子里没有程序化生成的那部分）。
func _material_at(p: Vector3i) -> int:
	if data == null:
		return 0
	return maxi(data.get_voxel(p), 0)


func _set_selection(sel: QVoxelSelection) -> void:
	selection = sel
	selection_changed.emit()


## 把一次框选落到选区上。**夹进网格** —— 框到网格外的部分不是"选中了虚空"，是没框到。
func _set_box_selection(a: Vector3i, b: Vector3i) -> bool:
	if object == null:
		return false
	var top := object.grid_size - Vector3i.ONE
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z)).clamp(Vector3i.ZERO, top)
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z)).clamp(Vector3i.ZERO, top)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return false
	var sel := QVoxelSelection.from_corners(lo, hi)
	if sel.equals(selection):
		return false
	_set_selection(sel)
	return true


## 快速选区：从 seed 出发，把**连通**的体素整块选中（逐格集合，不是包围盒）。
## 判据由 select_by_color 决定：
##    true（默认）= 颜色相连（只收同材质的格，紧贴但异色的一块不会被吞进来）；
##    false       = 几何相连（见实心就收，跨颜色也连）。
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
		for d in QVoxelBrushGeometry.neighbors6():
			stack.append(p + d)
	var sel := QVoxelSelection.from_cells(cells)
	if sel.equals(selection):
		return false
	_set_selection(sel)
	return true


## 一次性写入的公共流程：建命令 → 由 `build` 填格 → 封口 → 入栈 → 刷新。返回真正改动的格数。
## 【为什么不复用 begin/drag/release】那套协议的前提是"产物要等手势结束才知道"。复制 / 剪切 /
## 粘贴 / 清空 / 移动的产物在按下按钮的那一刻就定了 —— 硬套手势只会凭空多出一段手势状态，
## 还要向用户解释"为什么按了复制之后必须松手才算数"。
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


## 把剪贴板里的格从 `origin` 处挖空（写 0）。只遍历**有内容的格**，空选区不产生任何写入。
func _clear_into(cmd: QVoxelEditCommand, clip: QVoxelClipboard, origin: Vector3i) -> void:
	var cells := clip.cells()
	for i in cells.size():
		var p := origin + cells[i]
		cmd.set_voxel(p.x, p.y, p.z, 0)


## 把剪贴板里的格贴到 `at`，每格带上它原来的材质。
## 【为什么不能借 _apply】`_apply` 给整批格同一个材质，而剪贴板里每格材质不同 ——
## 那正是"复制"要保住的东西。
func _stamp_into(cmd: QVoxelEditCommand, clip: QVoxelClipboard, at: Vector3i) -> void:
	var cells := clip.cells()
	var mats := clip.materials()
	for i in cells.size():
		var p := at + cells[i]
		cmd.set_voxel(p.x, p.y, p.z, mats[i])


## 挖空一份剪贴板（剪切 / 清空共用）。选区与 clip 同源，故原点直接取选区下角。
func _clear_clip(clip: QVoxelClipboard, origin: Vector3i, label: String) -> int:
	return _commit_once(func(cmd: QVoxelEditCommand) -> void:
		_clear_into(cmd, clip, origin), label)


func _wake_renderer() -> void:
	if request_render_update.is_valid():
		request_render_update.call()


## 世界的材质表 → 显示层的调色板。索引 0 恒为空气占位（材质 ID 0 = 空），故从 1 开始；
## "索引 == 材质 ID"的对齐由 add_material 保证，MATE 条目 → 材质的解释复用内核唯一的
## VoxelMaterial.from_mate（不在这里再写一遍位域拆解）。
static func _copy_palette(world: QVoxelWorld, data: QVoxelSource) -> void:
	for i in range(1, world.materials.size()):
		data.add_material(VoxelMaterial.from_mate(world.materials[i], i))
