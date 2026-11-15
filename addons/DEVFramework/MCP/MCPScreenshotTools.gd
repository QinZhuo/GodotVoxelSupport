@tool
extends RefCounted

## ======= 截图域: 请求形状(与进程无关的安全部分) =======
## **本文件必须导出安全**(零编辑器标识符): 运行时服务器要在导出包里注册 take_screenshot,

## 不 preload MCPToolSchema: 本工具的 schema 是带 enum 的自定义字典, 那里没有对应工厂。


## ======= 请求形状(spec) =======
static func spec() -> Dictionary:
	return {
		"name": "take_screenshot",
		"desc": "画面感知工具, 只回答画面长什么样(像素)。capture_type='game'真实游戏截图(默认; 保存PNG返回路径; 需游戏运行), 'editor'编辑器视口截图, 'scene'场景缩略图。真实截图默认自动判定颜色空间(color_mode=auto: 按渲染缓冲的实际格式决定要不要补 sRGB 编码), 出图与实际看到的画面一致, 一般无需干预; 仅极少数偏色场合用 color_mode 覆盖。**只读文本布局/找可点的东西, 用 get_interactables**(返回可见元素与 ref, 比截图文本更结构化), 再配 simulate_*。仅当你能看到图片(多模态识图)时才需要本工具。",
		"schema": {"type": "object", "properties": {
			"capture_type": {"type": "string", "enum": ["game", "editor", "scene"], "description": "模式: game=真实游戏截图(默认, 需游戏运行; 导出运行时=本进程), editor=编辑器视口截图, scene=当前场景缩略图。传错值会直接报错而非静默回落"},
			"max_width": {"type": "integer", "description": "最大宽度, 超过则等比缩小。默认 1280, 传 0 或更大值可保留原始分辨率"},
			"color_mode": {"type": "string", "enum": ["auto", "srgb", "raw"], "description": "颜色处理模式, 默认 auto(按渲染缓冲的实际数据格式自动判定, 出图即所见)。srgb=强制补一次 linear→sRGB 编码(认定读回的是线性光值), raw=强制不转换(认定读回的已是显示值)。只有确认出图偏色时才需要手动指定"},
			"srgb": {"type": "boolean", "description": "[已废弃, 请用 color_mode] 旧的强制开关, 等价 color_mode=srgb(true)/raw(false); 与 color_mode 同时传时以 color_mode 为准。不传则走 auto"}
		}},
	}


## 从 MCP 入参里挑出**调用方显式指定**的颜色处理项, 交给 ScreenshotTool 的 opts。
## ⚠️ 刻意只透传"传了什么": 不传就一个键都不放, 让 ScreenshotTool 走 auto 自己判。
static func color_opts(args: Dictionary) -> Dictionary:
	var out := {}
	if args.has("color_mode"):
		out["color_mode"] = VariantTool.get_string(args, "color_mode", ScreenshotTool.COLOR_AUTO)
	if args.has("srgb"):
		out["srgb"] = VariantTool.get_bool(args, "srgb", true)
	return out


## ======= 截断收口在哪 =======
