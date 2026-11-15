@tool
extends RefCounted

## ======= 输出整形域 =======
## (主文件的 _output_cap() 是唯一读设置处)。截断策略的每个分支都对应一种真实事故, 无状态


## 补齐 JSON 字符串里剩余的 C0 控制字符转义。
static func json_safe(s: String) -> String:
	# 全程在 PackedByteArray 上做: 用 String.chr(c) 当 needle 会在 c == 0 那轮造出内含 NUL 的
	# "Unexpected NUL character" 纯噪音。检测也必须留在 C++ 侧: tools/list 响应有 38K,
	var bytes := s.to_utf8_buffer()
	# \t \n \r 已由 JSON.stringify 处理, 再转义反而会变成字面量 "\t" 之外的乱码
	var dirty := bytes.find(0) != -1
	if not dirty:
		for c in range(0x20):
			if c == 0x09 or c == 0x0A or c == 0x0D:
				continue
			if bytes.find(c) != -1:
				dirty = true
				break
	if not dirty:
		return s
	# 只在真有脏字节时才重建。追加式而非 resize+赋值: 转义后长度必然变化,
	var out := PackedByteArray()
	for i in bytes.size():
		var b := bytes[i]
		if b < 0x20 and b != 9 and b != 10 and b != 13:
			out.append_array(("\\u%04x" % b).to_utf8_buffer())
		else:
			out.append(b)
	# 此时 out 里已无任何 C0 字节, get_string_from_utf8() 不会再报 NUL
	return out.get_string_from_utf8()


## 统一输出上限: 所有工具(编辑器进程与游戏进程)的返回 text 不得超过 cap 字符。
static func enforce_output_cap(tool_name: String, result: Dictionary, cap: int) -> Dictionary:
	if cap <= 0:
		return result
	var text := str(result.get("text", ""))
	if text.length() <= cap:
		return result
	var original_len := text.length()
	# 预留说明的位置: 说明本身也计入上限, 否则"截断后的结果"仍可能超限。
	var notice := _truncation_notice(tool_name, original_len, cap)
	if notice.length() >= cap:
		# cap 被调到比说明还小时(实测 cap=120 而说明长 329), keep 会退化成 0, 结果是
		notice = ("[已截断] 原文 %d 字符, 超出上限 %d" % [original_len, cap]).substr(0, cap)
	var keep := maxi(0, cap - notice.length())
	# 按行边界回退到最近的换行, 避免把一行劈成两半产生半截 JSON/半截路径。
	var head := text.substr(0, keep)
	var nl := head.rfind("\n")
	if nl > keep / 2:
		head = head.substr(0, nl)
	var new_text := head + notice

	var out: Dictionary = result.duplicate(true)
	out["text"] = new_text
	out["truncated"] = true
	out["omitted_chars"] = original_len - head.length()
	# content[].text 同步: 官方 SDK 客户端读的是 content[], 不同步的话它们看到的是**未截断**
	if out.get("content") is Array and not out["content"].is_empty() and out["content"][0] is Dictionary:
		out["content"][0]["text"] = new_text
	# structuredContent: 成功响应带, 错误响应也带(MCPResult.err 现在会填, 见其说明),
	# 必须**同时缩减 structuredContent 里的长字符串**, 否则截断是假的: 实测 get_scene_tree
	# node_count / pruned_nodes 这类标量元信息(它们很小, 且是判断"要不要续读"的关键)。
	var sc: Variant = out.get("structuredContent", null)
	if sc is Dictionary and not bool(out.get("is_error", false)):
		var merged: Dictionary = sc
		merged["truncated"] = true
		merged["omitted_chars"] = original_len - head.length()
		_shrink_payload(merged, cap / 2)
		out["structuredContent"] = merged
	return out


## 递归把 payload 里超过 limit 的长字符串换成占位说明。阈值取 cap/2, 给多字段叠加留余量。
## 只动字符串: 数字与数组长度是"漏了多少"的唯一线索, 砍掉它们等于让调用方无从判断要不要续读。
## 必须**返回**结果而非原地赋值: Dictionary/Array 是引用类型可就地改, 但 String 是值类型,
static func _shrink_payload(node: Variant, limit: int) -> Variant:
	if node is Dictionary:
		var d: Dictionary = node
		for k in d.keys():
			d[k] = _shrink_payload(d[k], limit)
		return d
	if node is Array:
		var a: Array = node
		for i in range(a.size()):
			a[i] = _shrink_payload(a[i], limit)
		return a
	if node is String and (node as String).length() > limit:
		return "[已截断: 原文 %d 字符, 完整内容见响应 content/text 字段]" % (node as String).length()
	return node


## 构造截断说明文本(计入输出上限之内)。用字符串拼接而非 % 格式化。
## **每条续读建议都必须是该工具真实存在的参数** —— 指向不存在参数的指引比不给指引更糟: 调用方
static func _truncation_notice(tool_name: String, original_len: int, cap: int) -> String:
	return ("\n\n[已截断] 工具 " + tool_name + " 共 " + str(original_len) + " 字符, 超出输出上限 " + str(cap) +
		", 以上为开头部分, 后续内容未发送。\n续读: 缩小范围重试 —— read_file 传 offset=上次返回的 next_char_offset 并调小 limit"
		+ "(单位是字符不是字节); get_logs/get_errors 传 since 用上次返回的 next 或调低 max; get_scene_tree 减小 max_depth"
		+ " 或用 get_node_info 定位子树; classdb_query 用更具体类名; list_dir 关闭 recursive;"
		+ " search_symbols/find_resource_users 调低 max_results。")
