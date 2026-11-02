extends TestCase

## MCP 资源端点与体素 provider 的文档接口(编辑器进程即可, 纯逻辑)。
## 覆盖:
##   · MCPResourceDocs 的注册 / 去重 / 跳过无效项 / 读取 / 未知 uri 错误;
##   · MCPResult.resource_link 的 content 形状(text + resource_link);
##   · QVoxelMCPTools 的 resources() / instructions() / _help(正文内联 + resource_link)。
## 【为什么不碰服务器实例】本文件用 preload 取脚本(ResourceLoader 缓存对象), 与服务器 _mod
## 动态重编译出的对象**各自持有独立 static** —— 故 clear() 不会清掉运行中服务器的资源表。

const MCPResourceDocs := preload("res://addons/DEVFramework/MCP/MCPResourceDocs.gd")
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const QVoxelMCPTools := preload("res://addons/VoxelSupport/Dynamic/QVoxelMCPTools.gd")


func test_resource_docs_register_and_list() -> void:
	MCPResourceDocs.clear()
	assert_eq(MCPResourceDocs.list_all().size(), 0, "clear 后应为空")
	MCPResourceDocs.register([
		{"uri": "test://a", "name": "A", "description": "d", "mimeType": "text/plain", "content": "hi"},
	])
	var list: Array = MCPResourceDocs.list_all()
	assert_eq(list.size(), 1, "应注册 1 份")
	assert_eq(list[0]["uri"], "test://a")
	assert_eq(list[0]["mimeType"], "text/plain")
	assert_false((list[0] as Dictionary).has("content"), "list 项不应带 content(只在 read 时给)")


func test_resource_docs_read_known_and_unknown() -> void:
	MCPResourceDocs.clear()
	MCPResourceDocs.register([{"uri": "test://a", "name": "A", "content": "hello"}])
	var ok: Dictionary = MCPResourceDocs.read("test://a")
	assert_false(bool(ok.get("is_error", false)), "已知 uri 不该是错误")
	assert_eq(ok["contents"][0]["text"], "hello")
	assert_eq(ok["contents"][0]["mimeType"], "text/markdown", "默认 mimeType")
	var bad: Dictionary = MCPResourceDocs.read("test://missing")
	assert_true(bool(bad.get("is_error", false)), "未知 uri 应为错误")


func test_resource_docs_dedup_and_skip_invalid() -> void:
	MCPResourceDocs.clear()
	MCPResourceDocs.register([
		{"uri": "test://a", "name": "A1", "content": "1"},
		{"uri": "test://a", "name": "A2", "content": "2"},  # 同 uri → 后者覆盖
		{"uri": "test://b"},                                # 无 content → 跳过
		{"name": "no-uri", "content": "x"},                 # 无 uri → 跳过
		"not-a-dict",                                       # 非字典 → 跳过
	])
	assert_eq(MCPResourceDocs.list_all().size(), 1, "去重 + 跳过无效后应剩 1 份")
	assert_eq(MCPResourceDocs.read("test://a")["contents"][0]["text"], "2", "同 uri 应后者覆盖")


func test_resource_link_shape() -> void:
	var r: Dictionary = MCPResult.resource_link("x://y", "N", "text/markdown", "body", "desc")
	assert_false(bool(r.get("is_error", true)), "resource_link 不应是错误结果")
	var content: Array = r["content"]
	assert_eq(content.size(), 2, "content = [text, resource_link]")
	assert_eq(content[0]["type"], "text")
	assert_eq(content[0]["text"], "body")
	assert_eq(content[1]["type"], "resource_link")
	assert_eq(content[1]["uri"], "x://y")
	assert_eq(content[1]["name"], "N")
	assert_eq(content[1]["mimeType"], "text/markdown")
	assert_eq(content[1]["description"], "desc")


func test_resource_link_empty_description_omitted() -> void:
	var r: Dictionary = MCPResult.resource_link("x://y", "N", "text/markdown", "body")
	var link: Dictionary = r["content"][1]
	assert_false(link.has("description"), "空 description 不应出现在 resource_link 里")


func test_voxel_resources_instructions_help() -> void:
	var res: Array = QVoxelMCPTools.resources()
	assert_eq(res.size(), 1, "应声明 1 份资源")
	assert_eq(res[0]["uri"], "voxel://api")
	assert_true(str(res[0]["content"]).length() > 200, "资源正文应非空")
	assert_true(QVoxelMCPTools.instructions().contains("voxel://api"), "instructions 应指向资源")
	var help: Dictionary = QVoxelMCPTools._help({})
	var content: Array = help["content"]
	assert_eq(content.size(), 2, "help = [正文, resource_link]")
	assert_eq(content[0]["type"], "text")
	assert_true(str(content[0]["text"]).contains("QVoxelScript"), "正文应内联(资源不支持的客户端也能读到)")
	assert_eq(content[1]["type"], "resource_link")
	assert_eq(content[1]["uri"], "voxel://api")


## 参数 schema 必须真的由框架的 MCPToolSchema 产出。两者是运行期绑定（没有框架就整份 provider
## 不注册），而 `call` 写错方法名只会返回 null 而不报错 —— 那样工具在 IDE 里静默丢了参数，
## 属于典型的假绿，只有把返回结构断言出来才拦得住。
func test_register_binds_framework_factories() -> void:
	assert_true(QVoxelMCPTools.framework_available(), "有框架时应能惰性载入契约工厂")
	var got := {}
	QVoxelMCPTools.register(func(name: String, _desc: String, schema: Dictionary, _fn: Callable):
		got[name] = schema)
	assert_eq(got.size(), 2, "应注册 voxel_help + voxel_render")
	assert_eq(got["voxel_help"], {"type": "object", "properties": {}}, "no_arg = 空对象 schema")
	assert_eq(got["voxel_render"]["type"], "object")
	assert_true(got["voxel_render"]["properties"].has("views"), "properties 应由 str_arg 产出")
