# Changelog 更新日志

把"这一版改了什么"做成 Def 数据（版本 / 日期 / 分类 / 正文），由工具侧算出"有没有新内容要看"。
版本号是点分字符串，比较交给 `SaveTool.is_version_newer`；"已读到哪个版本"是进程级静态状态，落存档请自己带。

| 类 | 职责 |
|---|---|
| `ChangelogDef` | Def：`entries: Array[ChangelogEntryDef]`，`get_max_version()` 取最高版本 |
| `ChangelogEntryDef` | Resource：单条记录，`version` / `date` / `category` / `text` / `target` / `debug_only` |
| `ChangelogTool` | 纯 static：当前版本、待看条目、已读标记 |

`ChangelogEntryDef.Category`：`NEW`（新增玩法）、`IMPROVE`（优化调整）、`FIX`（修复）、`EVENT`（活动）。
`ChangelogTool.is_debug_mode()` 转调 `DebugTool.is_debug_mode()`，决定 `debug_only` 条目是否出现。

```gdscript
if ChangelogTool.has_update():
	for e in ChangelogTool.get_pending_entries():   # 按版本从新到旧
		print(e.version, " [", e.category, "] ", e.text)
	ChangelogTool.mark_seen()                        # 不传参则记为当前版本

var cur := ChangelogTool.get_current_version()    # 项目设置 application/config/version，空则取 Def 最高版本
ChangelogTool.load_seen_version(save_data.get("seen_version", ""))   # 读档回填
ChangelogTool.reset_seen_version()                                   # 清成空串，等于全量未读
```

| 条目字段 | 说明 |
|---|---|
| `version` | 点分版本串，如 `"0.5.0"` |
| `date` | 纯展示文本，不参与比较 |
| `category` | 见上面的 Category |
| `text` | `@export_multiline` 正文 |
| `target` | 可选的关联资源（做"点击跳转"用） |
| `debug_only` | 为 true 时只在 Debug 模式下出现 |

## 坑

1. `ChangelogEntryDef` 继承的是 `Resource` 而不是 `Def`：不参与 Def 扫描，只作为 `ChangelogDef` 的子资源存在。
2. 是否展示由三件事共同决定：`version` 非空、`debug_only` 为 false（或处于 Debug 模式）、且"已读版本 < 版本 <= 当前版本"。不改项目设置 `application/config/version` 时 `get_current_version()` 回退到 Def 最高版本，条目一写进去就算已发布。
3. 版本比较按点分段、段数不足补 0（`"1.0"` 与 `"1.0.0"` 相等），任一侧为空返回 0，非数字段被 `int()` 当 0；`date` 完全不参与排序与判定。
4. "已读"是进程级 `static var _seen_version`，重启或切档要自己 `load_seen_version()` 回填；它登记的是 `## Reset: 进程级（内容缓存）` 豁免，要清就显式调 `reset_seen_version()`。
5. 每次查询都会重新 `SaveTool.load_defs` 扫 `Def.DEFS_BASE` 下的 `ChangelogDef`，没有内容级缓存；别放进每帧的 UI 刷新里。
6. 命名约定：新工具别起 `reset_state`，`Resource` 基类已有同名核心方法会被抢占。
