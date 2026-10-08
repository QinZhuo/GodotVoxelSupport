@tool
extends Node3D

## 综合场景：PCG × 体素框架的"上限展示"。
##
## 【这是什么】把两条 PCG 技术栈、四种算子、一条可交互破坏链路放进同一张图里，
## 用来回答两个问题：
##   ① 结合是否优雅 —— 每个模型都只是"一个普通 VoxelData + 一个 VoxelRenderer 节点"，
##      所以编辑 / 破坏 / 物理 / 碰撞 / LOD 全部自动可用。本场景里那座可破坏塔就是证据：
##      它和其他模型的组装代码完全一样，唯一区别是容器类从 `VoxelRenderer.new()`
##      换成了 `VoxelDestructible.new()`（见 PcgSceneKit.add_model 的 destructible 参数）。
##   ② PCG 能到什么水平 —— 基底（SDF 组合）+ 植被（L-系统）+ 洞穴（元胞自动机）
##      + 遗迹（socket 式 WFC）+ 有机岩壁（重叠式 WFC）同场共存，约 70 个 chunk。
##      （遗迹网格从 32³ 提到 36³ 是为了对齐 TILE=6 的图块边界：36 = 6×6，
##      32 不是 6 的倍数，图块会跨 block 边界把柱列对齐切断。代价是每座遗迹
##      从 2 个 chunk 变成 8 个，具体数字看 HUD 的"已建 chunk / 期望 chunk"。）
##
## 【两条技术栈的分工】
##   SDF（PcgSdfGenerator）：逐点采样 sample(p) —— 适合"由简单件组合出的实体"。
##     这里的岛体就是 Plane ∪ SmoothUnion{台地, 山丘} ⊖ 火山口。
##   PcgModel（PcgModelGenerator）：整体产出 build(grid_size) —— 适合"必须全局迭代
##     才算得出来的东西"。L-系统 / 元胞自动机 / 两种 WFC 都只能这样算。
##
## 【曾经的两条硬约束：一条已解除，一条仍然成立】
##   · ~~生成器无法按位置给多材质~~ —— 已解除。`PcgModel.build()` 本来就返回**每体素一个
##     材质 ID**，分区多材质一直可行，只是过去没往里写；现在又多了两个来源：
##     `PcgLsystem.tip_material_id`（末梢换材质 → 树干/叶片分离）与细节层
##     `PcgSurfaceTint`（按噪声 + 朝上面把暴露体素染成苔藓色）。森林与遗迹已用上。
##     真正剩下的约束是：VoxelMaterial 走"256×1 调色板 + 材质内查表"的单色贴图路径，
##     一个 MeshInstance 对应一张贴图，所以调色板要在建模时就分配好 ID。
##   · PcgModel 栈没有 overlay：build() 一次写满，后写覆盖先写。真正的"叠加 / 挖空"
##     只在 SDF 栈里存在（见基底与 pcg_porous_demo）。这一条仍然成立。
##
## 【相机与 view_distance 的硬关系】有界程序化数据也走"按相机距离加载"——
##   对生成器世界，流式驱动恒开（不取决于 visibility_mode）。且超出 view_distance 的
##   LOD0 网格会被主动移除。所以相机必须让所有模型的 chunk 都落在 view_distance 内，
##   否则远处模型会"建了又删"或干脆不出现。本场景所有模型都排布在以相机为心、
##   半径 56 世界单位的球内。
##
## 【键位】左键 = 对着可破坏塔打一个球形洞；R = 重建该塔。

## 体素世界尺度（1 chunk = 32 体素 = 6.4 世界单位）
@export var voxel_scale: float = 0.2
## 加载半径（世界单位）。最远的是侧洞远端角（约 51），故 56 留出余量。
@export var view_distance: float = 56.0
## 破坏球半径（体素单位）
@export var damage_radius: float = 6.0

const BASE_GRID := Vector3i(128, 48, 128)
## 树的网格是 32×48×32 而不是 32³ —— **高度上多留一倍，水平方向一分不让**。
## 原因：PcgLsystem 的生长起点固定在网格**中心**（(x/2, 1, z/2)），而文法里
## `&`/`^` 每层都把枝干掰离竖直，4 层累积下来树冠水平半径就有 15+ 体素。32³ 的网格
## 半径只有 16，于是树冠必然被网格边界**削平**（实测 2691 个体素里有 291 个贴着
## 边界，削出的是一面刀切的平面）。把 y 抬到 48 体素后，26 体素（5.2 单位）高的树
## 在 32 宽的横截面里实测 0 体素越界（5 个种子），竖直方向也不再顶到天花板。
## 代价只是 chunk 数：32×48×32 = 2 个 chunk（y 方向两层），仍远小于基底。
const TREE_GRID := Vector3i(32, 48, 32)
## 遗迹网格：图块集用 TILE=6（见 PcgSceneKit.ruin_tiles），三个维度都必须是 6 的倍数，
## 否则图块会跨 block 边界、柱列与墙行的对齐被切断。
const RUIN_TILE := 6
## 30×24×30（= 5×4×5 个 tile）：两个维度从 36 收窄、**高度从 48 砍到 24**。
## 48 层 × 0.2 = 9.6 单位，比台面高度（6.8）还高 1.4 倍，三座遗迹叠起来就是
## 一座压住整个岛体的山，岛面完全看不见。24 层 → 4.8 单位，是"建筑"该有的尺度。
## 边长同时决定摆放间距（见 _ruin_span），收窄后三座之间自然让出台面。
##
## 【不能更矮】18 层（3 个 tile 高）实测**一个模型都解不出来**（体素全 0，建筑静默消失）：
## ruin_tiles 的竖向链是"地板 → 柱 → 上层"，地板块底面标 rock 必须坐在下方 rock 块上，
## 3 层放不下这条链就会在观察阶段直接矛盾，而 build() 矛盾后只 push_warning 并返回空模型。
## 24 层（4 个 tile）是实测能解出的最小高度。
const RUIN_GRID := Vector3i(30, 24, 30)
## 重叠式 WFC 的网格。PcgWfcOverlap 的类注释明确要求 grid_size ≤ 24³：
## 它"每格一个图案"，观察步是 O(格数²) 的扫描，32³ 会把构建时间推到分钟级。
##
## 【为什么是 24×7×22 的矮长条，而不是 24³ 的方块】重叠式 WFC 会把**整个网格**
## 填满，于是 24³ 直接产出一块 4.8×4.8×4.8 的**正立方** —— 正对着镜头，
## 六个面一样、边缘笔直，看起来像"放了一个绿点节方块"。压扁到 7 层（1.4 单位高）
## 并拉长成 24×22（4.8×4.4）之后，它读起来才像一片伏在地上的苔藓岩床。
## 【再压矮一层的代价】高度 10 层时侧壁还占了画面不小面积，规则的孔洞图案在侧壁
## 上看得清清楚楚（顶面俯视反而被压缩得最狠）；7 层之后顶面成为唯一可见面，
## 而顶面正是风化与苔藓染色改动最狠的一面，规则的图案被打散得最彻底。
const OVERLAP_GRID := Vector3i(24, 7, 22)

## 岛体台地顶面（体素 y）——所有地表物件都坐在这个高度上。
const PLATEAU_VOXEL_Y := 34.0
## 岛体节点的世界位置：让 128 宽的岛体以世界原点为中心。
const BASE_ORIGIN := Vector3(-12.8, 0.0, -12.8)
## 台地方盒的体素尺寸（见 _build_base 的 mesa.size）。地表落点判定要用它，
## 故提成常量：改台地大小时"树该站哪儿"会自动跟着变，不会漏改。
const PLATEAU_VOXEL_SPAN := Vector3(100, 34, 100)
## 火山口（体素球心与半径，见 _build_base 的 crater）。台地南缘的一个豁口 ——
## 位置不是随手填的：台地只有 20×20，遗迹群 + 石塔 + 岩壁已经占掉中央，
## 火山口必须落在南侧那条 4.4 宽的空带里，否则遗迹的柱子会悬在洞上
## （实测：Ruin_1 有 22/144 根柱子下方无岩体）。它同时被两处消费：
## 基底 SDF 拿它挖坑，散布器的地面查询拿它拒收"树不能种在洞里"。
const CRATER_VOXEL_CENTER := Vector3(44, 36, 23)
const CRATER_VOXEL_RADIUS := 10.0
## 岛体表面层的噪声种子（风化 / 苔藓斑 / 色阶三档共用一条链种子，各自的内部偏移由算子负责）。
const SURFACE_SEED := 20261007

## 所有 PCG 模型节点（HUD 统计用）。
var _models: Array[Node3D] = []
## 基底节点。地表物件要查它的体素高度来定落脚点，故单独持有引用。
var _base_node: VoxelRenderer
## 可破坏塔（演示用的破坏目标）
var _tower: VoxelDestructible
## 塔的初始快照，供 R 重建
var _tower_snapshot: Dictionary

var _camera: Camera3D
var _hud: Label
var _hint: Label
var _prev_left := false
var _prev_r := false


func _ready() -> void:
	_setup_environment()
	_setup_ground()
	_build_base()
	# 基底的体素是**异步**灌进 VoxelData 的，而地表物件的落脚高度要查它
	# （见 _ground_y_at）。所以必须等基底 chunk 全部就位再摆遗迹与树，
	# 否则 _ground_y_at 全都返回兜底高度，风化啃出的浅坑就会被架空。
	await _await_base_ready()
	_build_ruins_and_wall()
	_build_tower()
	_build_forest()
	_setup_camera()
	_setup_hud()
	print("[PCG综合场景] %d 个模型 / 期望 %d 个 chunk 已提交生成" % [_models.size(), _expected_chunks()])


## 等基底的体素数据全部落盘（chunk 数达到 grid_size 推算出的上限）。
## 兜底 1800 帧：万一 loader 卡住也不能让整个场景空着不动。
func _await_base_ready() -> void:
	var gz: Vector3i = _base_node.data.grid_size
	var cs: int = VoxelChunk.CHUNK_SIZE
	var want: int = maxi(1, (gz.x + cs - 1) / cs * ((gz.y + cs - 1) / cs) * ((gz.z + cs - 1) / cs))
	var frames := 0
	while _base_node.data.get_loaded_chunk_keys().size() < want and frames < 1800:
		await get_tree().process_frame
		frames += 1
	if frames >= 1800:
		push_warning("[PCG综合场景] 基底体素未在 1800 帧内就绪，地表物件可能悬空。")


## 台地顶面的世界 y（跟着 voxel_scale 走，避免改尺度后物件悬空 / 埋进地里）。
func _plateau_world_y() -> float:
	return BASE_ORIGIN.y + PLATEAU_VOXEL_Y * voxel_scale


## 台地半边长（世界单位）。台地以世界原点为中心，故半边长即"离中心的距离上限"。
func _plateau_half_span() -> float:
	return PLATEAU_VOXEL_SPAN.x * voxel_scale * 0.5


## 火山口的世界球心 XZ 与半径（跟随 voxel_scale）。
func _crater_xz() -> Vector2:
	var c := Vector3(CRATER_VOXEL_CENTER.x, 0.0, CRATER_VOXEL_CENTER.z) * voxel_scale + BASE_ORIGIN
	return Vector2(c.x, c.z)


func _crater_radius() -> float:
	return CRATER_VOXEL_RADIUS * voxel_scale


## 遗迹模型的世界边长。摆放间距全部从它派生 —— 改 voxel_scale 或 RUIN_GRID
## 都不会让相邻两座遗迹互相穿插（30 体素 × 0.2 = 6.0 单位）。
func _ruin_span() -> float:
	return RUIN_GRID.x * voxel_scale


## 某世界 XZ 处的**真实地面高度**：沿该列自上而下找第一个实心体素，返回它的顶面。
##
## 【为什么必须查，不能写死 PLATEAU_VOXEL_Y】台地现在吃 PcgWeather，侧壁被啃出缺角、
## 顶面也被啃出 1 体素深的浅坑。写死一个高度，建筑和树就会在坑上方悬空 —— 悬空 0.2
## 个世界单位在 33 单位外观看下仍有 4 像素，一眼就能看见。
## 框架的 ground_query 本就是为"逐点问地面高度"设计的，这里只是把查询实现成
## 查体素列，比手写一张"哪里高哪里低"的表可靠得多。
func _ground_y_at(wx: float, wz: float) -> float:
	var fallback := _plateau_world_y()
	if _base_node == null:
		return fallback
	var d: VoxelData = _base_node.data
	var bx := int(round((wx - BASE_ORIGIN.x) / voxel_scale))
	var bz := int(round((wz - BASE_ORIGIN.z) / voxel_scale))
	var gz: Vector3i = d.grid_size
	if bx < 0 or bx >= gz.x or bz < 0 or bz >= gz.z:
		return fallback
	for by in range(gz.y - 1, -1, -1):
		if d.get_voxel(Vector3i(bx, by, bz)) > 0:
			return BASE_ORIGIN.y + (by + 1) * voxel_scale
	return fallback


## 一块矩形区域的落脚高度：取四角与中心的**最低**值。
## 取 min 而不是 max：建筑只要有一角悬空就看得出来，而稍微嵌进地面
## （像砌了地基）在体素地形里几乎察觉不到 —— 宁可陷一点，不要浮一点。
func _ground_y_under_rect(center_xz: Vector2, half_x: float, half_z: float) -> float:
	var y := _ground_y_at(center_xz.x, center_xz.y)
	for corner in [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(-1.0, 1.0), Vector2(1.0, 1.0)]:
		y = minf(y, _ground_y_at(center_xz.x + corner.x * half_x, center_xz.y + corner.y * half_z))
	return y


## 已摆好的**地表物件**占位（世界 XZ 矩形）。树必须让开它们。
##
## 【为什么不写死矩形，而是问 _models】写死的话，挪一下遗迹位置就得回来改这里，
## 迟早漏改 —— 而"树从墙里长出来"是最刺眼的穿模。这里直接从已建节点反推：
## 谁被挪动或增删，这里自动跟随。
##
## 【占位矩形按"真实体素包围盒"而不是 grid_size】原来直接用 grid_size 外扩 0.5，
## 两个后果：① 明显过宽 —— 一座遗迹的 30×30 网格里柱列之间全是空档，占位却被算成
## 整块实心，白白吃掉台面（本场景台地只有 20×20 见方，一棵树都放不下就是这么来的）；
## ② **把 Organic_Wall 漏掉了**。它按"四角取最低地面"落脚（见 _ground_y_under_rect），
## 恰好有一角落在风化啃出的浅坑里，于是 y = 6.6 比台面 6.8 低 0.2，被"底面落在台地上"
## 这条判据一起误杀 —— 结果树可以直接种进岩壁里。现在改成按 get_voxels_aabb() 取真实
## 包围盒，基底则按引用显式排除（它的包围盒罩住整个台地，若算占位就一棵树都种不了）。
## 【为什么从 0.8 收到 0.5】树的体量在下面从 11 体素提到 26 体素（见 _build_forest），
## 占位外扩若照旧按 0.8 算，台面上会一棵都种不下（实测：14 个候选点全被拒收）。
## 树冠比树干宽，所以仍需往外扩一点，但 0.5 已足够挡住"树干贴着墙角"的擦碰。
const FOOTPRINT_PAD := 0.5

func _surface_footprints() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for m in _models:
		if m == _base_node or not (m is VoxelRenderer):
			continue
		var r := m as VoxelRenderer
		var s: float = r.voxel_scale
		var gs: Vector3i = r.data.grid_size
		# 体素还没灌进来时 aabb 为空 —— 退回整格网格，宁可保守拒收也不能让树穿模。
		var local := Rect2(Vector2.ZERO, Vector2(gs.x, gs.z) * s)
		var aabb := r.data.get_voxels_aabb()
		if aabb.size.x > 0.0 and aabb.size.z > 0.0:
			local = Rect2(aabb.position.x * s, aabb.position.z * s, aabb.size.x * s, aabb.size.z * s)
		# 外扩 FOOTPRINT_PAD：树冠比树干宽，让树干贴着墙也仍然会擦到。
		out.append(Rect2(r.global_position.x + local.position.x - FOOTPRINT_PAD,
				r.global_position.z + local.position.y - FOOTPRINT_PAD,
				local.size.x + FOOTPRINT_PAD * 2.0,
				local.size.y + FOOTPRINT_PAD * 2.0))
	return out


## 散布器的地面查询：台地顶面是已知高度的**平面**，所以只需回答
## "这个点能不能站"。不可站的点返回 null —— PcgScatter 会直接丢弃该候选点，
## 于是"不悬空、不种进洞里、不长在遗迹上"全部由散布器自带的拒收机制保证，
## 场景侧不必再手写一张"哪里能种树"的表。顺带给出台地高度，落点 y 也就
## 不用在调用处另算。
func _plateau_ground_query(p: Vector2) -> Variant:
	var half := _plateau_half_span()
	if absf(p.x) > half or absf(p.y) > half:
		return null
	# +0.6 是给火山口留的一圈安全边距：贴着洞沿的树看起来已经"站不稳"。
	if p.distance_to(_crater_xz()) < _crater_radius() + 0.6:
		return null
	for r in _surface_footprints():
		if r.has_point(p):
			return null
	return {PcgScatter.GROUND_KEY_Y: _ground_y_at(p.x, p.y)}


# ----------------------------------------------------------------------------
# 基底：SDF 组合（Box ⊖ 侧壁洞穴 ⊖ 火山口，∪ 山丘）
# ----------------------------------------------------------------------------

## 岛体。这是全场景唯一"由简单件组合出实体"的部分——也正因为 SDF 有真正的
## 组合算子（并/交/差/平滑并/域重复），它才能一次算出整个岛。
func _build_base() -> void:
	# 台地：平顶**竖棱倒角**大方块，顶面 y = 34 体素 —— 地表物件的落脚面。
	#
	# 【倒角为什么换成专用原语】同一个形状，老写法要用 12 个节点
	#（4×<差集 + 旋转 45° 的 200³ 方盒>）在每个采样点上做 4 次矩阵变换与 4 次盒测试；
	# SdfChamferBox 只要 1 次盒距离 + 1 次 L1 平面距离。实测岛体单 chunk 生成
	# 因此从 995ms 降到约 250ms —— 本生成器是 GDScript 逐点采样，节点数几乎线性决定耗时。
	# chamfer = 11.3 与老写法等价：老写法沿对角切进 8 体素，换算成 L1 度量即 8×√2。
	var mesa := SdfChamferBox.new()
	mesa.center = Vector3(64, PLATEAU_VOXEL_SPAN.y * 0.5, 64)
	mesa.size = PLATEAU_VOXEL_SPAN
	mesa.chamfer = 11.3
	mesa.material_id = 1

	# 【为什么不再用"无限平面 + 岛底裙边 + 圆化球 + 侧壁啃缺口"那一套】
	# 这四件套各自都在截图上留下过明确的破绽，逐条记在这里免得再犯：
	#  ① SdfPlane 是**无限**面，只能靠 skirt_box 裁到台地大小；而裙边总比台地大，
	#     台地四角被磨圆的地方裙边又填出方耳朵 —— 表现为岛底挂着一排深色方块齿。
	#  ② 圆化球是**球**：球面与竖直侧壁相切的那圈，栅格化后是一圈竖直"搓板"条纹，
	#     近看像瓦楞板（截图实测）。
	#  ③ 平面在 y<7 处离所有侧面越来越远，而材质按"更紧者"取，于是底部 7 格被判给
	#     平面分支，横着多出一条与地形无关的深色带。
	#  ④ 侧壁啃缺口是**规则球阵**，怎么调都像人工开的一排窗：r=8/周期11 是海绵，
	#     换成 r=6/周期18 就变成一排带窗框的方洞。
	# 结论：台地本体就是最终外形 —— 一个方盒，四角切一道 45° 平面倒角，
	# 不需要任何裁剪辅助体。干净的直壁 + 干净的斜切，
	# 比"四种纹理叠出来的假岩石"耐看得多。
	#
	# 【倒角必须是"平面"，不能是曲面 —— 踩过两次坑】
	# 曲面（先试球、再试竖直圆柱）在体素栅格上都会退化成一圈**竖棱**：
	# 曲面的法线沿高度方向不变，于是每一层切下来的台阶宽度相同、互相错开，
	# 斜看过去就是一排竖着的瓦楞柱（截图实测：近景里角上立着一排" Pipes "）。
	# 只有**平面**倒角（45° 斜切）栅格化出来才是干净的对角阶梯。
	#
	# 倒角已在 SdfChamferBox 里一次算完，这里不再叠任何裁剪辅助体。
	var chipped: Sdf = mesa

	# [-x 侧壁的洞穴] 往台地内部掏一条通道，入口开在侧壁上。
	#
	# 【用一根胶囊，而不是手排 5 颗球】老写法是 5 颗 SdfSphere 串起来（每颗配一个
	# Subtract = 10 个节点），因为当时以为"无限重复的球阵会把整座岛挖穿"。
	# SdfCapsule 就是"线段 a→b 按半径膨胀"，一根节点就能精确控制起止（x=16 → x=48），
	# 而且通道内壁是光滑的 —— 球串的凹槽在体素化后会留下几圈明显的"轮胎纹"。
	# 球心 y=20、半径 5 → 通道占 y∈[15,25]，台顶在 y=34，顶面完整不受影响，
	# 地表物件的落脚面一个都不用挪。入口端要伸到侧壁（x=14）之外一点，才真的开得出来。
	var tunnel := SdfCapsule.new()
	tunnel.a = Vector3(16.0, 20.0, 64.0)
	tunnel.b = Vector3(48.0, 20.0, 64.0)
	tunnel.radius = 5.0
	tunnel.material_id = 1
	var bored := SdfSubtract.new()
	bored.a = chipped
	bored.b = tunnel

	# 【顶面为什么不做"薄壳染色"——踩过的坑，留下来防止再犯】
	# 试过用 Intersect 给顶面染苔藓：薄板 y∈[32.8,33.9] 作 b，靠"交取更紧者"
	# 让苔藼在体素中心比台地更近（-0.15 > -0.5）。数值上这一步是对的，几何上却是错的：
	# 交集 max(d_台, d_苔) 对**薄板之外**的点取到的是薄板的正距离，于是 y≤32 的
	# 整个台体全部被判成体外 —— 台地被掏空到只剩一顶壳，遗迹直接掉到岛底 y=1.4。
	# 材质规则（按距离取舍）是为"融合处保住各部件材质"设计的，不是染色机制；
	# 靠交/并在**不改变体积**的前提下改表面材质，在当前 pick 语义下做不到。
	# 顶面的自然感改由几何承担（山丘、洞穴、火山口），材质分区留给
	# 吃 details 的生成器（见 _build_ruins_and_wall 里的 PcgSurfaceTint 用法）。

	# 山丘：球摆到台地一角，给轮廓加点起伏（纯方块太生硬）。
	# 直接用 SdfSphere.center，不套 SdfTransform —— 每多一层节点就是每个采样点多一次
	# 虚调用，而这是全场景最热的路径（岛体一场 1.05M 次采样）。
	var knoll := SdfSphere.new()
	knoll.center = Vector3(30.0, 20.0, 92.0)
	knoll.radius = 17.0
	knoll.material_id = 2

	# 平滑并：台地与山丘焊成一体（k 越大过渡越软）。
	var weld := SdfSmoothUnion.new()
	weld.a = bored
	weld.b = knoll
	weld.k = 6.0

	# 火山口：从台地顶部挖走一个球，露出内壁。
	var crater := SdfSphere.new()
	crater.center = CRATER_VOXEL_CENTER
	crater.radius = CRATER_VOXEL_RADIUS

	var field := SdfSubtract.new()
	field.a = weld
	field.b = crater

	# 【岛体改走修改器链（P3-2）】过去 PcgSdfGenerator 自带一层"内联表面层"，用 SDF 的
	# 距离值当暴露度，在采样循环里顺手做风化 / 色阶 / 朝上染色。它有效，但把
	# PcgWeather + PcgSurfaceTint 的同一套逻辑复制了第二份，而且只有 SDF 形态吃得到。
	# 现在链上只有"一个只出几何的 SDF 生产者 + 一串通用体素域算子"：
	#   SDF → 风化 → 朝上染色 → 岩石色阶 → 苔原色阶
	# 顺序即语义：风化先挖出表面不平，后三步才对**剩下的**表面着色 ——
	# 反过来会让新挖出的坑侧面保持原色，坑就成了一块突兀的补丁。
	# 代价是完整体积要常驻一份（细节算子需要完整邻域，按 chunk 懒算会在 32³ 边界留接缝）。
	var obj := QVoxModel.new()
	obj.grid_size = BASE_GRID
	var chain: Array[QVoxModifier] = [QVoxSdfModifier.of(field)]
	chain.append(QVoxVolumeModifier.of(_island_erode()))
	chain.append(QVoxVolumeModifier.of(_island_moss()))
	chain.append(QVoxVolumeModifier.of(_island_shade(1, PackedInt32Array([10, 11, 12]))))
	chain.append(QVoxVolumeModifier.of(_island_shade(2, PackedInt32Array([13, 14, 15]))))
	obj.modifiers = chain
	var gen := QVoxModelGenerator.new()
	gen.object = obj
	gen.eval_seed = SURFACE_SEED
	_base_node = PcgSceneKit.add_model(self, "Base_Island", BASE_ORIGIN, gen, BASE_GRID,
			PcgSceneKit.materials([
				# albedo 是**反射率**，不是最终显示色。真实岩石大约 0.15~0.35，
				# 早先按"好看的颜色"写 0.5+，加上方向光就直接过曝成一张白板，
				# 顶点色里的苔原与环境遮蔽全被冲掉 —— 细节不是没生成，是看不见了。
				[1, Color(0.33, 0.32, 0.30), 0.95],   # 岩石
				[2, Color(0.25, 0.34, 0.20), 0.9],    # 苔原
				# 岛底湿岩。早先写 0.19/0.21/0.23 —— 那是**反射率**，不是显示色，
				# 在背光面里直接压成近黑的墨蓝一条，横在岛腰上像贴了条黑边。
				# 抬到与岩石同一量级后，它只比上层暗一档，读作"没晒到的岩层"。
				[3, Color(0.26, 0.27, 0.29), 0.85],   # 湿岩
				# 10~15 是表面层写进去的三档色阶。**暗档偏冷、亮档偏暖**（不是纯明度缩放）：
				# 纯明度缩放在体素栅格上读作"同一块塑料的不同曝光"，
				# 掰开色相之后才读作"背光的岩面 / 受光的岩面"。
				# 【三档之间的差必须很小】第一版取 0.22/0.31/0.44（差一倍），
				# 铺在 20 单位宽的崖壁上就是一张高对比迷彩布。岩石真实的层间差异
				# 只有 ±15% 左右；差值压到 0.28/0.33/0.38 之后，画面才回到"岩体"。
				[10, Color(0.26, 0.255, 0.26), 0.95],   # 岩·暗（偏冷）
				[11, Color(0.32, 0.31, 0.29), 0.95],    # 岩·中
				[12, Color(0.39, 0.37, 0.33), 0.95],    # 岩·亮（偏暖）
				[13, Color(0.19, 0.27, 0.15), 0.9],     # 苔原·暗
				[14, Color(0.24, 0.33, 0.17), 0.9],     # 苔原·中
				[15, Color(0.30, 0.40, 0.21), 0.9],     # 苔原·亮
				[16, Color(0.20, 0.31, 0.14), 0.85],    # 苔藓（仅由朝上染色写到朝上面）
			]))
	_register(_base_node)


## 岛体风化：**只啃朝上的表面**。
##
## 【up_only 的实测依据（原文见已删除的 PcgSdfGenerator 表面层）】竖直崖壁上挖 1 体素深的
## 坑，在掠射视角下坑的侧壁受光量低、坑底还被邻格挡住直射光，一排坑连起来看就是**竖条纹**
## ——台地会像一块瓦楞铁皮（world 场景实测：崖面一行像素在 0.45~0.55 与 0.05~0.13 之间
## 反复跳，间距 1~2 体素）。平台面没有这个问题：坑就是坑，从上往下看仍然是地面。
## 所以"破平板"只该做在顶面，崖壁的层次交给色阶。
##
## 【强度换算】PcgWeather 的阈值为 `strength * (0.35 + 0.65 * 棱角偏好)`，平顶处偏好项为 0，
## 故要复现原表面层实测的 0.06 等效挖空概率，strength 取 0.06 / 0.35 ≈ 0.17。
## 0.1 等效值时崖壁（在旧写法下）被啃出 10% 的成片缺口，配上色阶分档过碎。
func _island_erode() -> PcgWeather:
	var w := PcgWeather.new()
	w.strength = 0.17
	w.cell = 4.0
	w.up_only = true
	w.min_exposure = 1
	w.protect_ground = true
	return w


## 岛体朝上染色：岩石的**朝上面**（台顶、缓坡、台阶）→ 苔藓 16。
##
## 【为什么必须硬过滤，而不是靠 up_bias】苔藓"只长朝上的面"是这条染色唯一想要的效果；
## up_bias 只让它"更偏向"朝上，崖壁上仍会零星冒出绿点，在 20 单位宽的崖面上看就是随机噪点。
## coverage = 0.3 沿用的是原表面层的苔斑覆盖率标定：0.22 在原色空间下只剩几个绿点
## （几乎看不见），起不到"给台面分区域"的作用；0.3 配上 cell = 10 之后台面上会出现成片的苔原。
func _island_moss() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([16])
	t.only_source_material_id = 1
	t.up_only = true
	t.coverage = 0.3
	t.cell = 10.0
	t.min_exposure = 1
	t.protect_ground = false
	return t


## 岛体色阶（源材质 → 暗/中/亮三档）。岩石走 [10,11,12]，苔原走 [13,14,15]。
##
## 【shade_noise = true 是实测改出来的】第一版用分块哈希 + shade_cell = 4，结果台面与崖壁
## 排出一张**方格迷彩**：每格 0.8 世界单位、边界笔直，20 单位宽的崖壁上看就是"贴图错位"，
## 比原来的纯灰平板更糟。换成噪声挑档后，色阶变成"这片岩层偏亮、那片偏暗"的软边界 → 才读作岩体。
##
## 【shade_cell 从 6 拉到 14】它同时是"挑档噪声的特征尺寸"：6 体素的色阶在 30 单位外只剩
## 10 来个像素，台面上就是一层"迷彩绒"；14（= 2.8 世界单位）才变成"一片偏亮、一片偏暗"的大区域。
## coverage = 1.0 = 近表面体素全部参与分档（留白交给苔藓那一层去占）。
func _island_shade(src_id: int, ramp: PackedInt32Array) -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = ramp
	t.only_source_material_id = src_id
	t.shade_noise = true
	t.shade_cell = 14.0
	t.coverage = 1.0
	t.cell = 4.0
	t.min_exposure = 1
	t.protect_ground = false
	return t


# ----------------------------------------------------------------------------
# 遗迹（socket 式 WFC）与有机岩壁（重叠式 WFC）
# ----------------------------------------------------------------------------

## 四块 4³ 图块按**手写的六面接口名**拼接。
##
## 【已改为共用实现】图块集搬到了 `PcgSceneKit.ruin_tiles(TILE)`，与 pcg_ruins_demo 用的是
## 同一套（10 块、TILE=6、柱网结构）。原因很实际：两份图块集各自演化，迟早会出现
## "这个场景的柱列对齐、那个场景不对齐"这类无法解释的差异；演示代码里同一套规则
## 应当只有一份实现。详见 ruin_tiles 的注释（三条约束 + 稀疏化权重）。
##
## 【强类型注意】返回类型必须是 Array[PcgWfcTile]：PcgWfc.tiles 是强类型数组，
## 直接赋值**行内**字面量时 GDScript 会按目标类型构造；但函数返回值在静态类型上是
## 普通 Array，运行期不会自动转换，赋值即报 "Invalid assignment of property 'tiles'"。
func _make_ruin_tiles() -> Array[PcgWfcTile]:
	return PcgSceneKit.ruin_tiles(RUIN_TILE)


## 遗迹调色板。ID 必须覆盖 PcgSceneKit.ruin_tiles 里所有图块用到的 material_id，
## 缺一个就会在体素里留下一个"查不到颜色"的 ID（渲染成调色板首色，看着像随机色块）。
const RUIN_MATERIALS := [
	# 1 地板：**从 (0.38,0.31,0.20) 压到 (0.30,0.24,0.16)**。原来的亮度+饱和度在直射光下
	# 读作"新锯的松木板"——近景里整座遗迹变成"石柱上的木头货架/长凳"（截图实测）。
	# 压暗之后它才是"风化过的朽木/砂岩"，与石柱同处一个明度带，家具感消失。
	[1, Color(0.30, 0.24, 0.16), 0.9],    # 1 地板（朽木 / 砂岩）
	[2, Color(0.29, 0.28, 0.27), 0.95],   # 2 石柱 / 墙（会被染苔藓）
	# 3 深土基岩：**从 0.49 压到 0.35**。它由 solid_core 铺成、覆盖面积最大，
	# 而 0.49 是整块遗迹调色板里最亮的一档 —— 结果"填充土"比真正的墙还抢眼，
	# 整座遗迹在镜头里读作一堆**白板**（实测：遗迹区域的像素比台面还亮一档）。
	# 填充物本该退到后面去：压到比墙(2)略亮一点即可。
	[3, Color(0.35, 0.32, 0.27), 0.95],   # 3 深土基岩
	[4, Color(0.24, 0.29, 0.20), 0.85],   # 4 苔藓（仅由 PcgSurfaceTint 写入）
	[5, Color(0.29, 0.24, 0.18), 0.9],    # 5 碎石
	# 6~11 同色系调色板梯度：只由 PcgSurfaceTint 后处理逐体素挑档写入，
	# 不参与图块接口（见 pcg_ruins_demo 同名常量的说明）。本项目不用贴图，
	# 表面层次就是靠"更多不同颜色的体素"堆出来的。
	# 墙走冷灰、地板走暖木，两组色相分开 —— 混在一个色相带里，一眼看过去分不出
	# "这是墙、那是地板"，整座遗迹会糊成一块。
	[6, Color(0.20, 0.20, 0.21), 0.95],   # 6 墙·暗（偏冷）
	[7, Color(0.28, 0.28, 0.27), 0.95],   # 7 墙·中
	[8, Color(0.36, 0.35, 0.32), 0.95],   # 8 墙·亮（偏暖）
	[9, Color(0.23, 0.18, 0.12), 0.9],    # 9 地板·暗
	[10, Color(0.30, 0.24, 0.16), 0.9],   # 10 地板·中
	[11, Color(0.36, 0.29, 0.19), 0.9],   # 11 地板·亮
]


## 风化：按噪声啃掉暴露体素，破掉"刀切垂直的方盒"观感。
func _weather(strength: float) -> PcgWeather:
	return _weather_at(strength, 4.0)


## 同上，但可指定噪声尺度。
##
## 【cell 是"坑的大小"，不是"随机数种子" —— 踩过的坑】重叠式 WFC 的孔洞天生按 tile
## 周期重复（看起来是规则点阵），要打散它就得让风化坑比孔洞更细：cell=4.0 的坑比
## 孔洞大，等于在规则点阵上再盖一层大块剥落，点阵的骨架反而更明显；收到 1.2 之后
## 坑比孔洞细，才真的把点阵磨平。
func _weather_at(strength: float, cell: float) -> PcgWeather:
	var w := PcgWeather.new()
	w.strength = strength
	w.cell = cell
	w.edge_bias = 0.7
	w.protect_ground = true
	return w


## 苔藓：只染石头（材质 2），偏向朝上的表面。
## coverage 压到 0.15（见 pcg_ruins_demo._make_moss 的说明）：苔藓是点缀，
## 开大了会连成绿漆盖住石头本身的分档层次。
func _moss(source_id: int) -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_id = 4
	t.only_source_material_id = source_id
	t.coverage = 0.15
	t.up_bias = 0.7
	t.cell = 4.0
	return t


## 墙面分档：剩下的墙面对应到 [6,7,8] 三档同色系深浅。
## 必须排在苔藓**之后**——苔藓先占掉朝上的表面，剩下的才做深浅分档。
## shade_cell = 2.0 是"看得出一个个体素、又不碎成电视雪花"的尺度；
## 取 1.0 会退化成逐体素随机，观感是噪点而不是石头。
func _wall_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([6, 7, 8])
	t.only_source_material_id = 2
	t.coverage = 0.9
	t.cell = 5.0
	# shade_cell 从 2.0 提到 3.0（= 0.6 世界单位）。遗迹本体 30 体素见方，
	# 2 体素的色块在 30 单位外只有 3~4 像素 —— 三档会退化成"迷彩布"，
	# 读作涂装而不是石头。3 体素是"看得出一个个体素、又不碎"的下界。
	t.shade_cell = 3.0
	t.min_exposure = 1
	return t


## 地板分档：作用于材质 1。地板是画面里最大的连续面，不分档时最显平涂。
func _floor_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([9, 10, 11])
	t.only_source_material_id = 1
	t.coverage = 0.9
	t.cell = 5.0
	t.shade_cell = 3.0
	t.min_exposure = 1
	t.protect_ground = false
	return t


## 有机岩壁分档：苔藓占掉一部分后，把剩余岩面拆成 [3,4,5] 三档。
func _overlap_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([3, 4, 5])
	t.only_source_material_id = 1
	t.coverage = 0.85
	t.cell = 5.0
	t.shade_cell = 3.0
	t.min_exposure = 1
	return t


## 树干分档：材质 1 → [3,4] 两档（树干本来就细，两档够了，三档会读成斑点狗）。
func _trunk_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([3, 4])
	t.only_source_material_id = 1
	t.coverage = 0.8
	t.cell = 3.0
	t.shade_cell = 1.5
	t.min_exposure = 1
	return t


## 树叶分档：材质 2 → [5,6,7] 三档深浅。树冠是树的主要视觉体量，
## 单色时整棵像塑料玩具；三档后光从哪个方向来都有明暗层次。
func _leaf_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([5, 6, 7])
	t.only_source_material_id = 2
	t.coverage = 0.9
	t.cell = 3.0
	t.shade_cell = 2.0
	t.min_exposure = 1
	return t

## 两座遗迹 + 一面有机岩壁。
func _build_ruins_and_wall() -> void:
	# 节点原点在模型的**最小角**（不是中心），故相邻两座的起点要差一个整边长。
	var span := _ruin_span()
	for i in 2:
		var wfc := PcgWfc.new()
		wfc.tiles = _make_ruin_tiles()
		# 同参数不同 seed → 两座遗迹形态不同，但各自仍是确定的（同 seed 恒同结果）。
		wfc.seed = 20261007 + i * 977
		wfc.max_retries = 40
		var gen := PcgModelGenerator.new()
		gen.model = wfc
		# 细节层：先风化出缺角与凹坑，再给朝上的石头挂苔藓，最后把剩下的墙面/地板
		# 拆成同色系三档（本项目不用贴图，层次靠"更多不同颜色的体素"）。
		# 顺序有意义——暴露判定在风化之后算，新挖出的凹坑侧面也会被判为暴露面而正常上色。
		gen.details = [_weather(0.15), _moss(2), _wall_shade(), _floor_shade()]
		gen.detail_seed = 20261007 + i * 977
		# 两座并排、居中：x 从 -span 到 0，合计正好铺满 2×span。
		# 落脚高度按占地四角里最低的那个点定（见 _ground_y_under_rect），
		# 不能写死台地高度 —— 风化在顶面啃出的浅坑会让写死的值悬空。
		var x := -span + i * span
		var pos := Vector3(x, _ground_y_under_rect(Vector2(x + span * 0.5, -5.6 + span * 0.5), span * 0.5, span * 0.5), -5.6)
		_register(PcgSceneKit.add_model(self, "Ruin_%d" % (i + 1), pos, gen, RUIN_GRID,
				PcgSceneKit.materials(RUIN_MATERIALS)))

	# 有机岩壁：规则不手写，从一块 8³ 样例里"数"出可重叠的 3³ 图案，再拼成一片同类岩体。
	var sample_size := Vector3i(8, 8, 8)
	var overlap := PcgWfcOverlap.new()
	overlap.sample = PcgSceneKit.overlap_sample(sample_size)
	overlap.sample_size = sample_size
	overlap.pattern_size = 3
	overlap.seed = 20261007
	overlap.max_retries = 8
	var ov_gen := PcgModelGenerator.new()
	ov_gen.model = overlap
	# 多孔岩吃很重的风化 + 一层苔藓染色。
	#
	# 【strength 必须顶到 0.7 才有效—— 踩过三次坑】重叠式 WFC 的孔洞是**全局周期**的
	# （见 PcgSceneKit.overlap_sample 的说明：样例改成噪声后无解，所以点阵打不散，
	# 只能在样例之后处理）。第一反应是加风化，可 0.12 → 0.24 → 0.4 全部无效，
	# 截图上的等距黑点一点没少。原因是 PcgWeather 的阈值公式：
	#   threshold = strength * (0.35 + 0.65 * bias)
	#   bias = edge_bias * (exposure - min_exposure) / (6 - min_exposure)
	# 岩床是个**平整的顶面**，顶面体素的 exposure 恒为 1 → bias = 0 → 阈值只有
	# strength 的 0.35 倍：0.4 实测只蚀掉 14%（顶面实体 316 → 310，点阵纹丝不动）。
	# 顶到 0.7 之后平面的阈值是 0.245、棱角处可达 0.5，顶面才真的被打成碎砾
	# （实测顶面实体 210，噪声主导、看不出周期了）。注意这**超过了 PcgWeather 类注释
	# 建议的 0.15~0.35**，但那条建议是针对"体素少、还要保结构的模型"（树、栅栏）；
	# 这里是一块实心大石台，层厚 7 层、经得起啃，唯一的代价就是苔藓覆盖率要跟着调。
	var moss := PcgSurfaceTint.new()
	moss.material_id = 2
	moss.only_source_material_id = 1
	# 苔藓从 0.3 提到 0.38：风化减轻之后（见下），顶面需要靠苔色来分区，
	# 否则整片会退回"均匀的灰石"。
	moss.coverage = 0.38
	moss.up_bias = 0.8
	moss.cell = 3.5
	# 【风化从 0.7 收到 0.45】0.7 是为了压掉样例的周期点阵（见上方长注释），代价是
	# 把 7 层厚的岩床啃成一地孤立小方块 —— 远看是"碎砾"，**近景里是一片乱牙**
	#（实测：顶面出现大量单格高的尖刺，读作砂砾堆而不是岩床）。
	# 收到 0.45 并把 cell 从 1.2 放到 1.6 之后，坑变成成片的浅凹，
	# 周期性靠"更大的苔斑 + 三档色阶"来打散，而不是靠把表面啃碎。
	ov_gen.details = [_weather_at(0.45, 1.6), moss, _overlap_shade()]
	ov_gen.detail_seed = 4242
	# 有机岩壁摆在遗迹群的前一排（z = 2.4 起）。两排用**z** 让开而不是 x：
	# 前排遗迹 z∈[-5.6, 0.4]，后排岩壁/塔 z 从 2.4 起 —— 中间 2 单位的空档既是
	# 免穿插的余量，也让台面留出一条能走人的通路。摆放不开两个渲染器会互相穿插，
	# 而穿插的结果是"看到的并集"，看不出哪里出了问题。
	# 落脚高度按占地四角里最低的点算，且 x/z 各自的半边长要分开取 —— 扁长条的
	# 两个方向不一样宽，用同一个半宽会让"四角"落到矩形之外，取到的地面是错的。
	var half_x := OVERLAP_GRID.x * voxel_scale * 0.5
	var half_z := OVERLAP_GRID.z * voxel_scale * 0.5
	_register(PcgSceneKit.add_model(self, "Organic_Wall",
			Vector3(4.0, _ground_y_under_rect(
					Vector2(4.0 + half_x, 2.4 + half_z), half_x, half_z), 2.4),
			ov_gen, OVERLAP_GRID,
			PcgSceneKit.materials([
				[1, Color(0.33, 0.31, 0.29), 0.95],
				[2, Color(0.28, 0.36, 0.25), 0.8],
				# 3~5 岩体三档（基色 0.33/0.31/0.29 的 暗/中/亮），由 _overlap_shade 写入
				[3, Color(0.26, 0.25, 0.23), 0.95],
				[4, Color(0.33, 0.31, 0.29), 0.95],
				[5, Color(0.40, 0.38, 0.35), 0.95],
			])))


# ----------------------------------------------------------------------------
# 可破坏塔：唯一的 VoxelDestructible，其余组装代码一字未改
# ----------------------------------------------------------------------------

func _build_tower() -> void:
	var wfc := PcgWfc.new()
	wfc.tiles = _make_ruin_tiles()
	wfc.seed = 424242
	wfc.max_retries = 40
	var gen := PcgModelGenerator.new()
	gen.model = wfc
	gen.details = [_weather(0.15), _moss(2), _wall_shade(), _floor_shade()]
	gen.detail_seed = 424242

	# destructible = true 是这里与其余场景模型的**唯一**区别。
	# 位置：前排左侧，与有机岩壁（x 起 4.0）留 2.0 单位间隙，且整座落在台地内
	# （x∈[-4.0, 2.0]、z∈[2.4, 8.4]，台地是 x,z∈[-10, 10]）。z 最靠前 = 离相机最近，
	# 破坏演示才不会被前面的模型挡住。
	var tower_span := _ruin_span()
	_register(PcgSceneKit.add_model(self, "Tower_Destructible",
			Vector3(-4.0, _ground_y_under_rect(Vector2(-4.0 + tower_span * 0.5, 2.4 + tower_span * 0.5),
					tower_span * 0.5, tower_span * 0.5), 2.4),
			gen, RUIN_GRID, PcgSceneKit.materials(RUIN_MATERIALS), true))
	_tower = _models.back() as VoxelDestructible
	# 伤害必须**单次**越过材质硬度才能立刻出洞：材质 hardness = 5.0（见 PcgSceneKit），
	# 而 PcgSceneKit 给破坏容器配的 damage_per_voxel = 1.0 是"按住连打"式的（destruction_demo
	# 就是按住不放靠多帧累伤）。本场景是"点一下出一个洞"，故把单次伤害提到硬度之上。
	_tower.damage_per_voxel = 8.0
	_tower_snapshot = _tower.data.save_data()


# ----------------------------------------------------------------------------
# 植被：L-系统（PcgLsystem）
# ----------------------------------------------------------------------------

## 成林。位置来自 `PcgScatter`（最小间距 + 密度衰减 + 随机 yaw/缩放），
## 形态差异来自 L-系统自己的 `seed` + `variation`。
##
## 【与 pcg_forest_demo 的分工】那边是"单技法深挖"：三种文法/参数/种子三个变量分开对照，
## 位置刻意等距以免干扰观察。这里是"综合场景"，只关心成片景观的自然度，
## 故位置全交给散布器。核心已下沉进框架（`PcgScatter` + `PcgLsystem.seed`），
## 场景侧不再需要为每棵树手写一份参数表。
##
## 【"哪能种树"也交给散布器】center/radius 画的是一片比台地大的圆（14 > 10），
## 圆外与火山口里的候选点由 `_plateau_ground_query` 返回 null 拒收，
## 于是不用在场景里反推"遗迹占哪、台地到哪"——那些数字都在 PcgSceneKit 的
## 摆放处与 SDF 的定义处，改一处就够，散布器自动跟随。
func _build_forest() -> void:
	var scatter := PcgScatter.new()
	# 【散布区域 = 整个台地，把"能不能种"交给地面查询】
	# 原来是一个半径 7 的圆心在遗迹群上的圆，可那块地被遗迹 + 岩壁 + 塔 + 火山口
	# 占满，实测只能长出 2 棵树。改成"半径基本覆盖台地 + 查询逐点拒收"之后，
	# 树会自动落到西侧那条 3.5 宽的空带、南侧台缘等所有**真正空着**的地方，
	# 不需要手写"哪块地能种"的表，也不会出现"圆圈外明明有地却没树"的漏区。
	scatter.center = Vector2(-1.0, 0.0)
	scatter.radius = _plateau_half_span() - 1.0
	scatter.count = 14
	# 间距 3.8：树冠实测 4.0~4.4 宽（20~22 体素 × 0.2）。**略小于树冠宽度是有意的** ——
	# 林冠本来就该互相搭接，等距散开的树反而像苗圃。
	# 散布器是"每格取一点、格边长 = spacing"的网格采样，间距同时决定上限与密度：
	# 半径 9 内 3.8 的间距约 5×5 = 25 格、圆内约 16 格，再被遗迹/岩壁/塔的占位拒收，
	# 实测能落 6~8 棵。被拒收的点不计入 count，散布器会继续找空地直到走遍网格。
	scatter.spacing = 3.8
	scatter.spacing_jitter = 0.35
	scatter.density = 0.95
	scatter.density_scale = 13.0
	scatter.seed = 20261007
	# 体积差拉大：0.85~1.1 的等比树群看上去是"同一棵复制了 N 遍"。
	# 上限压到 0.95：树满尺寸时冠幅（4.4 单位）会盖住 6 单位宽的遗迹，
	# 而这一场景的主体是遗迹，树是配景 —— 配景不该比主体还抢眼。
	scatter.scale_min = 0.62
	scatter.scale_max = 0.95
	# 地面查询顺带给出台地高度，落点 y 不必在下面再算一遍。
	scatter.ground_query = _plateau_ground_query
	var placements := scatter.generate()
	# 两套规则交替，兼看两种树形；同一套内的差异只来自 seed。
	#
	# 【文法里 `&`/`^` 前面必须先有 `+`/`-`】原来的 "F=FF[+F][-F][&F][^F]" 看着 3D，
	# 实测长出来的是一张**平面扇叶**：起始朝向是竖直的，此时 `+`/`-` 绕竖直轴转等于
	# 没转，第一层分枝全部落在同一个竖直平面内（实测包围盒 16×26×3，z 只占 3 体素）。
	# 写成 `[+&F]`（先绕竖直轴掰开平面、再离轴俯仰）之后四个分枝才真的散向四方
	#（包围盒 16×26×14）。
	var rules := ["F=FF[+&F][-&F][^+F][^-F]", "F=FF[&F][-F][^+F][^-F]"]
	for i in placements.size():
		var pl: PcgScatter.Placement = placements[i]
		# 散布器给的 basis 已含随机 yaw 与随机缩放：旋转取欧拉 Y，
		# 缩放要单独取出（作用在 voxel_scale 上，而不是缩放整个节点——
		# 节点被缩放会把 32×48×32 网格的体素一起放大，而体素生成是按体素算的）。
		var basis := pl.xform.basis
		var yaw := basis.get_euler().y
		var scale_mul := basis.get_scale().x
		var tree := PcgLsystem.new()
		# 【从 axiom="F" 改成两段式 axiom="A"】原来直接从 F 起步，第一步就是分枝，
		# 长出来是"灌木"：叶子从地面开始裹，没有一根裸露主干。
		# 改造见 PcgLsystem.two_stage（原文法的分枝结构一字未改）。
		tree.axiom = "A"
		tree.rules = PcgLsystem.two_stage(rules[i % rules.size()])
		# 【树体一轮从 11 体素提到 26 体素】原来 it=3 / step=1.7 / tip=1.7 长出来的树
		# 只有 6×11×6 体素、约 100 个实心体素 —— 那等于**一块遗迹砖**的体量
		#（RUIN_TILE = 6 体素），摆在 6 单位宽的遗迹旁边像杂草。
		# 更关键的是：11 体素高的小模型里任何细节层都无处安放 ——
		# 分档色块边长只能给 2 体素，整棵树只有约 9 个色块，读作"涂色块"而不是明暗。
		# 现在 26 体素高、3300+ 实心体素，色阶、剪影、枝干结构才能同时成立。
		# 参数取自 pcg_forest_demo 的扫参实测（it=5 / step=2.5 在 32×48×32 网格内
		# 包围盒 20~22 × 26 × 24，seed 1000/1002/2000 三档稳定、不越界）。
		tree.iterations = 5
		tree.step = 2.5
		tree.thickness = 0.9
		tree.angle_degrees = 22.0
		# 枝干渐细：恒定粗细的树像一串等粗的棍子
		tree.taper = 0.5
		tree.material_id = 1
		# 末梢叶团换成材质 2 —— 树干褐 / 叶片绿由此成立
		tree.tip_material_id = 2
		# 只在真正的枝端盖叶团：默认档会让每个 F 都算末梢（展开后所有符号深度相同），
		# 绿团把主干从头裹到脚。见 PcgLsystem._branch_terminals 的实测数据。
		tree.tip_scope = PcgLsystem.TipScope.BRANCH_END
		tree.tip_radius = 2.4
		# 形态抖动全部来自这一个种子。
		#
		# 【variation 必须压住】它不只是"抖一抖"：variation 会给**起始朝向**加一个
		# 绕竖直轴的大角度随机偏航（幅度 = π × variation），而此时生长方向恰好竖直，
		# 于是整棵树被随机**倾斜**，最坏 63°（0.35 时实测包围盒整体偏向一侧、
		# 树冠被网格边界削掉一片）。0.15 → 最大 9.5°，树是"歪着长"而不是"倒着长"。
		tree.seed = pl.variant_seed
		tree.variation = 0.4
		var gen := PcgModelGenerator.new()
		gen.model = tree
		var weather := PcgWeather.new()
		# 树体大了 30 倍，风化跟着加重：原来的 0.1 是"别让 100 体素的小树散架"，
		# 3300 体素的树经得起啃，而叶团表面那些锯齿缺口正是体素植物的质感来源。
		weather.strength = 0.16
		weather.cell = 2.5
		weather.min_exposure = 2   # 只蚀细枝末端，保住主干的完整感
		gen.details = [weather, _leaf_shade(), _trunk_shade()]
		# 落点必须落在**树干**上，而不是节点原点。PcgLsystem 从网格中心 (x/2, 1, z/2)
		# 生长，而 add_model 把节点原点钉在网格最小角 —— 于是树干比落点偏了半个网格
		# （16 体素 × 0.2 = 3.2 单位）。这正是原来"半径 14 的圆里有一半树悬空在岛外"
		# 的根因：偏移不是靠缩小树体能消掉的常量，而是固定等于半个网格。
		# 节点自身还要绕 Y 转 yaw，所以偏移要一起转到世界空间再减掉。
		var trunk_offset := Vector3(TREE_GRID.x * 0.5, 0.0, TREE_GRID.z * 0.5) * (voxel_scale * scale_mul)
		var pos := pl.xform.origin - Basis(Vector3.UP, yaw) * trunk_offset
		var node := PcgSceneKit.add_model(self, "Tree_%d" % (i + 1), pos, gen, TREE_GRID,
				PcgSceneKit.materials([
					[1, Color(0.30, 0.22, 0.14), 0.95],   # 树干
					[2, Color(0.22, 0.38, 0.16), 0.85],   # 叶片
					# 树干/树叶的同色系梯度，由 _trunk_shade / _leaf_shade 逐体素写入。
					# 走 PcgSceneKit.graded：暗档偏冷、亮档偏暖 —— 纯明度缩放的"三档"
					# 在体素栅格上读作同一块塑料的不同曝光，掰开色相才读作明暗。
					[3, PcgSceneKit.graded(Color(0.30, 0.22, 0.14), 0.60), 0.95],  # 树干·暗
					[4, PcgSceneKit.graded(Color(0.30, 0.22, 0.14), 1.30), 0.95],  # 树干·亮
					[5, PcgSceneKit.graded(Color(0.22, 0.38, 0.16), 0.58), 0.9],   # 叶·暗
					[6, Color(0.22, 0.38, 0.16), 0.85],                            # 叶·中
					[7, PcgSceneKit.graded(Color(0.22, 0.38, 0.16), 1.32), 0.85],  # 叶·亮
				]), false, voxel_scale * scale_mul)
		_register(node)
		node.rotation.y = yaw


# ----------------------------------------------------------------------------
# 场景装配
# ----------------------------------------------------------------------------

func _register(node: Node3D) -> void:
	# 统一相机半径：让每个模型都落在 view_distance 内（详见文件头）。
	(node as VoxelRenderer).view_distance = view_distance
	_models.append(node)


## 地面碰撞体：只给碎片一个落点，**不放可见网格**。
##
## 【为什么没有地面 mesh】原来这里挂了一块 120×120 的可见板子，结果有两个问题：
## 一是它在画面里占了近半屏、把岛挤成一小块；二是它材质一旦没挂上（BoxMesh 自带
## albedo=纯白 的默认材质），就是一块刺眼的白板。岛本身就是地面，不需要人工底板。
## 碎片是纯粒子，真要落地物理再往 StaticBody3D 上加碰撞形状即可。
func _setup_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	var shape := BoxShape3D.new()
	shape.size = Vector3(120.0, 1.0, 120.0)
	var oid := body.create_shape_owner(body)
	body.shape_owner_add_shape(oid, shape)
	body.position = Vector3(0.0, -0.6, 0.0)
	add_child(body)


## 光照/色调：配方唯一真源是 res://demo/pcg_environment.tres，这里只负责挂载。
##
## 【为什么不再是 Environment.new() 全硬编码】本文件一度把 sky / ambient / tonemap /
## fog / ssao / light_energy 全写在这里，6 个 PCG 场景各抄一份，改一处要改 6 处；
## 而 .tscn 的 Environment 子资源在 MCP 启动链路上**不参与重载**（编辑器进程持缓存版，
## 运行时 load() 出来的还是 ambient_light_source=0 / tonemap_mode=0 / fog_density=0.01
## 这些默认值），写了等于没写。于是"配置放资源、挂载放脚本"是唯一两头都生效的组合：
## .tres 在磁盘上、.gd 改动会被重载。
##
## 【各参数为什么是这个值】全部记在 pcg_environment.tres 的头部注释里
## （SKY 源 vs COLOR 源、ACES vs Filmic、雾为什么是减法项……），
## 连同 light_energy 的实测标定一起放在 PcgSceneKit.LIGHT_ENERGY。
## 改光照请改那两处，本函数保持一行。
func _setup_environment() -> void:
	PcgSceneKit.apply_environment(self)


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 55.0
	_camera.far = 400.0
	# 【机位从"高俯视"改成"贴台面平视"】原来是 (13, 22, 24)、俯角 34°：
	# 台面在画面里被压成一条窄带，占比最大的反而是台面**正中那片什么都没有的灰平面** ——
	# 实测 77% 的像素落在同一个颜色桶里，"空"比"模型差"更致命。
	# 台面顶在 y=6.8（PLATEAU_VOXEL_Y × voxel_scale），遗迹高 4.8、树高 5.2，
	# 故机位抬到 y≈12（≈ 遗迹顶）俯角约 20°：看得见台面与布局，
	# 但主体（遗迹群 + 树 + 岩壁）撑满画面上部，台面只留作地面。
	# 偏 x 是为了避开正对称，正对着看会把两座遗迹看成一座对称的怪东西。
	_camera.global_position = Vector3(12.0, 12.5, 18.0)
	_camera.look_at(Vector3(-0.5, 7.2, -1.5), Vector3.UP)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)

	_hint = Label.new()
	_hint.position = Vector2(10, 128)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.45, 0.9, 1.0))
	_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_hint.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hint)

	_hint.text = """[左键] 对着石塔打球形洞   [R] 重建石塔
【关键证据】那座可破坏塔与场景里其余模型的组装代码完全一致，
唯一区别是容器类 VoxelRenderer → VoxelDestructible。
产出即享全链路：编辑 / 破坏 / 物理 / LOD 无需任何 PCG 专属分支。"""


# ----------------------------------------------------------------------------
# 交互：破坏（复刻 destruction_demo 的手法）
# ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var key_r := Input.is_key_pressed(KEY_R)

	if left and not _prev_left:
		_damage_at_mouse()
	if key_r and not _prev_r:
		_rebuild_tower()

	_prev_left = left
	_prev_r = key_r
	_update_hud()


func _damage_at_mouse() -> void:
	if _tower == null or _camera == null:
		return
	var hit := _mouse_to_voxel()
	if hit == Vector3i.MIN:
		return
	_tower.damage_sphere(Vector3(hit) + Vector3(0.5, 0.5, 0.5), damage_radius)


## 屏幕射线 → 塔的局部体素坐标。VoxelDestructible 的 raycast 收的是
## "局部体素空间"的射线，故要把世界射线换算到局部再除以 voxel_scale。
func _mouse_to_voxel() -> Vector3i:
	var from := _camera.project_ray_origin(get_viewport().get_mouse_position())
	var dir := _camera.project_ray_normal(get_viewport().get_mouse_position())
	var local_origin := _tower.to_local(from)
	var local_dir := _tower.global_transform.basis.inverse() * dir
	return _tower.raycast_voxel(local_origin / voxel_scale, local_dir, 1000.0)


func _rebuild_tower() -> void:
	if _tower == null:
		return
	_tower.clear_damage()
	_tower.data.load_data(_tower_snapshot)
	print("[PCG综合场景] 石塔已重建")


# ----------------------------------------------------------------------------
# HUD：已建 chunk / 期望 chunk —— 这是"数据真的按 grid_size 全建出来了"的判据
# ----------------------------------------------------------------------------

func _expected_chunks() -> int:
	var n := 0
	for node in _models:
		var gs: Vector3i = (node as VoxelRenderer).data.grid_size
		var span := Vector3i(
			(gs.x + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.y + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.z + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE)
		n += span.x * span.y * span.z
	return n


func _built_chunks() -> int:
	var n := 0
	for node in _models:
		var data: VoxelData = (node as VoxelRenderer).data
		var gs: Vector3i = data.grid_size
		var span := Vector3i(
			(gs.x + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.y + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.z + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE)
		for cz in span.z:
			for cy in span.y:
				for cx in span.x:
					if data.is_chunk_loaded(Vector3i(cx, cy, cz)):
						n += 1
	return n


func _update_hud() -> void:
	if _hud == null:
		return
	var damage := 0
	if _tower != null:
		damage = int(_tower.last_damage_count)
	_hud.text = """===== PCG 综合场景 =====
FPS: %d    模型: %d    已建 chunk: %d / %d
可破坏塔: 最近一次破坏移除 %d 体素
相机 (%.0f, %.0f, %.0f)   view_distance %.0f
""" % [
		Engine.get_frames_per_second(), _models.size(), _built_chunks(), _expected_chunks(),
		damage, _camera.global_position.x, _camera.global_position.y, _camera.global_position.z,
		view_distance,
	]