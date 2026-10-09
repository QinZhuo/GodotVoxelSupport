class_name PcgSceneKit
extends RefCounted

## PCG 场景共享组装工具（静态类，只做"把模型装成节点"这一件事）。
##
## 【为什么需要它】既有两个 demo（pcg_models_demo / pcg_operators_demo）各自抄了一份
## 同构的 `_add_model` / `_material` / `_wfc_tile` / `_overlap_sample`。再加 5 个场景
## 就是 5 份拷贝，改一处要改 7 处。这里给出唯一一份实现，场景脚本只描述"造什么"。
##
## 【为什么不重构既有两个 demo】它们已验证可用，且组织方式与各自讲的主题耦合，
## 动它们只有风险没有收益。新场景一律走本工具。
##
## 【一个程序化模型 = 什么】有界 QVoxelSource（grid_size 即生成范围）
## + 一个 QVoxelModel（链上挂着产出算子）
## + 一个 VoxelRenderer / VoxelDestructible 节点。
## 因为产出就是一个普通节点，"编辑 / 破坏 / 物理 / 碰撞 / LOD"全部自动可用——
## 换可破坏版本只是 `VoxelDestructible.new()` 替掉 `VoxelRenderer.new()`，其余一字不改。

## 一个模型的默认世界尺度（32³ 体素 → 6.4 世界单位）。
## 1 chunk = 32 体素 = 6.4 世界单位，故 128 宽的基底 = 25.6 世界单位。
const DEFAULT_VOXEL_SCALE := 0.2


## 由紧凑描述批量造材质。
##
## 每项为 `[id, color, rough]`，可选第 4 项 `trans`（透明度，0 = 不透明）。
## 物理参数用一套与既有 demo 一致的常量：硬、韧、中等质量——够"能打能崩"演示用。
static func materials(specs: Array) -> Array:
	var out: Array = []
	for spec in specs:
		var m := VoxelMaterial.new()
		m.id = int(spec[0])
		m.color = spec[1] as Color
		m.rough = float(spec[2])
		if spec.size() > 3:
			m.trans = float(spec[3])
		m.hardness = 5.0
		m.connection_strength = 20.0
		m.mass = 2.0
		out.append(m)
	return out


## 由基色派生"暗档 / 亮档"：明度按 f 缩放，同时把色相往冷（f<1）或暖（f>1）掰。
##
## 【为什么必须掰色相，不能只乘亮度】纯明度缩放让三档颜色在 RGB 空间里共线，
## 体素栅格上读起来像"同一块材质的不同曝光"（发灰、发脏）；
## 把暗档的蓝通道抬起来、亮档的红通道抬起来之后，三档在色相环上张开，
## 才读作"背光的草 / 受光的草"。这是本项目"不加贴图、靠更多体素颜色做层次"的核心手段，
## 凡是"同色系三档"的调色板都该走这里，别在每个 demo 里各写一遍（容易漂移）。
##
## 系数是实测调出来的：再大就会让暗档发蓝、亮档发黄，脱离原色系。
static func graded(c: Color, f: float) -> Color:
	var cool := 1.0 - clampf(f, 0.0, 1.0)
	var warm := clampf(f - 1.0, 0.0, 1.0)
	var r := c.r * f + warm * 0.06
	var g := c.g * f * (1.0 + cool * 0.04)
	var b := c.b * f + cool * 0.05
	return Color(clampf(r, 0.0, 1.0), clampf(g, 0.0, 1.0), clampf(b, 0.0, 1.0))


## 共享环境资源的路径（唯一真源）。
##
## 【为什么必须是独立资源而不是 .tscn 子资源 / 代码】
##   1. 放 .tscn 子资源：编辑器进程持有场景的内存副本，MCP 启动游戏用的是缓存版，
##      .tscn 改动不重载 → 改多少遍都不生效（pcg_world_demo 早年就踩过，导致参数一度
##      全搬进代码）。.gd 改动才会被重载。
##   2. 放代码 `Environment.new()`：6 个场景各抄一份，改一处要改 6 处。
##   于是"配置在资源、挂载在脚本"是唯一两头都生效的组合 —— 也就是本函数。
##
## 【.tres / .tscn 里不能写 # 注释】文本资源解析器把 `#` 当值读（报 "Invalid color
## code"），所以参数背后的实测依据只能写在这里。
##
## 【各参数为什么是这个值（均来自 pcg_world_demo 实测标定）】
##   ambient_light_source = SKY(3)：写成 COLOR(2) 时 ambient_light_color 默认纯黑，
##     环境光恒等于 0（实测：关掉方向光，台面像素掉到 0.0）→ 背光面死黑，
##     侧壁缺口、底部圆角全看不见。SKY 源 = 70% 天空辐照 + 30% 下面那个灰蓝，
##     暗部能读出形状（0.12 左右），又不把台面拉平。
##   tonemap_mode = ACES(3)：Filmic(2) 低亮度区斜率远小于 1，会把
##     "albedo 0.33 + 主光 2.0" 这种本该正常的中间调压到 0.20，画面发闷发灰；
##     ACES 中间调接近线性，同样光照能到 0.42，岩石才像岩石。
##   fog_density = 0.0006：雾在这里是减法项不是氛围。0.004（其余 demo 的旧值，
##     pcg_models/operators 更是 fog_enabled 而没设密度 → 吃引擎默认 0.01，浓 16 倍）
##     在 30 单位视距上叠 5% 白，把远处遗迹和天空糊成一片灰、吃掉反差。
##   ssao_*：体素模型全是硬边直角，SSAO 是体素缝隙之外唯一能读出凹凸的手段。
##   ambient_light_energy = 2.0：**实测标定过，这个旋钮几乎是哑的**，
##     1.0 → 2.2 只让整图平均亮度从 0.317 变到 0.328（受影响像素 28%、单点最大差 0.064）。
##     原因：背光面本来就主要由天空自身的低辐照度决定，环境光乘数改的是那一项的系数，
##     而它绝对值很小。要提亮暗部请改 sky 颜色或加补光，不要指望这个数。
const ENVIRONMENT_PATH := "res://demo/pcg_environment.tres"

## 主光强度的实测标定值。
## albedo 0.33 的岩石在 3.6 时台面像素 0.47 —— 截图里是一块过曝白板，
## 看不到材质分区；2.0 落在 0.35 上下，体素颗粒与色阶档位才读得出来。
const LIGHT_ENERGY := 2.0
const LIGHT_ANGULAR_DISTANCE := 0.8

## 主光**方向**（光行进的方向，即它照向哪儿）。
##
## 【为什么必须由脚本定死，而不是沿用 .tscn 里那个变换】6 个 PCG demo 的 .tscn
## 用的都是同一个 DirectionalLight3D 变换（`basis.z = (-0.75, 0.5, 0.433)`），
## 光从 +x / +y / **−z** 打过来。而所有 demo 的相机都摆在 **+x/+z** 侧
## （world 在 (12,12.5,18)、forest 在 (6.5,5.6,15)、ruins/porous 在 (0,…,32)）——
## 于是"相机看得见的那两个面"里，**朝向 +z 的正面永远是背光的**。
## 实测（world 场景，原始色空间截图）：岛体 +z 侧壁的像素落在 0.03~0.08，
## 也就是近黑；刚做上去的岩层色阶与苔藓全被吃掉，一整面白做。
##
## 【取值】仰角 42°、方位在相机右后方 45° 左右：光照到 +x 与 +z 两个可见面（各约 0.5），
## 同时保住顶面（0.67）与足够的投影长度。仰角低于 30° 投影会拉得过长、
## 高于 55° 又变成"顶视图打光"，立面全部平掉。
const LIGHT_DIRECTION := Vector3(-0.52, -0.67, -0.53)


## 把共享光照/色调配方挂到场景上（各 PCG demo 的 _ready 里调用）。
##
## 【为什么必须在脚本里挂】.tscn 的改动不参与 MCP 启动链路的重载
## （编辑器持缓存版），写进场景文件等于没写；.gd 改动会被重载，
## 于是"配置在资源、挂载在脚本"是唯一两头都生效的组合。
## 场景里已有的 WorldEnvironment / DirectionalLight3D 会直接复用；
## 缺节点时才补建（保持各 demo 的 .tscn 结构不被强制改动）。
static func apply_environment(root: Node3D) -> void:
	var env := load(ENVIRONMENT_PATH) as Environment
	if env == null:
		push_warning("[PcgSceneKit] 共享环境资源缺失: %s" % ENVIRONMENT_PATH)
		return

	var we := root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null:
		we = WorldEnvironment.new()
		we.name = "WorldEnvironment"
		root.add_child(we)
	we.environment = env

	var light := root.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if light != null:
		light.light_energy = LIGHT_ENERGY
		light.light_angular_distance = LIGHT_ANGULAR_DISTANCE
		light.shadow_enabled = true
		# 朝向按 LIGHT_DIRECTION 钉死（DirectionalLight3D 沿自身 −Z 照射，
		# 故把 −Z 指向"光行进的方向"即可）。见该常量的说明。
		light.look_at(light.global_position + LIGHT_DIRECTION.normalized(), Vector3.UP)


## 组装一个模型并挂到 parent 上，返回该节点（供场景持有引用 / 做破坏目标 / 统计）。
##
## model_node 直接传入（一个 QVoxelModel —— 用 QVoxelModel.of_source 造，或一个组 / 世界），
## 因为"链上挂了什么"恰是各场景要展示的内容之一，不该被本工具藏掉。
## seed 是全链共用的主种子（→ QVoxelSource.seed）；细节算子的种子在 of_source 里定。
## destructible = true 时用 VoxelDestructible 替掉 VoxelRenderer（见 destruction_demo 的接线）。
static func add_model(parent: Node3D, model_name: String, pos: Vector3,
		model_node: QVoxelNode, grid_size: Vector3i, mats: Array, destructible := false,
		voxel_scale := DEFAULT_VOXEL_SCALE, seed := 0) -> Node3D:
	var data := QVoxelSource.new()
	for m in mats:
		data.add_material(m)
	data.node = model_node
	data.grid_size = grid_size
	data.seed = seed

	var node: Node3D
	if destructible:
		var d := VoxelDestructible.new()
		# 与 destruction_demo 同一套破坏参数：碎片粒子 + 局部增量崩塌。
		d.lod_count = 3
		d.spawn_debris_on_damage = true
		d.use_voxel_health = true
		d.damage_per_voxel = 1.0
		d.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
		d.local_collapse = true
		node = d
	else:
		node = VoxelRenderer.new()

	node.name = model_name
	node.data = data
	node.voxel_scale = voxel_scale
	# 有界模型：FULL 让"grid_size 覆盖到的 chunk 全建出来"，无需相机驱动流式加载。
	# 大 grid_size（如 128 宽基底）配合大 view_distance 会在首帧做立方枚举，故
	# 场景必须让 view_distance 覆盖模型的实际范围而不是一味放大。
	node.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	parent.add_child(node)
	node.global_position = pos
	return node


## 构造一块 WFC 图块：solid(x, y, z) 返回 true 的格子填 material_id。
##
## sockets 顺序与 PcgWfc 一致：+X, -X, +Y, -Y, +Z, -Z。接口名相同的面才能相邻——
## 这是 socket 式 WFC 唯一的约束来源，也是它"手动但可控"的代价。
static func wfc_tile(tile_size: Vector3i, sockets: Array, weight: float, material_id: int,
		solid: Callable) -> PcgWfcTile:
	var voxels := PackedInt32Array()
	voxels.resize(tile_size.x * tile_size.y * tile_size.z)
	for z in tile_size.z:
		for y in tile_size.y:
			for x in tile_size.x:
				if solid.call(x, y, z):
					voxels[x + y * tile_size.x + z * tile_size.x * tile_size.y] = material_id
	return PcgWfcTile.make(tile_size, voxels, PackedStringArray(sockets), weight)


## socket 式 WFC 的"遗迹"图块集：10 块、TILE=6、产出柱网 + 墙 + 楼层的多层结构。
##
## 【为什么图块集会产出噪点，而这一套不会】WFC 只按权重随机，权重接近时必然把每个
## block 填满，看上去就是随机噪点方块。要产出"建筑"，得靠图块集本身编码三条约束：
##
##   ① **X/Z 方向用 core / edge 两套接口名**。图块按 block 内坐标分"边缘列"
##      （x 或 z ∈ {0, TILE-1}）与"中心区"。core 图块标 core、edge 图块标 edge，
##      而接口名相同才能拼在一起 —— 于是"边缘只接边缘、中心只接中心"被强制保证。
##   ② **柱与墙都放在 block 内居中的 2×2**（x,z ∈ [c, c+1]，c = TILE/2-1）。
##      配合 ①，柱/墙每隔 TILE 格出现一次，**自动对齐成柱列与墙行**；否则它们会各自漂移。
##   ③ **竖向用 rock / air 两级链**。顶面标 rock 的块（基岩/柱/墙）只能叠在底面标 rock 的
##      块之上，顶面标 air 的块只能叠在顶面标 air 的块之上 —— 于是"基岩→地板→柱→墙→上层"
##      只能自下而上堆叠。
##
## 【权重决定疏密】open 占 6.0 远高于其它块，输出以空气为主 —— 这是"结构稀疏化"的
## 唯一手段，权重接近时 WFC 必然填满。
##
## 【让柱/墙读作建筑而不是积木：柱础与檐口】只有一根通高 2×2 方柱时，剪影是
## 两根并排的长条，配上满铺的实心块，整体读作"碎石堆"。给柱加**柱础**（底面 4×4）
## 和**檐口**（顶面 4×4），剪影就出现"下宽—中细—上宽"的建筑轮廓，且水平线条把
## 竖直的柱列连成有节奏的立面。这两处都只改 `solid` 闭包、不碰 socket ——
## socket 是 WFC 唯一的相容性来源，动了它这套图块集就会大面积矛盾。
##
## 【实心块只填下半】solid_core 原本整块 6³ 全填（材质 3 = 最浅的深土），
## 于是画面上浮着一个个浅灰大方块，是最主要的"积木感"来源。改成只填 y<=2，
## 它读作"台地的填充土"而不是独立方块；bedrock_core 保留整填，因为它是竖向链的
## 续接件，掏空会让柱/墙无法继续往上叠。
##
## 材质 ID：0 空 / 1 砂岩地板 / 2 石柱与墙（会被 PcgSurfaceTint 挂苔藓）/ 3 深土基岩 / 5 碎石。
static func ruin_tiles(tile_size := 6) -> Array[PcgWfcTile]:
	var tile := Vector3i(tile_size, tile_size, tile_size)
	var c := tile_size / 2 - 1      # 居中 2×2 的起始下标（TILE=6 → 占 x,z ∈ [2,3]）
	var c1 := c + 1
	# 柱础 / 檐口比柱身宽一格（TILE=6 → 占 x,z ∈ [1,4]），比 2×2 柱身外扩一圈。
	var p := c - 1
	var p1 := c + 2

	# —— 空气与土石 ——
	# open_core：中心区留白。权重最高，是"稀疏化"的主要来源。
	var open_core := wfc_tile(tile, ["core", "core", "air", "air", "core", "core"],
			7.0, 0, func(_x, _y, _z): return false)
	# open_edge：边缘列留白。与 open_core 接口名不同，二者不会混拼。
	var open_edge := wfc_tile(tile, ["edge", "edge", "air", "air", "edge", "edge"],
			2.5, 0, func(_x, _y, _z): return false)
	# solid_core：填充土。只填下半（见上方说明），避免整块大方块浮在画面里。
	var solid_core := wfc_tile(tile, ["core", "core", "air", "air", "core", "core"],
			0.5, 3, func(_x, y, _z): return y <= tile_size / 2 - 1)
	# bedrock_core：上下皆 rock —— 竖向链的"续接"件，让柱/墙可一直往上叠。
	var bedrock_core := wfc_tile(tile, ["core", "core", "rock", "rock", "core", "core"],
			0.4, 3, func(_x, _y, _z): return true)

	# —— 地板 ——
	# floor_core：底面整层实心；下方须 rock（坐在 bedrock/柱/墙上），上方留空。
	#
	# 【为什么要挖一个缺口】整层实心的 6×6 地板在近景里读作"一块完整的木板/石台"，
	# 叠几层就是"货架"。遗迹的地板本来就该是**塌了的**：在靠 +x 侧开一个 2×3 的洞，
	# 于是同一块地板既有完整边缘也有破口，视线能穿到下一层，家具感消失。
	# 洞只影响实心闭包，socket 一字未动 —— 图块相容性不受影响（socket 是名字约束，
	# 与几何接不接得上无关，所以地板在边界处断开是安全的）。
	var floor_core := wfc_tile(tile, ["core", "core", "air", "rock", "core", "core"],
			2.0, 1, func(x, y, z):
				return y == 0 and not (x >= 4 and x <= 5 and z >= 1 and z <= 3))
	# floor_edge：同上但标 edge。只出现在模型最底层的外围一圈（下方无邻居可校验）。
	var floor_edge := wfc_tile(tile, ["edge", "edge", "air", "rock", "edge", "edge"],
			1.2, 1, func(_x, y, _z): return y == 0)

	# —— 柱 / 墙（都在 block 内居中，构成柱网）——
	# pillar_core：2×2 通高柱 + 柱础(y==0 的 4×4) + 檐口(y==末层的 4×4)。
	var pillar_core := wfc_tile(tile, ["core", "core", "rock", "air", "core", "core"],
			1.6, 2, func(x, y, z):
				if y == 0 or y == tile_size - 1:
					return x >= p and x <= p1 and z >= p and z <= p1
				return x >= c and x <= c1 and z >= c and z <= c1)
	# wall_x_core：纵向墙 + 柱础/檐口，y==3 处沿 z 开一格窗洞。
	var wall_x_core := wfc_tile(tile, ["core", "core", "rock", "air", "core", "core"],
			1.0, 2, func(x, y, z):
				if y == tile_size - 1:
					return x >= p and x <= p1
				if y == 0:
					return x >= p and x <= p1 and z >= p and z <= p1
				return x >= c and x <= c1 and not (y == 3 and z == c1))
	# wall_z_core：横向墙，与 wall_x 在中心交叉。对称于 wall_x。
	var wall_z_core := wfc_tile(tile, ["core", "core", "rock", "air", "core", "core"],
			1.0, 2, func(x, y, z):
				if y == tile_size - 1:
					return z >= p and z <= p1
				if y == 0:
					return z >= p and z <= p1 and x >= p and x <= p1
				return z >= c and z <= c1 and not (y == 3 and x == c1))

	# —— 碎石 ——
	# rubble_core：底层 + 第二层几个缺角，制造坍塌感而非整齐方盒。
	var rubble_core := wfc_tile(tile, ["core", "core", "air", "rock", "core", "core"],
			1.6, 5, func(x, y, z):
				if y == 0:
					return true
				if y == 1:
					return (x == 0 and z == 0) or (x == 1 and z == 0) or (x == 0 and z == 1) or (x == 5 and z == 5)
				return false)

	return [open_core, open_edge, solid_core, bedrock_core, floor_core, floor_edge,
			pillar_core, wall_x_core, wall_z_core, rubble_core]


## 重叠式 WFC 的样例：一块多孔岩 —— 实心岩石里挖出孔洞，部分孔洞填另一种材质。
##
## 【样例怎么挑：重叠式能不能求出解，全看样例的图案有没有重复】
##   ① 不能是"地板 + 一圈墙"这类**稀疏骨架**：8³ 里大部分为空的样例学出的图案
##      绝大多数是纯空气，且纯空气自相容，WFC 会整体坍缩进"整块全空"的退化解。
##   ② 也不能是**白噪声**：每个 N³ 窗口都唯一，相容图近乎一条无环长链，
##      铺到网格边缘必然死路，重试多少次都矛盾（实测）。
##   ③ 要的是**致密 + 图案重复**：孔洞用两族周期互质（5 与 6）的斜切取并集，
##      于是 8³ 样例内每族各自重复数轮，学出的图案既能拼、又有多样性。
## 单族斜切是平行平面，输出会露出明显的"格栅"；两族相交后才成团状的天然孔隙。
##
## 【这里必须是周期性的，别再改成噪声 —— 踩过两次坑】样例里的 `%5` 是**全局周期**，
## 重叠式 WFC 学到的每个 3³ 图案都继承同一张周期表，于是输出岩体上的孔洞也落回
## 那一张规则点阵（俯视是等距黑点，像 polka dot 贴图）。很自然会想到"换成噪声"：
## FastNoiseLite 的 SIMPLEX 孔洞场试过 3 档频率（0.08/0.12/0.18）、样例 6³ 与 8³、
## 迭代 3 与 4 —— **全部 20 次尝试均矛盾、输出空模型**；域扭曲（用噪声给取模坐标
## 加整数量偏移）同样无解。原因就是上面的 ②：噪声让每个 3³ 窗口几乎唯一，
## 图案数爆炸，相容图退化成长链。
## 也就是说重叠式 WFC **在原理上就无法摆脱样例的周期**，"打散点阵"这件事不能在做
## 样例时做，只能在样例**之后**做 —— 见 pcg_world_demo 里岩壁那档 0.7 的风化。
static func overlap_sample(size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var m := 0
				if (x + 2 * y + 3 * z) % 5 < 2 or (2 * x + y - z) % 6 < 2:
					m = 2 if (x + z) % 3 == 0 else 1
				v[x + y * size.x + z * size.x * size.y] = m
	return v