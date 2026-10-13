@tool
extends RefCounted

## ======= 截图域: 请求形状(与进程无关的安全部分) =======
##
## **本文件必须导出安全**(零编辑器标识符): 运行时服务器要在导出包里注册 take_screenshot,
## 而该工具的 name / desc / schema / 颜色选项都来自这里。编辑器专属的像素捕获(editor / scene
## 两种模式, 需要 EditorInterface)已拆到 MCPScreenshotEditor.gd, 只在编辑器进程按需加载。
##
## 与 MCPDevServer 的分工: text / game 两种模式分析的是**游戏/运行中画面**, 其通路依赖服务器
## 实例状态(_pending / debugger_plugin), 留在主文件; 这里只提供与进程无关的契约形状。
##
## 响应里只有路径与几个标量, **没有图片数据**, 所以本工具不会撞上输出上限; 体积由 max_width
## (默认降采样到 1280 宽)在**落盘前**压住。截断由协议层统一施加。
##
## 依赖严格单向: 只走全局 class_name(ScreenshotTool / VariantTool), 不引用 MCPDevServer。

## 不 preload MCPToolSchema: 本工具的 schema 是带 enum 的自定义字典, 那里没有对应工厂。


## ======= 请求形状(spec) =======
##
## 工具名 / 描述 / schema 归本域所有: 它们描述"截图这个能力要什么参数", 与"在哪个进程注册"无关。
## 主服务器用 spec() 替掉原先内联的描述与 schema 字面量, 免得同一个契约在两处各写一份。
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
##
## ⚠️ 刻意只透传"传了什么": 不传就一个键都不放, 让 ScreenshotTool 走 auto 自己判。
## 以前这里是 `srgb: get_bool(args, "srgb", true)` —— 由本层替引擎补默认值, 于是 8 位缓冲
## 也被强制编码一次, 出图比实际画面发灰发白。判定的位置只能是"看得见数据格式"的那一层。
## 两个键都在 spec 的 properties 里声明过, 故此处读取不会触发入参自检的"读了未声明"。
static func color_opts(args: Dictionary) -> Dictionary:
	var out := {}
	if args.has("color_mode"):
		out["color_mode"] = VariantTool.get_string(args, "color_mode", ScreenshotTool.COLOR_AUTO)
	if args.has("srgb"):
		out["srgb"] = VariantTool.get_bool(args, "srgb", true)
	return out


## ======= 截断收口在哪 =======
##
## 输出上限由协议层在 handler 执行完紧接着统一施加(游戏进程侧同理), 收口在 handler **之上**,
## 与 handler 写在哪个文件里无关。故本域不需要、也不该复制那套截断实现。
