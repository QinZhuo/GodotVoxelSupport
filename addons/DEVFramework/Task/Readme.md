# Task 任务系统 + 新手教程（Tutorial）

DEV Framework 的**任务系统**：`Def（静态配置 .tres）→ Entity（运行时推进）`，完全外部驱动 —— 无运行器、无隐式生命周期，调用方创建并持有任务实体，靠信号推进。
**新手教程是任务系统的一个"特化子类"**：整体完全复用任务引擎（完成判定 / 流程 / 序列化），只在其上增加「步骤表现」与「引导视图」两个特化组件。教程不是另一个系统，也不是脱离任务的表现层。

**依赖方向（单向）**：任务包（Entity / Def / GroupTask 等）**绝不引用任何** **`Tutorial*`** **类型**；只有教程包（TutorialStepDef / TutorialGuide）依赖任务包。

***

## 一、任务系统核心（教程的地基）

| 类                              | 角色                                                                                       |
| ------------------------------ | ---------------------------------------------------------------------------------------- |
| `TaskDef`                      | 任务定义基类（抽象）：状态枚举 / 前置条件 `prerequisite` / 完成动作 `next`                                      |
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成                                                                                |
| `CountTaskDef` / `CountTask`   | 计数目标：信号累加计数，达到 `required` 即完成（"击杀 5 只怪"）                                                 |
| `GroupTaskDef` / `GroupTask`   | 子任务编排：`SEQUENTIAL`(顺序) / `ANY_ORDER`(任意全完) / `COMPLETE_ANY`(任一即完)；自带 `step_entered` 逐步信号 |

**状态机**：`INACTIVE → ACTIVE → COMPLETED / FAILED / CANCELLED`（终态不可再激活）。
`complete()/fail()/cancel()` 由外部或派生逻辑调用；`status` 只读，配套 `is_active` / `is_completed` / `is_terminal`。

```gdscript
var task := Task.create(task_def)   # 或 task_def.create_entity()
task.completed.connect(_on_done)
task.progress_changed.connect(_on_progress)   # 进度变化（步骤推进/计数累加）
task.activate(data)                # data 携带信号解析上下文（root 等）
task.get_progress()                # Vector2i(已完成数, 总数)；计数任务为 (当前, required)

var save := task.save_data()                   # 存档（Def 相对路径 + 状态 + 子进度）
var restored := Task.restore(save, data)       # 断点续玩：一步重建并激活到存档进度
```

### 完成动作与前置条件

```gdscript
# .tres 上配置（均为可选，缺省不启用）
@export var prerequisite: ConditionDef     # 未满足时 activate() 拒绝激活（保持 INACTIVE，发 blocked）
@export var skip_if: ConditionDef          # 激活时已满足 → 视为"已达成"直接完成并推进（门控跳过）
@export var next: EffectDef                # 任务完成时执行的操作(apply(context))，也是任务奖励
```

```gdscript
task.blocked.connect(_on_blocked)          # 前置未满足 → 点亮入口/提示玩家
task.activate(ctx)                          # ctx 同时作为条件判定与奖励发放的上下文
```

**`skip_if`** **的两个典型用途**：

- 教程"老玩家跳过"：前 3 步各配 `skip_if = 玩家等级 >= N`，激活流程时被满足的步骤直接完成并级联推进。

- 任务"已有存货"：`CountTaskDef.required = 3` + `skip_if = 背包数量 >= 3`，接任务时即刻完成。

- 配在 `GroupTaskDef` 上 = **整组跳过**（子任务静默标记完成，不执行子任务 `next`）；配在叶子步骤上则正常走 `completed`/执行 `next`。

> 与 `prerequisite` 的区别：`prerequisite` 是"没准备好就先不开始"（阻塞，发 `blocked`）；`skip_if` 是"已经做到了就直接算完成"（跳过）。需要"按玩家状态走不同流程"时优先用**入口分流**（`if 条件: start(流程A) else: start(流程B)` / `Task.restore`），不要把分支逻辑堆进步骤。

### 计数目标（进度型）

```gdscript
var def := CountTaskDef.new()
def.required = 5                            # 目标数量（required=1 时退化为普通信号任务）
def.signals = [node_sig]                    # 计数信号：任一触发 +1
def.signals = [cond_sig]                    # 或配 ConditionSignalDef → 只统计满足条件的触发
```

### 任务跟踪表（可选基建）

```gdscript
TaskTool.track(task)                # 显式注册（框架不做隐式生命周期）；终态自动转入 finished
TaskTool.get_active()               # 活动列表（任务日志 UI 数据源）
TaskTool.find("Tutorial/xxx.tres")  # 按 Def 相对路径查找
var saved := TaskTool.save_all()    # 聚合存档 {def_key: save_data}
var tasks := TaskTool.load_all(saved, ctx)   # 聚合读档并重新注册
TaskTool.untrack(task)              # 场景销毁时注销（静态表持有强引用）
```

> **存档前提**：`Def` 必须有 `resource_path`（即存成 `.tres` 文件）。运行时 `XxxDef.new()` 出来的内置 Def 没有路径，存档时会告警且无法还原 —— 需要持久化的任务请一律用 `.tres` 配置。
>
> `Task.restore(dict, data)` 的 `data` 可省略：省略时只恢复数据不激活，之后调 `task.activate(data)` 会从存档进度继续（不重跑已完成步骤）。
>
> 信号源（`SignalDef` 家族）：`NodeSignalDef` 订阅任意节点具名信号（如 `Button.pressed`）；`ConditionSignalDef` 带条件过滤（条件基于 activate 传入的上下文求值，信号实参原样转发）。

## 二、教程 = 任务的"特化子类"

| 文件                         | 角色                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `Def/TutorialStepDef.gd`   | **步骤定义**：继承 `SignalTaskDef`，额外携带表现字段（target/拦截）；完成语义（resolve\_target / has\_signals / click\_to\_complete）归口于此      |
| `Def/TutorialTargetDef.gd` | 目标换算：把 Control / Node2D / Node3D → 统一屏幕矩形                                                                           |
| `View/TutorialGuide.gd`    | **教程控制器**：直接订阅 `GroupTask` 的逐步信号（step\_entered/child\_completed/completed），步骤进入→渲染表现、纯提示点击→判定完成。一个类完成"推进+表现"，无中间转发器 |
| `Scenes/Tutorial/`         | 演示场景（含 `ClickableBall.gd` 自发光点击信号范式）                                                                                |

**设计要点**：教程流程就是一个普通 `GroupTaskDef`（步骤为 `TutorialStepDef`）。何时完成完全由 Task 系统信号驱动；`GroupTask` 自内建 `step_entered` 逐步信号，`TutorialGuide` 直接订阅它渲染表现并推进。层级单向：任务包 ← 教程包。

### 快速上手（三步）

1. **配步骤**：每个步骤一个 `.tres`（`TutorialStepDef`，含完成信号 + 表现）

```gdscript
# res://Assets/Def/Tutorial/Step_Welcome.tres （节选）
[resource]
script = ExtResource("1_step")                       # TutorialStepDef
signals = Array[SignalDef]([SubResource("sig")])     # NodeSignalDef → Button.pressed
target = SubResource("target")                       # TutorialTargetDef → node_path = UI/StartButton
# 提示文字走统一 desc 翻译: Assets/Translation/task.csv 中 步骤名_desc(如 Step_Welcome_desc)
```

> 翻译表格式（`Assets/Translation/task.csv` 供编辑器写入；运行时由 Godot CSV 导入器自动生成 `task.zh.translation` 并调 `TranslationTool.initialize()` 加载，内容支持 BBCode）：
>
> ```
> keys,zh
> Step_Welcome_desc,欢迎！请点击[color=#ffd140]开始游戏[/color]按钮。
> Step_ClickBall_desc,现在点击[color=#ffd140]蓝色球体[/color]！
> ```
>
> `.translation` 由 CSV 导入器自动生成（`task.zh.translation`），**不要手写同名翻译文件**——否则同键会被重复注册，且手写那份不会随 CSV 更新而漂移失效。

1. **配流程**：一个 `.tres`（`GroupTaskDef`，步骤按序引用）

```gdscript
[resource]
script = ExtResource("1_flow")                       # GroupTaskDef
tasks = Array[TaskDef]([步骤1, 步骤2, ...])
mode = 0                                             # SEQUENTIAL
```

1. **代码启动**（两选一）：

**便捷路径**（一行）：

```gdscript
var layer := CanvasLayer.new(); layer.layer = 100; add_child(layer)
var guide := TutorialOverlay.new()
guide.set_anchors_preset(Control.PRESET_FULL_RECT)
guide.theme = my_theme                    # 可选：主题定制
layer.add_child(guide)
var task := guide.start(TutorialStart, self)   # ← 一行启动，内部完成桥接 + 首次渲染
task.completed.connect(_on_completed)
```

> `guide.start(flow, host, {pause_tree: bool})` 内部完成「创建任务→连 entity\_changed/completed→activate→首次渲染」，完成后自动 `blur`；返回 `GroupTask` 供外部连接/存档。
> 配套：`guide.stop()` 提前结束/跳过（停用任务 + blur + 恢复暂停，不触发 completed，发 `stopped`）；`guide.step_started` 每进入一步发一次（绑步骤 UI/进度条/播音频），`guide.step_completed` 每完成一步发一次（埋点）。

**手动路径**（完全外部驱动，等价）：

```gdscript
var task := TutorialStart.create_entity() as GroupTask
task.entity_changed.connect(_on_task_changed)
task.completed.connect(_on_completed)
task.activate({"root": self})
_on_task_changed()                      # activate 不触发 entity_changed，需手动首次渲染

func _on_task_changed() -> void:
	if task.is_completed:
		guide.blur()                    # 完成时也会触发一次 entity_changed
		return
	var step := task.active_child_entity
	if step and not step.is_completed:
		guide.show_step(step, self)     # 渲染当前步骤（挖孔/箭头/提示）
```

## 三、配置详解

### TutorialStepDef（继承 SignalTaskDef）

| 字段                          | 说明                                                                                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `signals`                   | （继承）完成信号，任一触发即完成本步骤                                                                                                                                                                              |
| `target: TutorialTargetDef` | 高亮目标；**有 target 即自动遮挡目标外输入**（遮罩挖孔，完成靠目标自身交互/信号）；空 = 纯提示步骤（不挖孔，自动"点任意处继续"）                                                                                                                        |
| （完成语义方法）                    | `resolve_target(host)` / `has_signals()` / `click_to_complete(host)` / `click_to_complete_for(has_target)` —— 三态完成方式（有 target 靠交互、无 target 有信号等信号、无 target 无信号点任意处）全部**归口到本 Def**，表现层与驱动共用，不各自推导 |
| （无提示字段）                     | 提示文字复用 TaskDef 统一 desc 翻译 `tr(名称_desc)`（见上方翻译表）；纯提示气泡位置统一由 Guide 贴底铺满（可经 `set_tip_top_limit` 限制顶部），不再配置自定义位置                                                                                     |

### TutorialTargetDef（2D/3D 通用）

| 字段                                 | 说明                                                                                  |
| ---------------------------------- | ----------------------------------------------------------------------------------- |
| `node_path: NodePath`              | 目标节点（相对教程宿主 root）                                                                   |
| `padding: float = 8`               | 挖孔外扩像素（挖孔 = 目标视觉体量 + padding）                                                       |
| `arrow: bool = true`               | 显示指示箭头                                                                              |
| `allow_outside_drag: bool = false` | 放行孔外按下（拖拽类步骤：目标可能超出挖孔，需放行按下才能起拖）。每步进入时自动带入 `TutorialGuide.allow_hand_drag`，运行期也可手动改 |

屏幕矩形换算规则：

- **Control / Node2D**：合并**自身及可见子级**的画布矩形（Control 含所有后代 Control，Node2D 含后代 `Sprite2D`/`Control`）；无任何体量时退化为投影原点，尺寸由 `padding` 兜底外扩

  > **多目标同框不需要新功能**：把 `node_path` 指向这些目标的**共同父节点**即可（挖孔 = 父节点及其可见子级的并集）。

- **Node3D**：可见 mesh 世界 AABB 合并投影（相机背后隐藏；极小/极远目标退化为投影点，尺寸由 `padding` 兜底外扩）

- 箭头**默认置于挖孔上方**指向目标，顶部放不下才翻到下方兜底；提示气泡始终在箭头尾端外侧（默认上方），固定不随目标左右偏移/浮动；`arrow=false` 时不画箭头，气泡置于孔下方；纯提示（无孔）气泡横向铺满、贴屏幕底部显示（可经 `set_tip_top_limit` 限制顶部不遮住目标）

### TutorialGuide 主题（命名空间 `"TutorialGuide"`）

| 主题项                                | 类型        | 控制     |
| ---------------------------------- | --------- | ------ |
| `dim_color`                        | Color     | 遮罩暗色   |
| `frame_stylebox`                   | StyleBox  | 挖孔边框   |
| `arrow_color`                      | Color     | 指示箭头   |
| `arrow_size`                       | int       | 箭头长度   |
| `tip_stylebox`                     | StyleBox  | 提示气泡面板 |
| `tip_font_color` / `tip_font_size` | Color/int | 气泡文字   |

```gdscript
var theme := Theme.new()
theme.set_color("dim_color", "TutorialGuide", Color(0, 0, 0.08, 0.62))
theme.set_stylebox("frame_stylebox", "TutorialGuide", my_frame_box)
guide.theme = theme   # 或 ThemeTypeVariation / 项目全局主题
```

## 四、常见用法

**纯提示步骤"点任意处继续"（自动）**：无 `target` 且无 `signals` 的步骤，点任意处/按继续键 → `TutorialGuide` 依据 `TutorialStepDef.click_to_complete` 判定并完成当前步骤。宿主无需转发，也无重复完成的隐患。

> 有 `target` 的步骤完成靠目标自身交互/信号；无 `target` 但配了 `signals` 的"等待信号"步骤不遮罩、也不点击完成。

**拖拽类步骤**（目标/可拖物可能超出挖孔）：

```gdscript
# 配置式：该步骤的 TutorialTargetDef 勾 allow_outside_drag 即可
# 运行式：或由代码注入"当前是否正在拖拽"的判定，拖拽期间 Guide 放行全部指针事件
guide.drag_checker = func(): return MyDragManager.is_dragging
```

> 框架不认识任何具体拖拽实现：命中判定走鸭子类型（射线命中节点或其祖先带 `is_dragging` 属性即视为可拖），"是否正在拖拽"由 `drag_checker` 注入。

**3D 可点击物体（语义归节点自己，信号 Def 只订阅）** —— 参照 `Scenes/Tutorial/ClickableBall.gd`：

```gdscript
class_name ClickableBall extends Area3D
signal clicked
func _ready() -> void:
	input_event.connect(func(_c, e, _p, _n, _s):
		var press := e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
				or e is InputEventScreenTouch and e.pressed
		if press: clicked.emit())
```

**暂停世界播放**（遮罩/箭头仍每帧刷新）：

```gdscript
task.activate({"root": self})
get_tree().paused = true
guide.process_mode = Node.PROCESS_MODE_ALWAYS
task.completed.connect(func(): get_tree().paused = false)
```

**跳过/存档**：

```gdscript
guide.stop()                             # 一键跳过整个教程（Guide 自动停用任务+blur）
# 或仅跳过当前步骤：
task.active_child_entity.complete()
var data := task.save_data()                    # 进度存档（含子步骤）
var same_task := Task.restore(data, {"root": host})  # 断点续玩：重建并激活到存档进度
```

**自定义外观**：继承 `TutorialGuide` 重写 `_draw`（`_draw_dim/_draw_arrow`），或改造 `focus()/show_step()` 触发的表现；流程/完成逻辑无需改动。

### 键盘 / 手柄与可访问性（走 Godot 焦点系统）

框架不自建焦点导航 —— 有 `target` 的步骤进入时会把焦点移交给目标控件（仅当其 `focus_mode != FOCUS_NONE`），方向键导航、手柄摇杆、Enter 激活全部由 Godot 内置焦点系统承担：

```gdscript
btn.focus_mode = Control.FOCUS_ALL   # 目标控件可聚焦即可，Guide 会 grab_focus()
```

纯提示步骤（无 target）额外支持"按继续键推进"，默认映射引擎预定义动作 `ui_accept`（Enter/空格/手柄 A）：

```gdscript
guide.advance_action = &"ui_accept"   # 或自定义 InputMap 动作；置 &"" 则仅响应指针
```

> 有 `target` 的步骤不消费继续键 —— 完成靠目标自身交互（Enter 会激活已聚焦的目标按钮），避免双重推进。

### 漏斗埋点（步骤级事件）

```gdscript
guide.step_started.connect(func(s): Analytics.event("tutorial_step_start", s.def.name))
guide.step_completed.connect(func(s): Analytics.event("tutorial_step_done", s.def.name))
guide.stopped.connect(func(): Analytics.event("tutorial_abandoned"))
task.child_completed.connect(func(i, child): pass)   # 通用任务也可用（GroupTask 信号）
```

> `skip_if` 命中被跳过的步骤视为"已达成"，**不发** `step_completed`（埋点上不计入完成漏斗）。

### 目标不在屏内：交给项目层，不进框架

框架不认识镜头。需要"引导时自动把目标滚进画面"时，在项目层监听 `step_started` 自行处理：

```gdscript
guide.step_started.connect(func(step):
	var def := step.def as TutorialStepDef
	var target := def.target.resolve(host) if def and def.target else null
	if target == null or TutorialTargetDef.get_screen_rect(target).size == Vector2.ZERO:
		CameraTool.impulse(...)  # 或临时推一个对准目标的 vcam 机位
)
```

同理，边框呼吸/脉冲动画未内置 —— 它会抵消 Guide 的每帧重绘缓存优化，确有需要再做成默认关闭的开关。

## 五、最佳实践

1. **完成信号由目标节点自己发**（`pressed`/`clicked` 等），`NodeSignalDef` 只做订阅 —— 不替节点过滤输入流。
2. **教程即任务**：`TutorialStepDef` 是 `SignalTaskDef` 子类，可独立复用为普通任务；同一条流程去掉表现字段就是通用任务树。
3. **首次渲染手动调用**：`GroupTask.activate()` 不发射 `entity_changed`，激活后需手动 `guide.show_step(...)`，否则 Guide 停在模糊态遮挡全部点击（走 `guide.start()/bind_task()` 无此问题）。
4. **要存档就用** **`.tres`**：运行时 `new()` 出来的 Def 没有 `resource_path`，存不下也还原不了。
5. **完成统一由** **`TutorialOverlay`** **判定，不要在别处** **`complete()`**：纯提示步骤的点击完成由 TutorialOverlay 统一判定执行；外部再手动 `complete()` 会有重复推进/时序错乱风险。
6. **分支优先用入口分流，其次** **`skip_if`**：不要试图在流程内部建分支图。
7. 演示场景：`res://Scenes/Tutorial/TutorialDemo.tscn`（UI 按钮 + 3D 球体两步流程，含 `progress_changed` 进度显示）。

