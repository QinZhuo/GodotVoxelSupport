# Task 任务系统 + 新手教程

`Def（.tres 静态配置）→ Entity（运行时推进）`，完全外部驱动：调用方创建并持有任务实体，靠信号推进，无运行器。教程只是任务的特化子类（`TutorialStepDef` 继承 `SignalTaskDef`），流程就是一个普通 `GroupTaskDef`。

## 怎么用

```gdscript
var task := Task.create(task_def)        # 或 task_def.create_entity()
task.completed.connect(_on_done)
task.progress_changed.connect(_on_progress)
task.blocked.connect(_on_blocked)
task.activate(data)                      # data 携带上下文（root 等）
task.get_progress()                       # Vector2i(已完成数, 总数)
var save := task.save_data()
var restored := Task.restore(save, data)
```

| 类 | 用途 |
|---|---|
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成 |
| `CountTaskDef` / `CountTask` | 计数达到 `required` 即完成（`required=1` 退化为信号任务） |
| `GroupTaskDef` / `GroupTask` | `SEQUENTIAL` / `ANY_ORDER` / `COMPLETE_ANY`，内建 `step_entered` |
| `TaskDef` 字段 | `prerequisite`（未满足则 `activate()` 拒绝并保持 INACTIVE、发 `blocked`）/ `skip_if`（激活时已满足 → 直接完成）/ `next: EffectDef`（完成时 `apply`，即奖励） |
| `TaskTool` | `track` / `untrack` / `get_active` / `find` / `save_all` / `load_all` |

## 教程

教程 = 任务流程 + 表现配置。表现**不在**教程模块里，走通用遮罩 `FocusMask` / `FocusMaskTool`：
全场变暗，只有目标亮着且可交互。目标是**画在暗区之上**（重新渲染 / 提升绘制顺序），不存在"抠洞"，
所以目标周围仍然是暗的。

- 步骤 `.tres`：`TutorialStepDef`（`signals` = 完成条件，`targets` = 高亮目标，0..N 个）
- 流程 `.tres`：`GroupTaskDef`，`mode = 0`（SEQUENTIAL）
- 控制器：`TutorialGuide`（把步骤翻译成聚焦表现，自身不绘制）

```gdscript
var guide := TutorialGuide.new()
add_child(guide)
var task := guide.start(TutorialStart, self)                        # 创建 → 激活 → 首次渲染
var task2 := guide.start(TutorialStart, self, {"pause_tree": true}) # 教程期间暂停世界
```

`guide.stop()` 跳过（不触发 `completed`，发 `stopped`）；`step_started` / `step_completed` 供埋点。
遮罩层由 `FocusMaskTool` 自动创建（`UITool.Layer.TOP`，`PROCESS_MODE_ALWAYS`），暂停时仍可拦截。

步骤表现全部自动推导，不需要手工配：

| 步骤配置 | 表现 |
|---|---|
| 有 `targets` | 只有目标可交互，其余变暗（`block_input = false` 可放开操作） |
| 无 `targets` + 有 `signals` | 只弹提示、不遮挡，等外部流程推进（如结算衔接） |
| 无 `targets` + 无 `signals` | 全屏变暗，点任意处 / `advance_action` 继续 |
| `click_to_complete_with_target` | 有目标也允许"点任意处继续"（展示说明类步骤） |
| `silent` | 不显示任何引导，只等信号 |
| `dim = false` | 只弹提示，不画暗区 |

遮罩也能单独用（过场、强制选择、展示高亮），不依赖教程：

```gdscript
FocusMaskTool.focus([$UI/Btn, {"node": $Ball, "padding": 16.0}], {"tip": "点这里继续"})
FocusMaskTool.is_blocking()   # 外部据此禁用快捷键
FocusMaskTool.clear()
```

`FocusMask.screen_rect(node)` 统一换算 2D 控件 / Node2D 精灵 / 3D 模型 / 子视口贴面的屏幕矩形；
`SubViewport` 需挂在 `SubView3D` 之下（贴图面即屏幕区域）。目标每帧重算，动画/缓慢移动的按钮无需手动刷新。

亮起的实现（两种，都不抠洞）：

| 目标 | 做法 |
|---|---|
| 3D（主世界） | 临时挪到 `highlight_layer`（默认 20，需项目没占用）渲染层，一台与主相机逐帧同步的相机只渲染该层，透明底贴图盖在暗区之上 |
| 2D 控件/精灵 | 同 canvas 上除目标祖先链以外全部按 `modulate` 压暗（保留 alpha，透明/不透明背景都不会露色块）；根画布上的目标再靠 `z_index`（4095 > 暗区 4090）提到全屏暗区之上 |
| 子视口里的目标 | 自动升级为承载它的 `SubView3D` 面板（那个世界没法单独重渲染）；面板内部再按上面两条各自处理——2D 用 `modulate`、不透明 3D 用子视口内暗区 + 一层同步相机 |

3D 走重渲染时目标不会被别的几何遮挡（X 光效果，引导场景通常想要的）；`render_3d = false` 则只提绘制层、不开额外通道。
暗区只铺在舞台根（`FocusMaskTool.focus(..., host)`）内，所以层级高于 `FocusMaskTool.layer` 的 UI 不会被压暗。

项目侧需要改气泡时用这几个钩子（不要直接改遮罩内部）：

| 接口 | 用途 |
|---|---|
| `guide.get_mask().tip_placed` | 气泡每次排版完的回调，在这里做二次布局（塞模型、改宽度等） |
| `mask.tip_panel` / `mask.tip_label` | 气泡容器与文字（`Panel` / `RichTextLabel`） |
| `guide.set_tip(text)` / `guide.set_tip_top_limit(y)` | 步骤内换文案 / 纯提示气泡的顶部下限 |
| `mask.tip_min_height` / `mask.refresh_tip()` | 气泡最小高度 / 改完尺寸后强制重排 |
| `guide.blur()` | 临时收起表现（任务与进度保留） |

"亮着"的样子：

- 3D 目标（含子视口目标提升出来的贴图面）走 `FocusMaskLight.gdshader`：用重渲染结果的 alpha 当轮廓，**贴边发光（越靠边越亮）+ 向外溢出的光晕 + 轻微自发光**，所以光完全贴合物体形状（球是圆的、方块是方的），不会出现方框。参数：`rim_color/rim_width/rim_energy/halo_width/halo_energy/inner_boost`。
- 纯 2D 控件没有轮廓贴图，用矩形描边 + 光晕（控件本身是矩形，贴合即可）：`outline_color/outline_width/glow_color/glow_layers`。

主题里可配 `FocusMask/dim_color`、`FocusMask/tip_stylebox`、`FocusMask/tip_font_size`、`FocusMask/outline_color`、`FocusMask/glow_color`。

## 坑

1. 需要存档/还原的任务必须用 `.tres`：运行时 `new()` 的 Def 没有 `resource_path`，存档告警且无法还原。
2. `GroupTask.activate()` **不发** `entity_changed`：手动路径下激活后必须自己调 `guide.show_step(step)`，否则遮罩停在第一步。
3. 纯提示步骤的"点任意处继续"由 `TutorialGuide` 按 `TutorialStepDef.click_to_complete_for` 统一判定，别处不要再 `complete()`；`skip_if` 跳过的步骤视为已达成但不发 `step_completed`。
4. 遮罩全局唯一：`FocusMaskTool` 同时只服务一个聚焦请求，后聚焦的会让前一个的调用方失去高亮（并发引导需自己排队）。
5. 可交互区域是屏幕矩形（3D 目标取可见 mesh 的 AABB 投影），镜头/布局/目标动画动了每帧重算，不需要手动刷新；目标被替换导致失效时按 `node_path` 重新解析。
6. 2D 压暗是改 `modulate`：目标与它祖先链以外的节点都会被乘一层暗色，`clear()` 原值还原。别在教程步骤进行中同时给这些节点做 `modulate` 动画，否则会互相覆盖。
7. 根画布上的 2D 目标靠 `z_index`（`FocusMask.LIFT_Z = 4095`，暗区 `DIM_Z = 4090`）提到全屏暗区之上：目标不能处在 `CanvasGroup` / `clip_children` 裁剪里，否则提层无效。
8. 3D 点亮会临时改目标与场景光源的 `layers`、并多开渲染通道，`clear()` 时全部还原；`highlight_layer` 必须项目没占用。
8. 3D 目标会被"X 光"式点亮（不参与遮挡），需要真实遮挡时用 `render_3d = false`。
9. 每个 `CanvasLayer` 各铺一层暗区，所以 3D 会同时被根画布和 UI 画布的暗区叠两次（比 UI 更暗），这是刻意的层次差。
