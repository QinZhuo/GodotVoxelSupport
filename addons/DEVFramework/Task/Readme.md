# Task 任务 / 教程

任务树（`GroupTaskDef` + 子任务）由 `TaskRunner` 推进，`TutorialGuide` 负责"每步聚焦哪里 + 说什么"。

| 文件 | 职责 |
|---|---|
| `Def/GroupTaskDef` `Def/TutorialStepDef` | 步骤定义：描述、目标、完成条件、`silent` / `click_to_complete` / `dim` |
| `Entity/GroupTask` `Entity/*Task` | 运行时：完成的步骤、`step_entered` / `completed` |
| `View/TutorialGuide` | 控制器：`start` / `show_step` / `stop` / `set_tip` / `blur` |
| `Tool/TaskTool` | 可选基建：任务跟踪表（`track` / `get_active` / `find` / `save_all` / `load_all` / `reset`） |

```gdscript
guide.start(flow_def, host)   # 或 guide.bind_task(task, host)
guide.stop()                  # 结束（emit stopped，项目在此收尾）
```

| `TutorialStepDef` 字段 | 作用 |
|---|---|
| `desc` | 气泡文案（直接交给 Dialogue） |
| 目标 | 有目标 → 只保留它可交互；无目标 + `click_to_complete` → 点任意处继续 |
| `silent` | 不显示任何引导（纯逻辑步骤） |
| `dim` | 是否压暗（纯提示可关） |

`show_step` 只做两件事：让遮罩聚焦目标、把 `desc` 交给 `DialogueTool.show(desc, mask.get_focus_rect())`。气泡长什么样由项目 `DialogueView` 决定。

```gdscript
guide.set_tip("换个说法")     # 步骤内改文案
guide.set_tip_limit(900.0)    # 气泡顶部下限（避开底部按钮栏）
guide.blur()                  # 收起表现，进度保留
```

## 坑

1. 要存档/还原的任务必须用 `.tres`：运行时 `new()` 的 Def 没有 `resource_path`。
2. `GroupTask.activate()` **不发** `entity_changed`：手动路径下激活后要自己调 `guide.show_step(step)`。
3. "点任意处继续"由 `TutorialStepDef.click_to_complete_for` 统一判定，别处不要 `complete()`；`skip_if` 跳过的步骤不发 `step_completed`。
4. 遮罩全局唯一：同时只能服务一个聚焦请求，并发引导需自己排队。
5. 教程中的按键（如 ESC 退出）由项目决定并调 `stop()`；框架不接管任何退出键。
6. Demo：`Scenes/Tutorial/TutorialDemo.tscn`。
