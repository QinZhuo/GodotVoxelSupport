@tool
extends RefCounted

## ======= 文件操作域 =======
##
## 从 MCPDevServer 拆出的工具域, 收录"在磁盘上读写单个文件"这一类能力:
## read_file / write_file / append_file / delete_file / file_exists,
## 外加本域专属的写路径安全设施(guard_write_path + dry_run 预演结果拼装)。
##
## 依赖方向与 MCPCodeIndex 一致, 严格单向: 本文件**不引用** MCPDevServer, 也不持有任何
## 服务器状态, 只依赖:
##   - MCPResult      响应封装
##   - MCPToolSchema  请求 schema 工厂
##   - VariantTool    全局 class_name, 入参读取
## 注册靠"把 _add_tool 当 Callable 传进来"完成, 所以连服务器的类型都不需要认识。
##
## ## guard_write_path 为什么归本域
##
## 它是**本域专属**件, 不是共享件: 全项目调用方只有三个, 正是本域的 write_file /
## append_file / delete_file 三个 handler(见 MCPDevServer 顶部"路径守卫对三者一致生效"
## 那句注释所指的正是这三个)。留在主服务器会让本域每个写类 handler 都得反向引用服务器,
## 等于把耦合从横向搬到纵向, 什么都没解决。故连同它的两个常量一起收进本文件。
##
## ## 写路径守卫是安全边界, 不是校验糖
##
## 拒绝 '..' 父级跳转、拒绝 .godot/.import/Assets/imported/project.godot 等引擎管理目录、
## 拒绝 res:// 与 user:// 之外的路径 —— 这三条各自都有具体的误伤场景(写到项目外、覆盖导入
## 索引、用裸覆盖改 project.godot 绕过类型转换), 任何一条被"顺手放宽"都会立刻变成
## 删错东西/工程损坏, 且**不报错**。改本文件时不要把它们当冗余检查清理掉。
##
## ## 接缝自查: 本域无功能接缝(log 域那条全局判据的第四种答案)
##
## 判据原文: "接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。"
## 本域对照结论 = **三个依赖全都不需要接缝**, 因为它们要么能域内自建、要么压根没有初始化步骤:
##   - MCPResult / MCPToolSchema 是 preload 常量。漏 preload 是**编译错误**, 不是运行期漏调。
##   - VariantTool 是全局 class_name, 静态调用, 没有"忘了 bind"这种状态。
##   - 文件系统无需注入。
## 所以本域不存在"log 域注入 logger / validate 域自建"那种分歧, 无需为统一而改。
##
## 唯一的注入项是 register(add_tool) 这个注册接缝, 漏调后果是**显式可见**的, 故保留接缝:
## 5 个工具不进 _tool_defs/_tool_handlers -> tools/list 里查不到 -> 任何调用在协议层就撞上
## "Unknown tool: read_file"(HTTP 路径)或"未知运行时工具"(编辑器路径); 契约自检也会因注解
## 名单里的工具名对不上而报出。三条都不是静默, 符合判据。
##
## **本域唯一要警惕的接缝诱惑: 别把输出上限拉进域内。**
## read_file 是全局载荷最大的工具, 看上去"截断是本域的事", 但 enforce_output_cap 是协议层
## 对所有工具统一施加一次的关口。若有人图"就近"把它改成注入接缝, 漏调形态是: 客户端按协议
## 静默切掉尾部 -> AI 拿到残缺数据却以为完整 -> 基于错误的文件内容做修改。属"漏调会静默失效",
## 按判据一律不许。真要限长就用本域的 offset/limit 显式分页(见 _handle_read_file)。
##
## **必须带 @tool 且不声明 class_name**, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")


## ======= 域注册入口 =======
##
## 由 MCPDevServer._register_file_tools() 转发调用一次。add_tool 是服务器 `_add_tool` 的
## Callable, 签名 (name, desc, input_schema, handler)。
##
## handler 一律 static(不用 lambda): MCPToolAudit 靠 handler.get_method() 拿函数名再去源码里
## 切函数体做入参一致性自检, lambda 注册会让 get_method() 返回空串, 那批工具将**静默跳过**
## 自检 —— 详见 MCPCodeIndex 开头与 MCPToolAudit 开头。

## -- 文件操作 --
## 写类工具统一带 dry_run: 批量改动或删文件前先用 dry_run=true 预演影响面, 确认后再去掉该参数
## 实际执行。路径守卫(仅 res:// 与 user://、拒绝 '..'、拒绝引擎管理目录)对三者一致生效,
## 详见 guard_write_path。
static func register(add_tool: Callable) -> void:
	add_tool.call("read_file",
		"读取文件内容(UTF-8)。返回内容与大小。大文件分段读: offset=起始字符下标(单位是**字符**不是字节), limit=本次最多返回字符数(默认0=不限); 返回的 next_char_offset=-1 表示已读完, 否则把它作为下次 offset 传入即可续读(同 get_logs 的 since/next 约定)。",
		MCPToolSchema.read_file(),
		_handle_read_file)

	add_tool.call("write_file",
		"写入内容到文件(不存在则创建, 含目录; 存在则**覆盖**, 不可撤销)。建议先 dry_run=true 预演(会告知是否覆盖已有文件), 确认后再实写。",
		MCPToolSchema.write_content(),
		_handle_write_file)

	add_tool.call("append_file",
		"追加内容到文件(不存在则创建)。可传 dry_run=true 查看当前大小而不实际追加。",
		MCPToolSchema.write_content(),
		_handle_append_file)

	add_tool.call("delete_file",
		"删除文件或空目录(**不可撤销**)。强烈建议先传 dry_run=true 预演(返回目标大小), 确认后再删。目录只能删空目录。",
		MCPToolSchema.file_path("文件或目录路径(res:// 或 user://)", true),
		_handle_delete_file)

	add_tool.call("file_exists",
		"检查文件或目录是否存在。",
		MCPToolSchema.file_path("文件或目录路径(res:// 或 user://)"),
		_handle_file_exists)


## ======= 文件操作实现 =======

## 本域载荷最大的工具, 也是最容易被"顺手加上截断"的地方 —— **别加**。
## 理由见文件头"接缝自查"一节: 输出上限是调度层对所有工具统一施加的设施, 拉进域内就会变成
## 漏调即静默给出残缺内容的接缝。要限长用下面的 offset/limit。
static func _handle_read_file(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	if not FileAccess.file_exists(path):
		return MCPResult.fail("文件不存在: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return MCPResult.fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	# 仅支持 UTF-8(引擎默认编码)。此前声明的 gbk/gb2312 实际未实现解码, 已移除以免误导。
	var content := file.get_as_text()
	var size := file.get_length()
	file.close()
	# 分段读: offset/limit 按**字符**切(String 的索引单位), 而上面的 size 是 `get_length()`
	# 给的**字节**。两者单位不同且都要返回给调用方, 故游标字段独立命名 next_char_offset ——
	# 若沿用 offset 这类中性名字, 调用方极可能拿它当字节偏移去和 size 比较, 得出错误的长度。
	var total_chars := content.length()
	var offset: int = maxi(0, VariantTool.get_int(args, "offset", 0))
	var limit: int = VariantTool.get_int(args, "limit", 0)
	if offset > total_chars:
		# 不静默返回空串: 读到文件末尾却拿到空内容, 调用方无法区分"文件是空的"与"游标越界",
		# 而这两种情况的正确动作完全相反(前者该结束, 后者该把游标退回)。
		return MCPResult.fail("offset %d 超出文件末尾(总字符数 %d)。文件已读完, 无需续读; 若确需重读请把 offset 回退到 0" % [offset, total_chars])
	# limit<=0 表示不限: substr 的第二参传 -1 即"到末尾", 但显式分两支写, 免得读代码的人
	# 要去查 substr 的默认参数语义才能确认这里没漏东西。
	var chunk: String = content.substr(offset, limit) if limit > 0 else content.substr(offset)
	var consumed: int = offset + chunk.length()
	return MCPResult.ok_json({
		"path": path,
		"size": size,
		"encoding": "utf-8",
		"offset": offset,
		"total_chars": total_chars,
		"returned_chars": chunk.length(),
		# -1 = 已读完; 否则原样作为下次 offset 传回即可续读。语义与 get_logs 的 next 一致,
		# 免得同一个服务器里出现两种游标约定, 那是 AI 最容易搞混的一处。
		"next_char_offset": consumed if consumed < total_chars else -1,
		"content": chunk,
	})


## ======= 文件写入安全(dry_run + 路径守卫) =======
##
## 统一入口, 三个文件工具(写入/追加/删除)共用: 检查顺序为 路径合法性 → dry_run 短路 → 实际改动。
## 拆出独立函数而不是散在各 handler 里, 是因为这类守卫最容易漂移 —— 三个工具里漏一处,
## 就等于该工具完全没有保护, 而这类遗漏不会报错、只在真的删错东西时才暴露。
##
## dry_run 的语义是"只回报将要发生什么, 不动任何东西", 用于让 AI 在批量改动前先确认影响面;
## 返回里显式带 dry_run=true, 避免调用方把预演结果误当成已完成。

## 写操作允许的路径前缀。
## res:// = 工程内(可写), user:// = 引擎用户数据目录(可写, 不污染工程)。
## 刻意**不**放行: 绝对路径(可能写到项目外的任意位置)、相对路径(依赖 cwd, 行为不可预测)。
const _WRITE_PATH_PREFIXES := ["res://", "user://"]

## 受保护路径前缀: 这些目录由引擎/导入器管理, 人工写入要么被覆盖要么会破坏索引。
## project.godot 同理 —— 改它应当走 project_setting(有类型转换与注册表处理), 而非裸覆盖。
const _PROTECTED_PREFIXES := [
	"res://.godot/", "res://.import/", "res://Assets/imported/",
	"res://project.godot",
]


## 校验写路径。返回空串 = 通过; 否则返回拒绝原因(可直接作为错误信息)。
static func guard_write_path(path: String) -> String:
	if path.is_empty():
		return "必须提供 path"
	if path.contains(".."):
		return "路径含 '..' 父级跳转(拒绝): %s" % path
	for p in _PROTECTED_PREFIXES:
		if path.begins_with(p):
			return "路径位于受保护目录, 禁止直接写入: %s (%s 由引擎/导入器管理, 请改用对应工具操作)" % [path, p]
	var ok := false
	for p in _WRITE_PATH_PREFIXES:
		if path.begins_with(p):
			ok = true
			break
	if not ok:
		return "只允许写入 res:// 或 user:// 下的路径(收到: %s)。绝对路径会写到工程外, 相对路径依赖当前工作目录, 均不允许。" % path
	return ""


## 预演结果(统一形状)。
static func _dry_run_result(tool_name: String, path: String, detail: Dictionary) -> Dictionary:
	var info := detail.duplicate(true)
	info["path"] = path
	info["dry_run"] = true
	info["message"] = "[预演] 未做任何改动。确认无误后去掉 dry_run 参数重新调用 %s。" % tool_name
	return MCPResult.ok_json(info)


static func _handle_write_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	var content := VariantTool.get_string(args, "content")
	var existed := FileAccess.file_exists(path)
	var dir_path := path.get_base_dir()
	if VariantTool.get_bool(args, "dry_run"):
		return _dry_run_result("write_file", path, {
			"action": "write",
			"exists": existed,
			"would_overwrite": existed,
			"would_create_dirs": not dir_path.is_empty() and DirAccess.open(dir_path) == null,
			"bytes": content.length(),
		})
	if not dir_path.is_empty():
		var dir := DirAccess.open(dir_path)
		if dir == null:
			var err := DirAccess.make_dir_recursive_absolute(dir_path)
			if err != OK:
				return MCPResult.fail("无法创建目录: %s (错误码: %d)" % [dir_path, err])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return MCPResult.fail("无法写入文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.store_string(content)
	var size := file.get_length()
	file.close()
	return MCPResult.ok_json({
		"path": path,
		"size": size,
		"existed": existed,
		"message": "文件写入成功"
	})


static func _handle_append_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	var content := VariantTool.get_string(args, "content")
	var existed := FileAccess.file_exists(path)
	if VariantTool.get_bool(args, "dry_run"):
		return _dry_run_result("append_file", path, {
			"action": "append",
			"exists": existed,
			"current_size": FileAccess.get_file_as_string(path).length() if existed else 0,
			"bytes": content.length(),
		})
	if not existed:
		# 目标不存在时复用 write_file 的实现路径(建目录 + 写入), 而不是另写一份创建逻辑 ——
		# 两份创建逻辑的漂移形态是"append 能建目录、write 不能"这类半通不通的 bug。
		return _handle_write_file(args)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		return MCPResult.fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.seek_end()
	file.store_string(content)
	var new_size := file.get_length()
	file.close()
	return MCPResult.ok_json({
		"path": path,
		"size": new_size,
		"message": "内容追加成功"
	})


static func _handle_delete_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	# dry_run 读一次就够: 原本两个分支各判一次 `args.get("dry_run") == true`, 严格比较
	# 在客户端把 true 传成字符串 "true" 时两边都失效 —— 预演被静默跳过, 而调用方(AI)
	# 看到的是"预演成功", 于是以为文件还在。
	var dry_run := VariantTool.get_bool(args, "dry_run")
	if not FileAccess.file_exists(path):
		var dir := DirAccess.open(path)
		if dir == null:
			return MCPResult.fail("文件或目录不存在: %s" % path)
		if dry_run:
			return _dry_run_result("delete_file", path, {"action": "delete_empty_dir"})
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			return MCPResult.fail("无法删除目录: %s (错误码: %d)。注意: 只能删除空目录" % [path, err])
		return MCPResult.ok_json({"path": path, "message": "目录删除成功"})
	if dry_run:
		return _dry_run_result("delete_file", path, {
			"action": "delete_file",
			"bytes": FileAccess.get_file_as_string(path).length(),
		})
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return MCPResult.fail("无法删除文件: %s (错误码: %d)" % [path, err])
	return MCPResult.ok_json({"path": path, "message": "文件删除成功"})


static func _handle_file_exists(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	var exists := FileAccess.file_exists(path)
	var is_dir := false
	if not exists:
		var dir := DirAccess.open(path)
		is_dir = dir != null
	return MCPResult.ok_json({
		"path": path,
		"exists": exists or is_dir,
		"is_directory": is_dir,
		"message": "文件存在" if exists else ("目录存在" if is_dir else "文件不存在")
	})
