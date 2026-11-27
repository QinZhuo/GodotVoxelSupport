# Translation 运行时语言表与编辑器 CSV 翻译

游戏侧用 `TranslationTool` 从 `*.translation` 挑语言、切语言；编辑器侧用 `EditorTranslationTool` 直接读 CSV，把 Def 的名字与描述翻成当前编辑器语言。
CSV 是数据源（第一列 `id`，其余每列一个 locale），Godot 导入时按列生成各语言的 `.translation`，运行时只认后者。

| 类 | 职责 |
|---|---|
| `TranslationTool` | 运行时：`initialize` / `get_locales` / `get_current_locale` / `set_locale` / `get_display_name` |
| `EditorTranslationTool` | 仅编辑器（`@tool`）：`editor_settings` / `editor_locale` / `editor_text` / `editor_text_for` / `clear_cache` |
| `CSVDataAccess` | 读写 CSV：`load_csv_data` / `save_csv_data` / `set_translation_value` / `apply_translation` |

```gdscript
TranslationTool.initialize()                       # 启动调一次：扫描 + 按 OS.get_locale() 选最佳 + set_locale
for locale in TranslationTool.get_locales():       # 已排序的 locale 代码
	print(locale, " -> ", TranslationTool.get_display_name(locale))
TranslationTool.set_locale(locale)                 # 切语言（不会重新扫描目录）

@tool
extends Node
func _ready() -> void:
	name = EditorTranslationTool.editor_text(TranslationTool.TRANSLATION_DIR, "some_id")
	EditorTranslationTool.clear_cache()            # 改完 CSV 后清缓存
```

| CSV 约定 | 说明 |
|---|---|
| 目录 | `TranslationTool.TRANSLATION_DIR`（`res://Assets/Translation/`）；`Def.csv_path("some")` 拼成 `some.csv` |
| 第一列 | 必须是 `id`，同一文件内唯一 |
| 其余列 | 列名就是 locale 代码（`zh` / `zh_Hant` / `en` …），一行一条文本 |
| 与 Def 的关系 | `Def.get_csv_path()` 默认按类名去掉 `Def` 后缀转 snake_case 决定文件名 |

```gdscript
var csv := TranslationTool.TRANSLATION_DIR.path_join("some.csv")
CSVDataAccess.set_translation_value(csv, "some_id", "en", "Text")
CSVDataAccess.apply_translation(csv, "en")        # 重载 CSV 后再重设语言
```

## 坑

1. 一切都不自动刷新：改 CSV 后必须重载（`apply_translation` 先以 `CACHE_MODE_REPLACE` 重载 csv 再重设语言）或让编辑器重新导入；`set_locale()` 只换表不重新扫描，进程启动后新加的翻译文件看不到。
2. `_scan()` 只认目录里的 `*.translation`，不读 CSV；文件名约定 `<名>.<locale>.translation`——去掉扩展名后取第一个 `.` 之后的部分当 locale，中间再带点会被截断。
3. locale 不匹配不报错：`_best_match` 依次走 standardize_locale → 精确 → 主语言 → zh 的 tw/hk/mo 特判到含 hant 的列 → compare_locales 打分取最高，只有 locale 为空或语言表为空时才返回 `"en"`；给一个表里没有的 locale，只把内部 `_active` 改成它、不加载任何翻译。语言表为空时 `initialize()` 会 push_error 后返回。
4. 两份缓存各管一边：游戏进程的 `TranslationTool` 与编辑器进程的 `EditorTranslationTool` 互不相干，各持一份 static 状态；编辑器里改完要 `clear_cache()`，运行期要 `set_locale()` 或重开进程。
5. Def 的翻译只在编辑器里写回 CSV：`Def._set_tr_name` 走 `set_translation_value` + `apply_translation`，运行时改被导出的 Def 字段不会回写；`editor_locale()` 只在编辑器语言设为 auto 时回退 `OS.get_locale()`。
