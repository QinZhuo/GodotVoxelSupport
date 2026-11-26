@tool
class_name QVoxelNaming
extends RefCounted
## 落盘命名规则：**用户随手起的名字 → 能安全写进文件系统的名字**。

## 消毒后为空时的兜底名。
const FALLBACK_NAME := "unnamed"

## Windows 上非法或带路径语义的字符（`/` 会被当成子目录，`:` 会被当成数据流）。
const ILLEGAL_CHARS := ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]

## 文件名消毒：**只留下放之四海而皆准的字符**，其余换成下划线。
static func sanitize(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var c := raw[i]
		out += c if _is_legal(c) else "_"
	while out.ends_with(".") or out.ends_with(" "):
		out = out.left(-1)
	return out

## 消毒 + 兜底：出口拼路径时用这个（省掉每个出口各写一次"空了怎么办"）。
static func safe_stem(raw: String) -> String:
	var stem := sanitize(raw)
	return stem if not stem.is_empty() else FALLBACK_NAME

static func _is_legal(c: String) -> bool:
	return c.unicode_at(0) >= 32 and not ILLEGAL_CHARS.has(c)
