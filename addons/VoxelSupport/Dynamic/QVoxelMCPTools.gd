@tool
extends RefCounted

## ======= 体素程序化建模 —— 项目侧 MCP provider =======
##
## 由 DEVFramework 的 MCPDevServer 按项目设置 `dev_framework/mcp/providers` 加载并调用 `register`。
##
## 【只剩一个"说明"工具】建模能力已收敛到脚本侧: 用 `QVoxelScript`(全局类, 自动分流实时/无头)
## 写脚本, 在 eval_code(process="editor"|"game") 里执行 —— 这比固定形状的 MCP 工具更自由。
## 故这里只留 `voxel_help`(API 说明), 不再暴露 reset/material/draw/resize/info/save 等包装工具。
##
## 【说明为何内嵌】打包运行时 .md 不进包、源码文本也不可读, 只有随包编译的字符串还能拿到 ——
## 这正是本工具存在的理由。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

const HELP := """# 体素程序化建模 —— API 说明
全部入口在一个类: **QVoxelScript**(全局类)。软件(QVoxelier)界面上能做的每个动作,
这里都有同名方法; 软件能打开/保存的格式, 这里也能。

## 0. 最短闭环

    QVoxelScript.new_model(Vector3i(32,32,32))
    var skin := QVoxelScript.material(Color(0.8,0.5,0.3), 0.0, 0.8)   # 参数: 颜色/金属/粗糙/自发光
    QVoxelScript.paint(VoxelPrimitives.ball(Vector3i(8,8,8), 5), skin)
    QVoxelScript.save("user://model.qvx")        # 存 .qvx 工程
    QVoxelScript.save("res://art/model.vox")     # 存 .vox(按扩展名自动换格式)

## 1. 进程与分流(决定"看不看得见")

- 运行时场景里有 QVoxelier → 走应用内部命令路径: **看得见、可撤销**。用 `eval_code(process="game")`。
- `process="editor"` → **一律走无头**(内存里的 QVoxelWorld), 不会碰你正开着的场景; 生成完写文件即可。
- 想看效果: `voxel_render`(MCP) 或 `QVoxelScript.preview()` 直接出 PNG, 再用 read_file 看图 ——
  **不需要导入、不需要打开软件**(见 §9)。
- 状态在同一进程内跨 `eval_code` **保持**(静态字段), 所以可以分多次调用逐步搭建。

## 2. 文件

    open(path) -> bool                    # .qvx 工程 / .vox 外部模型, 打开后可继续改
    save(path := "user://voxel_model.qvx") # 按扩展名选格式; 没写扩展名按 .qvx 补
    import_model(path, resolution := 96)   # 网格(glTF/OBJ) → 体素并**并入**世界; 需 await
    export_mesh(path)                      # 世界 → .glb/.gltf
    preview(path, opts)                    # 离屏渲一张 PNG(**不用导入/不用开软件**); 需 await
                                           # opts: {file, size, yaw, pitch, dist, bg, transparent,
                                           #        views, frames, gap}
    # 例: await QVoxelScript.import_model("res://art/chair.glb", 64)
    # 例: await QVoxelScript.preview("user://shot.png", {"file": "user://model.qvx", "size": 800})
    # 例: 三视图+等轴拼一张(行=视角, 列=帧):
    #     await QVoxelScript.preview("user://sheet.png", {"views": "front,right,top,iso", "size": 320})
    # 例: 动画全帧横排(时间在横轴):
    #     await QVoxelScript.preview("user://anim.png", {"frames": -1, "size": 256})

`.qvx` / `.vox` 的读写与"打开文件"走同一条装载路径, 所以外部 `.vox` 打开后可以直接接着改。
注意 `export_mesh` 依赖 GLTFDocument: 在**编辑器进程**里 Godot 不导出编辑器场景网格,
会明确返回 false(不产空壳); 需要网格请用 game 进程或软件里的"导出"按钮。

## 3. 对象树(多模型 / 组 / 摆放)

    nodes() -> Array                     # 全部节点: {id, kind, name, parent, visible, frames}
    models() -> Array                    # 只列模型: {id, name, grid_size, offset, visible, frames, solid}
    active(id := -1) -> int              # 读 / 切活动模型
    add_model(name := "", grid := Vector3i.ZERO, parent_id := 0) -> int
    add_group(name := "Group", parent_id := 0) -> int
    remove_node(id) / rename_node(id, name) / move_node(id, parent_id, index := -1) -> bool
    set_offset(id, Vector3i)             # 摆放: 体素格位移(相对父)
    set_rotation(id, Vector3)            # 摆放: 角度,**只接受 90 的倍数**
    set_visible(id, on) / resize(size, id := -1) -> bool

**节点 id 约定**: 模型 = `model_id`(> 0, 落盘); 组 = 负数(仅内存内稳定, 重新 open 后需重新查)。
`parent_id = 0` 表示顶层。

## 4. 材质(调色板, id 从 1 起; 0 = 空气)

    material(color, metal := 0.0, rough := 0.8, emission := 0.0) -> int
    set_material_color(id, color) -> bool
    set_material_pbr(id, metal := -1.0, rough := -1.0, emission := -1.0) -> bool   # 负数=不动
    materials() -> Array                 # [{id, color, metal, rough, emission}]

## 5. 体素

    paint(cells: Array[Vector3i], material_id := 1) -> int   # 返回实际改动格数
    erase(cells) -> int       # 等价 paint(cells, 0)
    get_voxel(pos, id := -1) -> int
    count_solid(id := -1) -> int

`VoxelPrimitives`(与画笔同一份实现)产出格子集合: `line(a, b)` `box(a, b)` `ball(center, radius)`
`dilate(cells, radius)` `dilate_plane(cells, radius, normal)` `region(seeds, accept, step)`。
自定义算法直接拼 `Array[Vector3i]` 交给 paint。

## 6. 帧动画

    frames(id := -1) -> {count, active, fps, loop, durations}
    add_frame(duplicate := false, id := -1) -> int           # 当前帧之后插入并切过去; duplicate=复制当前帧
    remove_frame(index, id := -1) / move_frame(from, to, id := -1) -> bool
    set_frame(index, id := -1)                               # 切帧(只影响读路径: 渲染/求值/统计)
    set_frame_duration(index, ms, id := -1) / set_anim(fps, loop, id := -1) -> bool

静态模型第一次 add_frame 会被**就地转成动画**(现有体素进第 0 帧), 新帧插在它之后。

## 7. 相机书签

    cameras() -> [{name, pos, look, fov}]
    add_camera(name := "camera") -> int
    remove_camera(index) -> bool
    set_camera(index, "pos" | "look" | "fov" | "name", value) -> bool

## 8. 信息

    info() -> {live, grid_size, voxel_count, material_count, models, active, frames}

## 9. 格式与硬约束

- **.qvx**(工程, 无损): 完整模型树、帧动画、组、相机、PBR。block_size 必须是 2 的幂(默认 32)。
- **.vox**(MagicaVoxel 交换格式)硬约束 —— 不合规时 `save` 返回 false 且不落盘
  (报错里带具体原因, 也可先问 `VoxWriter.check(world)` 拿全量 reasons/warnings):
  尺寸 ≤ 256 / 旋转只能是 90° 整数倍 / 平移必须是整数格 / 体素帧动画只写**当前帧** /
  调色板 8 位色。需要"多帧都带走"就存 .qvx, 或用 export_mesh 出 .glb。
- 无头模式 grid_size 只是参考(坐标可为负, .qvx bounds 按实际体素自动算); 实时模型才是硬边界。

**看图(自检闭环)**: `voxel_render(path=...)` 或 `QVoxelScript.preview()` 直接出 PNG,
再用 read_file 打开 —— 不用导入、不用打开软件, 改完再渲一次即可。
**一张图看全**: `views` 一次出多视角(front/back/left/right/top/bottom/iso 或 `{yaw,pitch}` 数组),
`frames=-1` 出全部动画帧; 两者同时给就是拼图 —— **视角横向并排、帧纵向叠加**,
只有帧在变时沿横轴铺开(时间轴)。每格 `size` 见方, `gap` 留缝。单视角单帧原样返回, 与以前逐像素一致。
需要"编辑器里能像资源一样双击打开"时, 才走 `res://` + `scan()` + `reimport()`。
【前提】渲染要渲染服务器: 编辑器/游戏进程可以, `--headless` 不行(headless 就是没渲染设备)。
输出写 `user://`(默认)即可; 写 `res://` 会被编辑器当图片资源导入, 平白多出 `.import`。

## 10. 约定与坑

- eval_code 的 code 是**方法体**, 用 `return` 返回; 跨行注意缩进。
- `models()` / `nodes()` 返回**字典数组**(给调用方读的); 要拿对象用 `QVoxelScript.model(id)` /
  `QVoxelScript.world()`, 需要链式调用时显式标注类型(如 `var m: QVoxelModel = QVoxelScript.model()`)。
- 坐标是整数体素, 最小粒度 1 格; 材质 0 = 空气。
- 打包运行时: QVoxelScript / VoxelPrimitives 随包可用, 源码不可读 —— 本文即为此提供。"""


const RESOURCE_URI := "voxel://api"


static func register(add_tool: Callable) -> void:
	add_tool.call("voxel_help",
		"体素程序化建模的**完整 API 说明**: QVoxelScript 统一入口(文件/对象树/材质/体素/帧/相机/导入导出/预览)、"
		+ "实时与无头分流、.qvx 与 .vox 的硬约束。返回指向资源 %s 的链接。" % RESOURCE_URI,
		MCPToolSchema.no_arg(), _help)
	add_tool.call("voxel_render",
		"把 .qvx / .vox（或 QVoxelScript 当前世界）离屏渲染成 PNG, **不需要导入、不需要打开 QVoxelier**。"
		+ "返回图片路径, 用 read_file 打开即可看图; 造型不对就改完再渲一次。视角/尺寸/背景可调。",
		_render_schema(), _render)


## MCP 静态文档资源(内嵌内容, 编辑器与运行时都可用)。由 MCPResourceDocs 注册。
static func resources() -> Array:
	return [{
		"uri": RESOURCE_URI,
		"name": "体素程序化建模 API",
		"description": "QVoxelScript 全量接口 + 格式约束 + 自检闭环。",
		"mimeType": "text/markdown",
		"content": HELP,
	}]


## 追加到服务器级 instructions 的一句话(见 MCPDevServer.BASE_INSTRUCTIONS)。
static func instructions() -> String:
	return "体素建模: 用 QVoxelScript 脚本(自动分流实时/无头)完成全部操作, voxel_render 出图自检; API 见资源 %s 或工具 voxel_help。" % RESOURCE_URI


## 返回文档: 正文内联为 text(资源感知之外的客户端也能直接读到), 另附 resource_link 供拉取/缓存。
static func _help(_args: Dictionary) -> Dictionary:
	return MCPResult.resource_link(RESOURCE_URI, "体素程序化建模 API", "text/markdown", HELP,
		"QVoxelScript 全量接口说明")


static func _render_schema() -> Dictionary:
	return {"type": "object", "properties": {
		"path": MCPToolSchema.str_arg("要渲的 .qvx / .vox 路径(res:// 或 user://)；省略 = 渲 QVoxelScript 当前世界"),
		"out": MCPToolSchema.str_arg("PNG 输出路径，默认 user://voxel_preview.png"),
		"size": {"type": "integer", "minimum": 64, "maximum": 4096, "description": "每格边长(像素)，默认 512"},
		"yaw": {"type": "number", "description": "水平角(度)，默认 35（未给 views 时生效）"},
		"pitch": {"type": "number", "description": "俯仰角(度)，默认 20，范围 -85..85（未给 views 时生效）"},
		"dist": {"type": "number", "description": "相机距离 = dist × 包围球半径，越小越放大，默认 2.6"},
		"views": MCPToolSchema.str_arg(
			"多视角拼图：逗号分隔的视角名或角度数组。可选 front/back/left/right/top/bottom/iso，"
			+ "如 \"front,right,top,iso\"；也可传 [{yaw:0,pitch:0},...]。省略 = 单视角(yaw/pitch)"),
		"frames": {"type": "integer", "description": "动画帧：0=当前帧(默认)，-1=全部帧，n=前 n 帧。与 views 同时给则视角横排、帧纵叠"},
		"gap": {"type": "integer", "minimum": 0, "maximum": 64, "description": "拼图格子间距(像素)，默认 0(边对边)"},
		"bg": MCPToolSchema.str_arg("背景色 #rrggbb，默认 #2a2d33"),
		"transparent": {"type": "boolean", "description": "透明背景(PNG 带 alpha)，默认 false"},
	}}


## 渲一张预览图。世界为空/无体素/headless 时明确失败 —— 不产出"纯背景色"的假截图。
## 先各自预检，让"路径写错"和"没渲染设备"报的不是同一句话。
static func _render(args: Dictionary) -> Dictionary:
	var src := str(args.get("path", "")).strip_edges()
	if not src.is_empty() and not FileAccess.file_exists(src):
		return MCPResult.err_validation("找不到 %s" % src,
			"确认路径(res:// 或 user://)；省略 path 则渲 QVoxelScript 当前世界")
	var out := str(args.get("out", "user://voxel_preview.png")).strip_edges()
	if out.get_extension().is_empty():
		out += ".png"
	var dir := out.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		return MCPResult.err_validation("输出目录不存在: %s" % dir,
			"换一个已存在的目录，或用默认的 user://")
	var opts := args.duplicate()
	opts["file"] = src
	var saved: String = await QVoxelScript.preview(out, opts)
	if saved.is_empty():
		return MCPResult.err_validation(
			"渲染失败：目标里没有体素（空世界/空模型），或当前进程没有渲染设备(headless)",
			"确认 .qvx/.vox 里确实有体素；渲染需要带窗口的编辑器或游戏进程")
	var o := QVoxelPreview.normalize(opts)
	var views: Array = o["views"]
	var cell := "%d×%d" % [o["size"], o["size"]]
	var how := "%s (yaw %d°, pitch %d°)" % [cell, int(o["yaw"]), int(o["pitch"])]
	if views.size() > 1 or int(o["frames"]) != 0:
		how = "%d 视角 × frames=%d, 每格 %s(视角横排 帧纵叠)" % [views.size(), int(o["frames"]), cell]
	return MCPResult.ok_with_meta("已渲染 %s → %s —— 用 read_file 打开看效果" % [how, saved],
		{"path": saved, "size": o["size"], "views": views.size(), "frames": o["frames"]})
