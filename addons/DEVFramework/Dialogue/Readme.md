# Dialogue 对话 / 提示

`Def`（说什么）→ `Entity`（播到第几行）→ `View`（长什么样）。**外观完全由项目决定。**

| 文件 | 职责 |
|---|---|
| `Def/DialogueLineDef` | 一行：`speaker / text_key / text / hold / meta{}` |
| `Def/DialogueScriptDef` | 一段：`lines[] / loop` |
| `Entity/DialogueSession` | 游标 + `line_changed / finished / cancelled` |
| `View/DialogueView` | 表现基类：`show_line / clear / relayout / attach_slot` + 锚点与 `place_default` |
| `View/BubbleView` | 默认气泡（可替换） |
| `Tool/DialogueTool` | 入口：`bind / show / play / next / hide / stop / reset` |

## 三行接入

```gdscript
DialogueTool.bind(ui_layer)          # 一次（遮罩会自动 bind）
DialogueTool.show("点这里继续", rect) # 一条提示；rect 省略 = 贴屏幕底部
DialogueTool.next()                  # 推进
```

一段多行对话：

```gdscript
DialogueTool.play(script)   # 返回 DialogueSession
DialogueTool.next()         # false = 已播完
DialogueTool.stop()
```

目标会移动时，每帧喂锚点（用 `FocusMask` 时它已自动做）：

```gdscript
DialogueTool.set_anchor(target_rect, view_size)
```

## 换成项目自己的样子

| 层级 | 做法 |
|---|---|
| 只改样式 | 主题 `DialogueBubble/panel`；或设 `BubbleView` 的 `style / font_size / font_color / max_width / min_height / padding` |
| 改局部 | 继承 `BubbleView`，覆盖 `_build_view()` / `_apply_style()` / `place_default()` |
| 完全自写 | `class_name MyView extends DialogueView` 后 `DialogueTool.register(MyView.new())`，或 `view_scene = preload("...tscn")` |

基类提供：`set_anchor_rect()` / `anchor()` / `view_size()` / `place_default(size)` / `limit_top` / `attach_slot(name, node, size)` / `detach_slot()`。

## 和遮罩的关系

遮罩负责"哪里亮、能不能点"，对话负责"气泡长什么样"。两者只通过**锚点**相连：

```gdscript
FocusMaskTool.focus(targets, {...})      # 只聚焦，不传文案
DialogueTool.show(text, mask.get_focus_rect())
```

`FocusMask` 的 `opts.tip` 仍可用（内部转给对话），教程已改为直接调 `DialogueTool`。

## Demo

`Scenes/Dialogue/DialogueDemo.tscn` —— 单行 / 多行 / 拖动跟随 / 插槽 / 贴底 / 左上角，全部可点。

## 两个坑

1. `show_line` / `clear` / `relayout` 与内置成员撞名会**直接编译失败**（`script`、`hidden`、`set_anchor` 同理）。改 API 前先跑 `test_framework_compile`。
2. 气泡挂在 `CanvasLayer` 下，拿不到 Control 主题链 → 项目主题要显式传给 `DialogueTool.theme`。
