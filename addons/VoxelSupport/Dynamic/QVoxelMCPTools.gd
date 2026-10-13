@tool
extends RefCounted

## ======= 体素程序化生成 —— 项目侧 MCP provider =======
##
## 由 DEVFramework 的 MCPDevServer 按项目设置 `dev_framework/mcp/providers` 加载并调用 `register`。
##
## 【只剩一个"说明"工具】建模能力已收敛到脚本侧: **优先用 `QVoxelScript`(自动分流实时/无头)
## 或 `QVoxelBuilder`(纯无头)** 写脚本, 在 eval_code(process="editor"|"game") 里执行 —— 这比固定形状的
## MCP 工具更自由, 也是 AI 更擅长的用法。故这里只留 `voxel_help`(API 说明), 不再暴露
## reset/material/draw/resize/info/save 等包装工具(它们都是脚本能力的子集)。
##
## 【说明为何内嵌】打包运行时 .md 不进包、QVoxelBuilder 源码文本也不可读, 只有随包编译的
## 字符串还能拿到 —— 这正是本工具存在的理由。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

const HELP := """# 体素程序化生成 —— 用法说明

## 首选: 脚本 + QVoxelScript(全局类, 自动分流实时/无头)
在 eval_code(process="editor"|"game") 里执行:

    QVoxelScript.new_model(Vector3i(32,32,32), 32)                 # 新建(实时=替换当前模型)
    var id := QVoxelScript.material(Color(0.8,0.5,0.3), 0.0, 0.8)  # 追加材质, 返回 id(从 1 起; 0=空气)
    var cells := VoxelPrimitives.ball(Vector3i(8,8,8), 5)          # 或 box/line/... 返回 Array[Vector3i]
    QVoxelScript.paint(cells, id)                                  # 批量写格, 返回改动数
    QVoxelScript.resize(Vector3i(16,16,16))                        # 改输出盒(保留 [0,size) 交集)
    print(QVoxelScript.info())                                     # {live, grid_size, voxel_count, material_count}
    QVoxelScript.save("user://model.qvx")                          # 写 .qvx

QVoxelScript 每个方法内部自动分流: 运行时有 QVoxelier 应用→改它的当前活动模型(可见、可撤销);
否则→无头 QVoxelBuilder。也可用 QVoxelScript.app() / QVoxelScript.builder() 自取两端。

### 在哪跑(进程决定"是否可见")
- 想改**正在运行的应用**(看得见): 用 **eval_code(process="game")**(编辑器里 process="editor" 跑在编辑器进程, 摸不到游戏)。
- 编辑器里 process="editor": QVoxelScript **不把"编辑中的场景"当实时目标**(避免改你正开着的场景),
  一律落无头 builder; 想看得见就用 eval_code(process="game")。
- **打包运行时**: 服务器就在游戏进程内, process="game" 直接生效、可见。

## 完全控制: 直接用 QVoxelBuilder(纯无头)
    var b := QVoxelBuilder.new(Vector3i(64,64,64), 32)      # (网格, 块边长)
    var skin := b.add_material(Color(0.8,0.5,0.3), 0.0, 0.8, 0.5, 0.5, Color.BLACK)
    b.put(Vector3i(1,2,3), skin)                            # 单格
    b.line(a, c, skin)                                      # 直线(Bresenham)
    b.box(a, c, skin)                                       # 实心长方体(两角点含端点)
    b.ball(Vector3i(8,8,8), 5, skin)                        # 欧氏球
    b.paint(cells, skin)                                    # 任意格子集(自定义算法走它)
    b.voxels()                                              # Vector3i -> 材质ID(只读)
    b.resize(Vector3i(16,16,16))                            # 裁到 [0,size)
    b.save("user://model.qvx")                              # 写 .qvx(含 CRC); 返回 bool
  QVoxelScript.builder() 可取到 QVoxelScript 内部那个无头 builder。

## 实时应用接口(高级; QVoxelScript 内部即走这些)
    var app = get_tree().current_scene               # QVoxelierApp
    app.call("script_new", Vector3i(32,32,32))                    # 新建(整体替换, 无确认框)
    var id: int = app.call("script_add_material", Color(0.8,0.5,0.3), 0.0, 0.8)
    var sess = app.get("session")                    # QVoxelEditSession
    sess.call("apply_cells", cells, id)              # 批量写格(走应用撤销与渲染)
    app.call("script_resize", Vector3i(16,16,16))
    app.call("script_save", "user://model.qvx")
    app.call("script_stats")                         # {grid_size, voxel_count, material_count, objects}

## 约定
- 坐标是整数体素; 实时模式落在 [0,grid)。材质 0 = 空气(写 0 即挖空)。最小粒度 1 体素。
- 无头 builder 的 grid_size 仅参考值(不裁剪, 坐标可负), .qvx bounds 按实际体素自动算;
  实时模型才是硬边界。block_size(2 的幂)只影响 .qvx 分块存储。
- 打包运行时: QVoxelBuilder / QVoxelScript 随包可用, 源码文本不可读 —— 本说明即为此提供。"""


const RESOURCE_URI := "voxel://api"


static func register(add_tool: Callable) -> void:
	add_tool.call("voxel_help",
		"体素程序化生成的**用法说明**(API 参考): 用 QVoxelScript 脚本自动分流实时/无头地建模型, 或直接用 QVoxelBuilder; 含进程选择、坐标与材质约定。返回指向资源 %s 的链接。" % RESOURCE_URI,
		MCPToolSchema.no_arg(), _help)


## MCP 静态文档资源(内嵌内容, 编辑器与运行时都可用)。由 MCPResourceDocs 注册。
static func resources() -> Array:
	return [{
		"uri": RESOURCE_URI,
		"name": "体素程序化生成 API",
		"description": "QVoxelScript / QVoxelBuilder 用法: 何时用脚本、如何自动分流实时/无头、坐标与材质约定。",
		"mimeType": "text/markdown",
		"content": HELP,
	}]


## 追加到服务器级 instructions 的一句话(见 MCPDevServer.BASE_INSTRUCTIONS)。
static func instructions() -> String:
	return "体素程序化生成: 用脚本(QVoxelScript 自动分流实时/无头, 或直接用 QVoxelBuilder) 建模; API 见资源 %s 或工具 voxel_help。" % RESOURCE_URI


## 返回文档: 正文内联为 text(**资源感知之外的客户端也能直接读到**), 另附一个 resource_link
## 指向 %s 供资源感知客户端拉取/缓存。正文较长(约 2.8K), 但 voxel_help 是显式调用, 可接受。
static func _help(_args: Dictionary) -> Dictionary:
	return MCPResult.resource_link(RESOURCE_URI, "体素程序化生成 API", "text/markdown", HELP,
		"QVoxelScript / QVoxelBuilder 用法说明")
