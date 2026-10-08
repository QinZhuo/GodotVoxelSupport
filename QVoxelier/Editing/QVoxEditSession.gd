@tool
class_name QVoxEditSession
extends RefCounted
## 编辑会话 —— 一次「手势 → 数据 → 撤销 → 刷新」的完整链路，**不依赖任何节点**。
##
## 【为什么把这条链收在一个类里】它横跨四个模块：工具的纯几何（QVoxBrushTool）、命令与撤销
## （QVoxVoxelEditCommand / QVoxUndoStack）、插件的数据层（VoxelData / QVoxObjectGenerator）、
## 以及渲染器。每个环节的接口都很窄，但**接线本身**有语义，散在视口脚本里的话：
##   ① 视口要同时懂"手势协议""命令封口""chunk 键换算""渲染器刷新"四件事 —— 一个只该翻译
##      输入的角色被撑成全能类；
##   ② 这条链无法无头测试（要建窗口、要跑帧），而它恰恰是最容易写错的地方（顺序错了不报错，
##      只表现为"画了没反应"或"撤销后贴图残留"）。
## 收进来之后视口只剩 `session.drag(pick)` 一句，而本类可以在 TestCase 里跑完整条链。
##
## 【依赖方向】QVoxelier → {VoxelSupport, DEVFramework}。本类只用插件的数据层与框架的命令基类，
## 反过来插件完全不认识它（见 QVoxCommand 的分层说明）。
##
## 【刷新用回调，而不是持一个 VoxelRenderer】渲染器是节点（要进场景树、要跑帧），而本类要在
## 无头测试里跑。传一个 Callable（视口传 `renderer.request_update`）就够了：
## "让数据源作废"是**真逻辑**，"通知渲染器"只是**唤醒**。

## 被编辑的对象（手绘体素 + 修改器链，全项目唯一的常驻真值）。
var object: QVoxObject

## 显示几何：视口渲染的那份数据层。对象改动后由本类负责让它按需重新取数。
var data: VoxelData

## 供数源。手绘体素是链的输入，故它必须能被作废（QVoxObjectGenerator.invalidate）。
var generator: QVoxObjectGenerator

## 撤销栈（会话内）。刻意叫 history 而不是 undo：本类另有 undo() 方法，同名成员与方法冲突。
var history := QVoxUndoStack.new()

## 当前工具（模式 / 笔刷尺寸由界面直接设）。
var tool := QVoxBrushTool.new()

## 数据层被改动后唤醒渲染器的回调（一般传 `renderer.request_update`）。
## 为空 = 只作废数据源、不通知渲染（无头测试与"离线批量改数据"都走这条路）。
var request_render_update := Callable()

var _cmd: QVoxVoxelEditCommand = null


# ----------------------------------------------------------------------------
# 装配
# ----------------------------------------------------------------------------

## 按对象装配显示层（VoxelData + QVoxObjectGenerator + 调色板）并绑成一个会话。
##
## 【为什么要有这个工厂】"对象 → 可渲染数据层"的接线步骤固定但零散（分辨率、块尺寸、材质表、
## 生成器指向），漏一步的表现是"画了没反应"或"颜色全错"，而不是报错。收在这里之后，
## 视口与测试走的是同一条装配路径 —— 测试里绿的接线，运行时也一定是同一条。
##
## world 只用来取调色板（材质表就是它的 materials），可为 null（不渲染颜色的场合）。
static func create_for(obj: QVoxObject, world: QVoxWorld = null) -> QVoxEditSession:
	var s := QVoxEditSession.new()
	s.object = obj
	var gen := QVoxObjectGenerator.new()
	gen.object = obj
	var d := VoxelData.new()
	d.grid_size = obj.grid_size
	if world != null:
		_copy_palette(world, d)
	# 顺序要紧：先 grid_size 再 generator —— generator 的 setter 会把数据层的 grid_size
	# 转成生成器的可生成范围（VoxelData._sync_generator_bounds），反过来的话生成器拿到 ZERO，
	# 于是"无限世界"模式生效，渲染器对视野内每个 chunk 都去提交生成。
	d.generator = gen
	s.generator = gen
	s.data = d
	return s


## 从一条射线命中信息造拾取上下文（视口把 `VoxelRay.cast` 的结果直接丢进来）。
##
## 【几何判据取自显示层，而不是对象】对象里只有**手绘种子**；修改器链的产出（风化 / 染色 /
## 程序化生成）只存在于显示层。拿对象判"实心"会让面笔与填充看不见链生成出来的那部分几何
## —— 表现为"点得中却刷不动"。这也是 Pick 把判据做成闭包的原因（工具层不必认识 VoxelData）。
func pick_from_hit(info: Dictionary, erase := false, material_id := 1) -> QVoxBrushTool.Pick:
	var hit: Vector3i = info.get(VoxelRay.KEY_HIT, Vector3i.MIN)
	var normal: Vector3i = info.get(VoxelRay.KEY_NORMAL, Vector3i.ZERO)
	var pick := QVoxBrushTool.Pick.new()
	pick.hit = hit
	pick.normal = normal
	pick.erase = erase
	# 画 = 往法线那侧长一格；擦 = 就擦命中格本身（擦掉面前的空格毫无意义）。
	# 这是 Pick 的既定约定（见 QVoxBrushTool.Pick.place 的注释），也是唯一区分两者的地方。
	pick.place = hit if erase else VoxelRay.placement_of(hit, normal)
	pick.material_id = material_id
	pick.grid = object.grid_size if object != null else Vector3i.ZERO
	if data != null:
		pick.solid = func(p: Vector3i) -> bool: return data.has_voxel(p)
		pick.material_at = func(p: Vector3i) -> int: return maxi(data.get_voxel(p), 0)
	return pick


# ----------------------------------------------------------------------------
# 手势（视口在输入事件里调用；顺序 begin → drag* → release）
# ----------------------------------------------------------------------------

## 按下。返回 false = 这次无处落笔（视口据此不改数据、不入撤销栈）。
func begin(pick: QVoxBrushTool.Pick) -> bool:
	if object == null:
		return false
	if _cmd != null:
		# 上一笔没收尾（输入事件乱序 / 焦点切换）：先回滚。两条命令同时握着一批块，
		# 撤销时会互相盖掉对方的 after 快照。
		cancel()
	if not tool.begin(pick):
		return false
	_cmd = QVoxVoxelEditCommand.begin(object)
	return true


## 拖动。返回本次写入的格数（live 工具 > 0，span 工具恒 0 —— 它们松手才产出）。
func drag(pick: QVoxBrushTool.Pick) -> int:
	if _cmd == null:
		return 0
	# 材质必须在 tool.drag() 之前取：release() 内部会 cancel()，那之后 _pick 就没了。
	var mat := tool.material()
	var n := _apply(_cmd, tool.drag(pick), mat)
	if n > 0:
		# 拖动中的即时反馈：显示层已就地把这批格改掉，唤醒渲染器走增量重建。
		# 唤醒放在这里而不是 _apply 里 —— 收尾那次由 _refresh 负责，免得一笔唤醒两回。
		_wake_renderer()
	return n


## 松手：封口成一条命令并入栈。返回"是否真的改了东西" —— false 时这一笔不占撤销单位。
func release() -> bool:
	if _cmd == null:
		return false
	var cmd := _cmd
	var mat := tool.material()
	# 命令是显式传进去的，不是从 _cmd 读的：此刻 _cmd 必须尽早清空（重入保护），
	# 而"写哪条命令"和"手势是否还活跃"是两件事 —— 让它们共用 _cmd 就会出现"先清空后写入 = 什么都没写"。
	_apply(cmd, tool.release(), mat)
	_cmd = null
	if not cmd.commit():
		# 空手势（点了一下但没改到任何格）：对象本来就没变，不该占一次撤销。
		# 显示层的镜像也只在真有写入时才做，故此处两边都干净。
		return false
	history.push(cmd)
	_refresh(cmd.dirty_bounds())
	return true


## 作废当前手势（Esc / 失焦）。
func cancel() -> void:
	var cmd := _cmd
	_cmd = null
	tool.cancel()
	if cmd == null or cmd.dirty_bounds().is_empty():
		return  # 还没写过任何格：对象没被碰过，不必回滚也不必刷新
	# 【必须回滚，而不是只丢命令】live 工具在拖动期间已经改了对象；只丢命令的话，那批改动
	# 就留在数据里而撤销栈里没有对应记录 —— 从此永远撤不掉，且下次"新建"会把它当成既有内容。
	cmd.undo()
	# 回滚也是"对象又变了" → 显示层同样按权威重新取数（镜像写过的块正好都在这个范围内）。
	_refresh(cmd.dirty_bounds())


## 悬停预览：返回"若现在按下会画出哪些格"。与落笔共用工具内的同一条形状分派 ——
## 所见即所画由构造保证，不靠预览与落笔两处对齐。
func hover(pick: QVoxBrushTool.Pick) -> Array[Vector3i]:
	return tool.hover(pick)


func active() -> bool:
	return _cmd != null


# ----------------------------------------------------------------------------
# 撤销 / 重做
# ----------------------------------------------------------------------------

func can_undo() -> bool:
	return history.can_undo()


func can_redo() -> bool:
	return history.can_redo()


## 【为什么撤销之后也要刷新】命令只把**对象**恢复到 before 态，显示层仍是旧内容。
## 刷新粒度由命令自己给出（见 QVoxCommand.dirty_bounds）：体素编辑只重算受影响的那几块。
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


# ----------------------------------------------------------------------------
# 刷新
# ----------------------------------------------------------------------------

## 把一次改动落到屏幕上。三步顺序不可换，每一步都在回答一个不同的问题：
##   ① 生成器的缓存体积作废 —— 手绘体素是链的**输入**，输入变了整块体积必须重求值。
##      （求值精度仍由引擎的签名比对兜底：没变的链段一次遍历都不做。）
##   ② 只让受影响范围的 chunk 重新取数 —— 范围外的缓冲内容对未编辑区域**仍然正确**，
##      整对象重算纯属浪费（256³ 是 16M 格）。
##   ③ 唤醒渲染器 —— 数据层失效不发信号（那是"内容变更"事件，而失效是"缓存作废"），
##      重建的真实粒度由数据层的 mesh 脏账本给出。
func _refresh(bounds: Array[Vector3i]) -> void:
	if object == null:
		return
	if generator != null:
		generator.invalidate()
	if data != null:
		var whole := bounds.size() < 2
		var lo := Vector3i.ZERO if whole else bounds[0]
		var hi := object.grid_size - Vector3i.ONE if whole else bounds[1]
		data.invalidate_chunk_source_range(lo, hi)
	_wake_renderer()


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 把一批格写进**两个**账本：对象（权威，撤销要快照）与显示层（镜像，为了即时反馈）。
## 返回真正改变的格数（两个调用方据此决定要不要唤醒渲染器）。
##
## 【为什么要镜像，而不是每帧重跑一次求值】拖动中若每帧都作废生成器的体积，就是每帧一次
## 全量求值（手绘层是 obj.to_volume() 的整块密集拷贝，还叠上整条修改器链）—— 大模型上必卡。
## 镜像只改被碰过的 chunk 缓冲并标记重建，代价与笔画长度成正比，与模型大小无关。
##
## 【镜像的账目为什么不会污染真值】镜像走的 `set_voxels` 会标记"待写盘"（PERSIST），
## 但松手时的 `_refresh` 会对同一批 chunk 调 `invalidate_chunk_source`，它把 PERSIST 清掉
## 并丢弃缓冲 → 下次取数重新按"流 > 生成器"读入，于是拿回的是**权威**内容。
## 换句话说：镜像只活在"这一笔还没结束"的窗口里。（该窗口内唯一能写盘的时机是显式
## `data.flush()`，编辑器只在存盘时调它，而存盘不会发生在拖动中。）
func _apply(cmd: QVoxVoxelEditCommand, cells: Array[Vector3i], mat: int) -> int:
	if cmd == null or cells.is_empty():
		return 0
	var written := 0
	for c in cells:
		if cmd.set_voxel(c.x, c.y, c.z, mat):
			written += 1
	if written <= 0:
		# 一格都没真变（刷了同一种颜色）：显示层不必跟着重建。
		return 0
	if data != null:
		# notify=false：唤醒交给本类的回调，刷新时机只有一处（渲染器另有每帧限流）。
		data.set_voxels(cells, mat, false)
	return written


func _wake_renderer() -> void:
	if request_render_update.is_valid():
		request_render_update.call()


## 世界的材质表 → 显示层的调色板。索引 0 恒为空气占位（材质 ID 0 = 空），故从 1 开始；
## "索引 == 材质 ID"的对齐由 add_material 保证，MATE 条目 → 材质的解释复用内核唯一的
## VoxelMaterial.from_mate（不在这里再写一遍位域拆解）。
static func _copy_palette(world: QVoxWorld, data: VoxelData) -> void:
	for i in range(1, world.materials.size()):
		data.add_material(VoxelMaterial.from_mate(world.materials[i], i))
