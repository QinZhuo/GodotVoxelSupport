@tool
extends RefCounted

## ======= MCP 资源(静态文档)注册表 =======
##
## 项目侧 provider 用 `static func resources() -> Array` 声明文档, 每项:
##   {"uri": "...", "name": "...", "description": "...", "mimeType": "text/markdown", "content": "..."}
## **content 是内嵌字符串**(不读文件) —— 于是导出包没有 .md 也能提供资源, 运行时同样可用。
##
## 本文件**必须导出安全**(不得出现 EditorInterface 等编辑器引用): resources/list|read 在
## 编辑器与运行时两个进程都要能 _mod 它。这也是它独立于 MCPResourceTools 的原因 —— 后者含
## 编辑器工具(open_scene 等), 导出包解析不了。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")

## 已注册文档(provider 声明顺序 = 稳定顺序, 满足规范"确定性排序"要求)。
static var _docs: Array = []


## 清空(每轮工具注册前由 MCPDevServer 调用, 与 _reset_tools 同节奏)。
static func clear() -> void:
	_docs = []


## 合并一批文档。uri 重复时后者覆盖前者(便于同一 provider 分多次声明)。
static func register(docs: Array) -> void:
	for d in docs:
		if not (d is Dictionary):
			continue
		var doc: Dictionary = d
		if str(doc.get("uri", "")).is_empty() or str(doc.get("content", "")).is_empty():
			continue
		var i := _index_of(str(doc["uri"]))
		if i >= 0:
			_docs[i] = doc
		else:
			_docs.append(doc)


## resources/list 的响应体。
static func list_all() -> Array:
	var out: Array = []
	for d in _docs:
		out.append({
			"uri": d["uri"],
			"name": str(d.get("name", d["uri"])),
			"description": str(d.get("description", "")),
			"mimeType": str(d.get("mimeType", "text/markdown")),
		})
	return out


## resources/read 的 result 体。成功 {contents:[...]}; uri 未知返回 MCPResult 的 validation
## 错误(自带 content + isError), 两种情况都是合法 result。
static func read(uri: String) -> Dictionary:
	var i := _index_of(uri)
	if i < 0:
		return MCPResult.err_validation("未登记的资源 uri: %s" % uri,
			"先调 resources/list 取可用 uri(共 %d 份)" % _docs.size())
	var d: Dictionary = _docs[i]
	return {
		"contents": [{
			"uri": uri,
			"name": str(d.get("name", uri)),
			"description": str(d.get("description", "")),
			"mimeType": str(d.get("mimeType", "text/markdown")),
			"text": str(d.get("content", "")),
		}],
	}


static func _index_of(uri: String) -> int:
	for i in _docs.size():
		if str((_docs[i] as Dictionary).get("uri", "")) == uri:
			return i
	return -1
