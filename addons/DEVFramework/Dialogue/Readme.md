# Dialogue —— 通用对话 / 提示子系统

与 `AI/`、`Camera/` 同构：**Def（数据）/ Entity（运行时）/ View（表现）/ Tool（入口）**。
框架只提供结构与能力，**长什么样由项目决定**。

```
Dialogue/
├─ Def/DialogueLineDef.gd      一行：speaker / text_key / text / hold / meta{}
├─ Def/DialogueScriptDef.gd    一段：lines[] / loop
├─ Entity/DialogueSession.gd   运行实例：游标 + line_changed / finished / cancelled
├─ View/DialogueView.gd   表现基类：present / dismiss / refresh / attach_slot + 锚点与 place_default
├─ View/BubbleView.gd     默认实现：一条圆角气泡（可替换）
└─ Tool/DialogueTool.gd        入口：bind / show / play / next / hide / stop / reset
```

## 三层职责

| 层 | 管什么 | 不管什么 |
|---|---|---|
| `DialogueScriptDef` / `DialogueLineDef` | 说什么（数据、翻译 key、扩展 meta） | 怎么显示 |
| `DialogueSession` | 播到第几行、何时结束（只发信号） | 任何 UI |
| `DialogueView` | 显示成什么样、摆哪里 | 播放顺序 |
| `DialogueTool` | 谁播、推进、停止 | 外观 |

## 三条命令够用

```gdscript
DialogueTool.bind(ui_layer)              # 一次（遮罩会自动 bind，通常不用管）
DialogueTool.show("点这里继续", rect)     # 一条提示（rect 省略 = 屏幕底部）
DialogueTool.next()                      # 推进
```

一段对话：

```gdscript
var session := DialogueTool.play(script, {"actor": player})
DialogueTool.is_playing()
DialogueTool.stop() / DialogueTool.reset()
```

目标在移动：每帧把锚点喂进去（`FocusMask` 已自动做）

```gdscript
DialogueTool.set_anchor(target_rect, view_size)
```

## 换成项目自己的样子

三种方式，从轻到重：

1. **只改样式**：主题 `DialogueBubble/panel`，或设 `BubbleView.style / font_size / font_color / max_width / min_height / padding`。
2. **改默认实现的局部**：继承 `BubbleView`，覆盖 `_build_view()` / `_apply_style()`。
3. **完全自己实现**：
   ```gdscript
   class_name MyDialogueView extends DialogueView
   func present(line, text): ...        # 立绘 / 打字机 / 字幕 / 3D 头顶文字都行
   func dismiss(): ...
   func refresh(): ...                  # 需要自己摆位置时覆盖 place_default()
   func attach_slot(name, node, size): ...
   ```
   然后 `DialogueTool.register(MyDialogueView.new())`，或 `DialogueTool.view_scene = preload("...tscn")`。

## 基类提供的能力

| 能力 | 说明 |
|---|---|
| `set_anchor_rect(rect, view_size)` | 调用方每帧喂"锚在哪"（空 Rect2 = 没有目标） |
| `anchor()` / `view_size()` | 读取当前锚点与屏幕尺寸 |
| `place_default(size)` | 有锚点贴其下方（放不下翻上方），无锚点贴屏幕底部居中；**要别的摆法就覆盖它** |
| `limit_top` | 排版后顶部不得高于该 Y（避开底部按钮栏） |
| `attach_slot(name, node, size)` | 插槽：立绘/模型子视口/按钮；节点归项目所有，框架只腾位置 |
| `placed / shown / dismissed` | 生命周期信号 |

> 没有 placement 枚举——`place_default()` 一行就能覆盖，比配一堆枚举更直接。

## 改这个模块时的两个坑

1. **别用内置成员名**（继承自 `Control` / `RefCounted`，会直接编译失败）：
   | 想用的名字 | 撞到的内置成员 | 改用 |
   |---|---|---|
   | `signal hidden` | `Control.hidden` | `closed` |
   | `set_anchor()` | `Control.set_anchor(Side, float, …)` | `set_anchor_rect()` |
   | `var script` | `RefCounted.script` | `var dialogue` |
2. **改完先跑编译冒烟测试**：`run_tests test_framework_compile`
   （它会全量扫描 `addons/DEVFramework` + `Scripts` 下所有 `.gd`，扫不到死文件；比翻编辑器日志快且准）

## 与遮罩的关系

`FocusMask` **不认识气泡**：它只提供命中区，并把锚点转给 `DialogueTool`。
所以这套可以脱离教程单独用（剧情对话、道具说明、字幕），教程只是"一个使用方"。
