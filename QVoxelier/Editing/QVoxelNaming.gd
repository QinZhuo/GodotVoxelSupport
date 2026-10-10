@tool
class_name QVoxelNaming
extends RefCounted
## 落盘命名规则：**用户随手起的名字 → 能安全写进文件系统的名字**。
##
## 【为什么单独一层】"名字要消毒"这件事不只 `.vox` 一个出口要（快照的 PNG 也要），
## 而两个出口各写一份消毒规则，迟早一份允许的字符另一份不允许 —— 表现是"有的名字存得下、
## 有的存不下"，且两边都不报错。规则收在这里，出口只管拼名字。
##
## 【为什么消毒必须做】节点的显示名是用户随手打的（`石/头`、`a:b`、`第 3 关`），而 `/` `\` `:`
## 在 Windows 上要么非法、要么带语义（`/` 会被当成子目录），直接拿去拼路径会写到别处或直接失败。
## 中文与空格**保留** —— 它们是合法字符，而且正是用户想看到的名字。
##
## 【为什么结尾的点与空格要去掉】Windows 会**悄悄**吃掉它们，于是"写出去的名字"与
## "清单里回显的名字"对不上，用户按清单去找文件会找不到。


## 消毒后为空时的兜底名。空名拼出的路径会落在目录自身（Windows 直接失败），
## 故不能任由它空着；兜底名由本类给出，各出口不再各自硬编码一个字面量。
const FALLBACK_NAME := "unnamed"

## Windows 上非法或带路径语义的字符（`/` 会被当成子目录，`:` 会被当成数据流）。
const ILLEGAL_CHARS := ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]


## 文件名消毒：**只留下放之四海而皆准的字符**，其余换成下划线。
## 返回空串是合法结果（调用方用 FALLBACK_NAME 兜底），不在这里悄悄改名 ——
## "用户给的名字被换成了别的名字"是比"空"更让人意外的行为。
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
