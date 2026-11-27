# Dialogue 对话 / 提示

`Def`（说什么）→ `Entity`（播到第几行）→ `View`（长什么样）。外观完全由项目决定。

| 文件 | 职责 |
|---|---|
| `Def/DialogueLineDef` | 一行：`speaker / text_key / text / hold / meta{}` |
| `Def/DialogueScriptDef` | 一段：`lines[] / loop` |
| `Entity/DialogueSession` | 游标 + `line_changed / finished / cancelled` |
| `View/DialogueView` | 表现基类：`present / dismiss / refresh / attach_slot` + `set_anchor_rect` / `place_default` |
| `View/BubbleView` | 默认气泡（可替换） |
| `Tool/DialogueTool` | 入口：`bind / register / show / set_anchor / play / next / hide / stop / reset` |

```gdscript
DialogueTool.bind(ui_layer)          # 一次（遮罩会自动 bind）
DialogueTool.show("点这里继续", rect) # 一条提示；rect 省略 = 贴屏幕底部
DialogueTool.next()                  # 推进

var session := DialogueTool.play(script)   # 一段多行
DialogueTool.stop()

DialogueTool.set_anchor(target_rect, view_size)   # 目标会移动时每帧喂锚点（FocusMask 已自动做）
```

## 换成项目自己的样子

| 层级 | 做法 |
|---|---|
| 只改样式 | 主题 `DialogueBubble/panel`；或设 `BubbleView` 的 `style / font_size / font_color / max_width / min_height / padding` |
| 改局部 | 继承 `BubbleView`，覆盖 `_build_view()` / `_apply_style()` / `place_default()` |
| 完全自写 | `class_name MyView extends DialogueView` 后 `DialogueTool.register(MyView.new())`，或 `view_scene = preload("...tscn")` |

基类提供：`set_anchor_rect()` / `anchor()` / `view_size()` / `place_default(size)` / `limit_top` / `attach_slot(name, node, size)` / `detach_slot()`。

## 和遮罩的关系

遮罩负责"哪里亮、能不能点"，对话负责"气泡长什么样"，两者只通过**锚点**相连：

```gdscript
FocusMaskTool.focus(targets, {...})      # 只聚焦，不传文案
DialogueTool.show(text, mask.get_focus_rect())
```

`opts.tip` 仍可用（内部转给对话）。Demo：`Scenes/Dialogue/DialogueDemo.tscn`。

## 坑

1. 覆写 `present` / `dismiss` / `refresh` 时不要用会撞内置成员的名字（`script`、`hidden`、`set_anchor` 等），`class_name` 与内置成员同名会**直接编译失败**。改 API 前先跑 `test_framework_compile`。
2. 气泡挂在 `CanvasLayer` 下拿不到 Control 主题链 → 项目主题要显式传给 `DialogueTool.theme`。
