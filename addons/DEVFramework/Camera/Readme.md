# Camera 虚拟机位模块

一套 **机位（VirtualCamera3D） + 大脑（CameraBrain3D）** 的 3D 镜头管理方案，思路对齐 Unity Cinemachine：
场景里摆若干「机位」只描述想要的取景，场景中唯一的真实相机（Brain）每帧挑出生效机位并平滑混合过去。

```
VirtualCamera3D × N   ──(优先级竞争)──▶  CameraBrain3D(真实 Camera3D)
   取景 / 过渡 / 跟随 / 死区 / 手持抖动       混合 + 叠加偏移 + 冲击 → 写 transform
```

---

## 一、三分钟上手

1. 场景里放一个 `Camera3D` 并挂 `CameraBrain3D` 脚本（需要自定义相机时也可继承它，例如叠加鼠标跟随）。
2. 需要几个取景就放几个 `Node3D` 挂 `VirtualCamera3D`，在 3D 视图里摆好位置角度（有视锥 gizmo 可视化；也可用 Inspector 的 **对齐到编辑器视角** 按钮一键抓取当前视角）。
3. 让机位生效：

```gdscript
vcam.set_active(true)        # 参与竞争（场景信号可直连: on_opened → set_active(bind true)）
vcam.activate(0.5)           # 代码切换, 本次过渡 0.5 秒
vcam.deactivate()            # 退出竞争, 自动回落到上一个仍激活的机位
CameraTool.activate(vcam)    # 等价的静态入口
```

**竞争规则**：`priority` 大者胜；同优先级时**最后激活者**胜。因此「打开面板 → 激活面板机位；关闭面板 → 取消激活」天然构成机位栈，无需保存/恢复现场。

---

## 二、机位（VirtualCamera3D）

| 分组 | 属性 | 说明 |
|---|---|---|
| — | `active` | 是否参与竞争（参与 ≠ 生效） |
| — | `priority` | 优先级，越大越优先；同级取最后激活者 |
| 过渡 | `blend_time` | 切到本机位的过渡时长；`< 0` 用 Brain 的 `default_blend_time` |
| 过渡 | `blend_trans` / `blend_ease` | Tween 曲线与缓动（默认 CUBIC / IN_OUT） |
| 过渡 | `blend_style` | 位置轨迹（枚举归属 `CameraTool.BlendStyle`）：`LINEAR` 直线 / `SPHERICAL` 绕枢纽点球面弧线（默认）/ `CYLINDRICAL` 柱面 |
| 镜头 | `lens_fov` | `> 0` 时覆盖 Brain 的视场角，混合期间一起插值；`0` 表示不覆盖 |
| 目标与行为 | `target` | 行为的目标节点（直接拖）；固定取景的机位留空 |
| 目标与行为 | `behaviors` | 决定机位如何根据 `target` 算姿态（含手持抖动），见 [行为资源](#三行为资源camerabehaviordef) |
| 性能 | `standby_update` | 未生效时的更新策略，见 [待机策略](#待机策略standby_update) |

信号：

| 信号 | 触发时机 |
|---|---|
| `active_changed(value)` | 是否参与竞争发生变化 |
| `current_changed(value)` | 是否成为生效机位（Brain 切换瞬间） |

静态成员：`VirtualCamera3D.current`（当前生效机位，**带缓存**，竞争关系变化时才重算）、
`VirtualCamera3D.active_cameras`（竞争中的机位，按激活先后）。

主要方法：`set_active` / `activate(blend)` / `deactivate` / `get_pose()`（基础姿态 + 手持抖动，不写回节点）/ `snap_pose()`。

> 跟随/朝向只在**运行时**驱动，编辑器内不写 transform，避免污染场景。
> 使用 `look_at_*` 时机位不要挂在带缩放的父节点下；机位也不要挂成 Brain 的子节点（会形成"相机跟机位、机位跟相机"的反馈循环）。
> 没有任何机位激活时 Brain 不接管相机，transform 交回场景自行控制。

### 死区与软区

纯阻尼跟随的问题是：目标**任何**微小移动相机都会跟着飘，且永远滞后。死区解决这一点：

- 目标在 `dead_zone`（半尺寸，机位局部空间）内 → 相机**完全不动**；
- 越出死区后，在 `soft_zone` 厚度内按「超出量 / 软区厚度」成比例追赶；
- 超出软区则全速追（由 `damping` 控制平滑）。

死区在**机位局部空间**计算，等价于"屏幕上的取景框"，因此会随镜头朝向一起转。
以上参数都在 `FollowBehaviorDef` 资源里。

### 待机策略（standby_update）

未生效（Standby）的机位是否继续跟随目标，是开销与冷启动的权衡（对齐 Cinemachine 的 Standby Update）：

| 策略 | 行为 | 适用 |
|---|---|---|
| `ALWAYS` | 每帧都更新，上台即就位 | 少量机位、或切换必须无缝 |
| `ROUND_ROBIN`（默认） | 待命机位**轮流**每帧更新一个 | 机位较多时的折中 |
| `NEVER` | 只有生效时才更新 | 最省 CPU |

无论哪种策略，机位上台瞬间都会先 `snap_pose()` 对齐一次，不会出现"从旧姿态飘过来"。

---

## 三、行为资源（CameraBehaviorDef）

机位**默认就是固定取景**——不挂行为时 Inspector 只有「竞争 / 过渡 / 镜头 / 性能」几项，非常干净。
需要动态取景时才在 `behaviors` 里挂资源。这是本模块唯一的扩展点，设计上刻意保持窄：

```
VirtualCamera3D.target ──▶ behaviors 依次 apply() ──▶ 机位姿态 ──▶ 依次 apply_offset() ──▶ get_pose()
                              (写节点: 决定机位在哪)              (不写节点: 只修饰输出画面)
```

- `target` 是**节点引用**（在机位上直接拖，符合 Godot 原生体验）；
- `behaviors` 是**资源**数组：算法与参数的载体，可跨机位复用，也能继承自定义；
- 两者职责分明：目标属于场景（机位持有），算法属于配置（资源持有）。

内置三个：

| 资源 | 作用 | 关键参数 |
|---|---|---|
| `FollowBehaviorDef` | 跟随目标位置 | `offset`、`use_target_basis`、`damping`（**按轴** `Vector3`）、`dead_zone`、`soft_zone` |
| `LookAtBehaviorDef` | 始终瞄准目标 | `offset`、`damping`、`up`（奇异时自动改用相机右轴） |
| `NoiseBehaviorDef` | 常驻手持抖动 | `position_amplitude`、`rotation_amplitude`、`frequency`、`noise`（Godot 原生 `Noise`，留空用默认 Perlin） |

### 为什么叫 `Def` 却不继承 `Def`

沿用框架既有约定（与 `TownStepDef`、`TileDef`、`PlacementDef` 等一致）：

- **叫 `Def`**：它是 `@export` 自含参数的配置资源，与 `ValueDef`→`AddValueDef` 的命名模式一致。
- **不继承 `Def` 基类**：`Def` 承载的是「翻译（`tr_name` 走 CSV）+ 存档序列化（`save_data`）」。
  相机行为是**内嵌在场景里的技术参数**，既不需要翻译也不进存档，继承只会凭空多出无意义的翻译字段并往 CSV 写垃圾。

但**继承了 `Def` 的核心纪律**：行为可被多个机位共享，因此 **不得存放运行时状态**。
需要按机位累积的量（如抖动相位）一律向宿主机位取——见 `VirtualCamera3D.get_behavior_time()`。

### 用法

**编辑器**：机位 Inspector → `behaviors` → Add Element → 选行为类型 → 展开配参数。
需要「既跟随又朝向」就挂两个（顺序即执行顺序，通常先 Follow 后 LookAt）。

**代码**（推荐用方法，不要直接赋数组）：

```gdscript
var follow := FollowBehaviorDef.new()
follow.damping = Vector3(0.05, 0.3, 0.05)   # 水平跟得紧、垂直更缓
vcam.target = player
vcam.add_behavior(follow)
vcam.add_behavior(LookAtBehaviorDef.new())
vcam.clear_behaviors()                       # 退回固定取景
```

> 为什么不要写 `vcam.behaviors = [follow]`：本版本的 GDScript 会把数组字面量推断为**无类型** `Array`，
> 赋给类型化数组属性会报 `Invalid assignment` 而失败。用 `add_behavior()` / `behaviors.append()` 即可。

### 自定义行为

继承 `CameraBehaviorDef`，按需重写两个钩子之一：

| 钩子 | 时机 | 是否写节点 | 用途 |
|---|---|---|---|
| `apply(vcam, delta, instant)` | 求解姿态 | **是** | 决定机位在哪（跟随、环绕…） |
| `apply_offset(vcam, pose)` | 输出画面前 | 否 | 只修饰画面（抖动…），不污染场景、不反馈给跟随 |

```gdscript
class_name OrbitBehaviorDef extends CameraBehaviorDef

@export var radius: float = 5.0

func apply(vcam: VirtualCamera3D, delta: float, instant: bool = false) -> void:
	var t := vcam.target
	if t == null:
		return
	vcam.global_position = t.global_position + vcam.global_basis.z * radius
```

若行为有「朝向」语义，可重写 `get_aim_point()` 返回瞄准点——它会被用作球面/柱面混合的枢纽点。
Brain 通过 `vcam.get_aim_point()` 统一代问，**不认识任何具体行为类型**，因此自定义行为同样能参与弧线混合。

---

## 四、大脑（CameraBrain3D）

真实相机，继承 `Camera3D`。每帧：挑机位 → 混合 / 跟随 → 叠加偏移 + 冲击 → 写 `global_transform` 与 `fov`。

| 属性 | 说明 |
|---|---|
| `default_blend_time` | 机位没写过渡时长时使用的默认值（秒） |
| `blends` | 过渡规则表（`CameraBlendDef` 资源），见下文 [过渡规则表](#过渡规则表blends) |
| `tracking_damping` | 非混合期「**相机**追随**机位**」的平滑时间，0 = 严格贴住 |
| `ignore_time_scale` | 慢动作/暂停时相机仍按真实时间过渡（默认开） |
| `snap_on_ready` | 进场景时立即对齐机位（关闭则从场景摆放姿态混过去，可做开场推镜） |
| `blend_pivot` | 球面/柱面混合的枢纽点兜底（优先用机位行为提供的瞄准点） |
| `position_offset` | **叠加**位置偏移（相机本地空间）：常态特效写这里 |
| `rotation_offset` | **叠加**旋转偏移（角度，相机本地空间）：鼠标跟随等写这里 |

| API | 说明 |
|---|---|
| `snap_to_current()` | 立即对齐当前机位（传送 / 场景切换后消除拖影） |
| `is_blending()` / `get_current_camera()` | 混合状态查询 |
| `refresh()` | 标记重新挑选机位（机位属性变化时自动调用） |
| `update_camera(delta)` | 每帧驱动（子类重写 `_process` 时记得 `super._process(delta)`） |
| 信号 `blend_started(from, to)` / `blend_finished(vcam)` | 过渡开始 / 结束 |

**叠加偏移层**是关键约定：任何"抖动/摆动/鼠标跟随"都写 `position_offset` / `rotation_offset`，
不要直接写相机的 `position` / `rotation`——那会被机位混合覆盖。`TweenShake` 只需把 `property` 指向 `:position_offset` 即可。

**fov 语义**：机位 `lens_fov > 0` 时覆盖，否则沿用 Brain 自身的 `fov`；运行期外部修改 `Brain.fov` 会被自动认作新的基础值。

> 两个 damping 别搞混：Brain 的 `tracking_damping` 是「**相机**追随**机位**」；
> `FollowBehaviorDef.damping` 是「**机位**追随**目标**」。前者影响所有机位，后者只影响挂了它的机位。

### 过渡规则表（blends）

机位自身的 `blend_time/trans/ease/style` 是"**切到该机位**"的默认过渡——就近、直观，覆盖绝大多数场景。
`CameraBlendDef` 解决剩下的两类需求：**A→B 专属过渡**（反向不同）与**按来源/目标统一**（如"一切入过场机位都走 0.2 秒硬切"）。

- 规则按机位**节点名**匹配（资源不引用节点，无引用失效问题，跨场景可复用），`from` / `to` 留空 = 通配；
- 多条命中时**精确者胜**：`from+to` > 仅 `from` > 仅 `to` > 全通配；都不命中回退到机位自身配置；
- 命中即覆盖 `trans/ease/style`；`time < 0` 表示时长沿用回退链（机位自身 → Brain 默认）；
- Brain 就绪时会校验规则引用的机位名是否存在于场景，写错名字会打警告（按名匹配的防呆兜底）。

```gdscript
# Brain 上配置; 也可在 Inspector 的 blends 列表里添加
var rule := CameraBlendDef.new()
rule.to = &"Cinematic"      # 切入过场机位时
rule.time = 0.2             # 0.2 秒利落切换
brain.blends.append(rule)
```

### 混合轨迹

| 样式 | 轨迹 | 何时用 |
|---|---|---|
| `LINEAR` | 两点直线 | 无枢纽点、或位移很小 |
| `SPHERICAL`（默认） | 绕枢纽点走球面弧线（方向 slerp + 半径 lerp） | 有瞄准目标时，相机绕着目标转过去，**不会切过目标内部** |
| `CYLINDRICAL` | 绕枢纽点走柱面弧线（水平绕行 + 高度线性） | 环绕类机位，希望高度线性变化 |

枢纽点取值顺序：机位行为的瞄准点（`LookAtBehaviorDef` 或自定义行为的 `get_aim_point()`）→ Brain 的 `blend_pivot` → 都没有则退化为直线。

---

## 五、用 Godot 原生能力组合高级机位

框架刻意**不重复实现**引擎已有的东西。下列需求请直接用 Godot 原生节点——把机位挂成它们的子节点即可，
Brain 照样混合工作，无需任何额外代码：

| 需求 | 原生做法 | 说明 |
|---|---|---|
| 第三人称碰撞（相机穿墙） | `SpringArm3D` | 机位挂在 `SpringArm3D` 下，它自动缩短臂长避障 |
| 沿路径运镜 | `PathFollow3D` | 机位挂在 `PathFollow3D` 下，推动 `progress` 即可 |
| 简单跟随（无需阻尼/死区） | 机位挂成目标节点的子节点 | 零代码，目标动它也动 |
| Dutch 滚转（斜角镜头） | 直接旋转机位节点的 Z 轴 | 机位本来就是 `Node3D`，滚转是天然能力 |
| 跟随物理体抖动 | 项目设置 `physics/common/physics_interpolation` | 引擎级物理插值，开启后自动生效 |

这些方式与本模块正交：机位最终只提供「一个 `Transform3D`」，它怎么来（原生节点 / 行为资源 / 动画）框架不关心。
因此用 `AnimationPlayer` 驱动机位做过场同样可行。

---

## 六、统一入口（CameraTool）

```gdscript
CameraTool.get_brain()                       # 当前 Brain（不在树中返回 null）
CameraTool.get_camera()                      # 真实渲染相机，无 Brain 时退回视口相机
CameraTool.get_current()                     # 当前生效机位
CameraTool.activate(vcam, 0.5)               # 切机位（0.5 秒过渡）
CameraTool.deactivate(vcam)                  # 退出机位
CameraTool.find(level, &"GameOverCam")       # 按节点名找机位
CameraTool.snap()                            # 立即对齐当前机位
CameraTool.damp_weight(damping, delta)       # 帧率无关的指数平滑权重
CameraTool.interpolate_transform(...)        # 直线/球面/柱面姿态插值
```

### 手持抖动与冲击

两者定位不同，不要混用：

| | 手持抖动（行为资源） | 冲击（全局事件） |
|---|---|---|
| 用途 | 常驻"呼吸感"，让画面不呆板 | 事件驱动的震屏：爆炸、受击 |
| 配置 | 机位挂 `NoiseBehaviorDef` | `CameraTool.impulse(...)` / `CameraTool.shake(...)` |
| 作用方式 | 叠加在机位姿态上，**参与混合** | 叠加在 Brain 最终输出上，不影响机位 |
| 作用域 | 只有挂了的机位有（可逐机位调质感） | 全场景，与当前机位无关 |

```gdscript
CameraTool.impulse(hit_pos, 1.0)             # 定向冲击: 从 hit_pos 以 40m/s 扩散, 默认半径 25m
CameraTool.impulse(hit_pos, 1.5, 40.0, 0.8)  # 自定义强度/半径/时长
CameraTool.shake(0.6)                        # 无方向震屏(爆点在画面外 / 纯 UI 反馈)
CameraTool.shake(0.6, 0.5, cam.global_basis.x)  # 带主方向的震屏: 受击向侧后方 punch 的打击感
CameraTool.shake(0.6, 0.5, Vector3.ZERO)     # direction=ZERO 时关闭位移, 只留旋转抖动
CameraTool.clear_impulses()                  # 手动清空(通常不需要: 新 Brain 进场景会自动清)
```

冲击波形为衰减正弦（相位从 0 起振），叠加**传播延迟**（远的相机晚震到）与**距离衰减**（超出 radius 完全无感），
因此多个爆点会形成冲击波掠过的层次感。时间基于 `Time.get_ticks_msec()`，不受 `Engine.time_scale` 影响。

冲击是**静态全局状态**，因此 Brain 在 `_ready()` 里会自动 `clear_impulses()`——切场景不会带着上一个场景的余震进来，无需手动清理。

手持抖动（`NoiseBehaviorDef`）在机位局部空间采样 6 条通道（位置 3 轴 + 旋转 3 轴），噪声源是 Godot 原生 `Noise` 资源（可换类型/种子）。
**结果只体现在 `get_pose()` 返回值里，不写回节点**，因此既不污染场景，也不会反馈给跟随/死区计算。

---

## 七、编辑器支持

- **视锥 gizmo**：`Camera/Editor/VirtualCameraGizmo.gd`，由 `DEVFramework` 插件注册。机位画出视锥与上方向标记，参与竞争中的机位显示为橙色。
- **对齐到编辑器视角**：机位 Inspector 上的按钮，把 3D 视图当前视角写入机位，取景所见即所得。
- **取景器**（底部面板 *Camera Viewfinder*）：实时预览某个机位看到的画面。
  实现上用一个 `SubViewport` **共享编辑器 3D 视口的 World3D**，内部放一台预览相机对齐到目标机位——
  不需要复制场景、不改动场景树，看到的就是编辑中的真实场景。面板不可见时完全停止渲染，不占开销。

  画面按 **项目实际分辨率比例** letterbox 显示（读 `display/window/size/viewport_width/height`，改了设置立即生效），
  并同步 Brain 的 `keep_aspect`，因此取景范围与运行时一致——用固定 16:9 预览而游戏是别的比例时，水平取景范围会有偏差。

  面板控件：

  | 控件 | 作用 |
  |---|---|
  | 机位下拉 | 列出场景中所有机位，点选即切换预览，并同步选中该节点（3D 视图 gizmo 一起高亮） |
  | 跟随选中 | 在场景中选中机位时自动切换预览；选中非机位节点时**保持**上一台，不会丢失画面 |
  | 构图线 | 三分线 + 中心十字 + 安全框（四边内缩 5%） |
  | Solo | 让该机位立即生效（激活并置顶） |

### 取景器实现的坑（改动前务必读）

1. **必须用 `find_world_3d()` 取 world，不能用 `world_3d` 属性。**
   编辑器 3D 视口从不显式设置 `world_3d`，读出来恒为 `null`，它实际用的是**内部自动创建**的 world；
   只有 `find_world_3d()` 能拿到。共享到取景器 `SubViewport.world_3d` 后即为共享 scenario，
   于是能渲染到同一份场景内容。若误用 `world_3d`，画面会是一片空场景背景（**看起来"能显示"但内容全无**）。
2. **不要给 `Engine.get_singleton(&"EditorInterface")` 的返回值标注 `EditorInterface` 类型**（含 `as` 转换与带类型的 `return`）。
   这会触发 GDScript VM 内部错误 `Opcode 31 (OPCODE_RETURN): Condition "!nc" is true`，每帧刷屏。
   一律用**无类型返回 + 动态调用**。
3. **`_process` 在编辑器里不会自动启用**，必须在 `_ready()` 里显式 `set_process(true)`，否则取景器永远不刷新。
4. **构图线叠层不能塞进 `SubViewportContainer` 里靠 anchors 撑满**。那是 `Container`，会覆盖子节点 anchors，
   叠层拿不到画面的完整尺寸（实测画面 302 高、叠层只有 122 高 → 构图线全部错位）。
   正确做法：叠层与 `SubViewportContainer` **同为 `AspectRatioContainer` 的子节点**——
   它会把每个 Control 子节点摆到同一个按比例居中的矩形，两者矩形因此严格重合。
   另外绘制坐标一律基于叠层本地矩形（`(0,0)` 起），不要用 `get_rect()`（含父级偏移）；
   叠层 size 变化不会自动重绘，需把 `resized` 连到 `queue_redraw`。

另外：主屏幕不在 3D 视图时编辑器视口尚未建立 world，取景器会提示"请先把主屏幕切到 3D 视图"（属预期降级）。
共享 world 后取景器与编辑器视口同时渲染同一 scenario，面板不可见时务必保持渲染关闭（已实现）。

---

## 八、相对旧实现的修复点

| 问题 | 旧实现 | 现在 |
|---|---|---|
| 混合曲线不可控 | 每帧 `lerp(current, target, weight)`，weight 线性递增导致「越来越快」，旋转还额外 `weight²` | 固定时长 + Tween 曲线求权重，`Transform3D.interpolate_with` 四元数 slerp |
| 混合完就断联 | 过渡 Tween 结束后相机不再跟随，机位移动会掉队 | 混合结束后持续跟随（可选 `tracking_damping`） |
| 快速连切抖动 | 每次切换新建 Tween，旧 Tween 未 kill，互相打断 | 单一状态机，从「当前实际姿态」起混 |
| 欧拉角插值 | `global_rotation_degrees` 线性插值，跨 ±180° 会绕圈 | 四元数 slerp |
| 直线切换穿模 | 只能走直线 | 可选球面 / 柱面弧线，绕着目标转过去 |
| 机位属性堆砌 | follow / look_at / noise 共 16 个导出属性平铺在 Inspector | 收敛为 `target` + `behaviors` 两个，参数进资源，不挂行为则完全不显示 |
| 自造噪声参数 | 机位上自带 `noise_seed` / `noise_frequency` 等 | 噪声源改用 Godot 原生 `Noise` 资源（类型/种子/频率都在原生资源里配） |
| 切场景余震残留 | 冲击是静态状态，需自己记得 `clear_impulses()` | Brain 接管场景时自动清 |
| 两个 damping 撞名 | Brain 的 `follow_damping` 与机位跟随参数同名，极易配错 | Brain 改名 `tracking_damping`（相机追机位）与行为的 `damping`（机位追目标）区分 |
| 缩放污染 | 机位挂在带缩放父节点下会把缩放带给相机 | 取姿态时 `orthonormalized()` |
| 只能按栈顺序 | 只有 `active_cameras.back()` | `priority` + 激活顺序双重裁决 |
| 编辑器副作用 | `_validate_property()` 里创建 Tween | 编辑器只做 gizmo 与对齐按钮，不驱动 transform |
| 特效与混合争写 | 震屏写 `position`、鼠标跟随写 `rotation`，与混合互相覆盖 | 独立叠加偏移层 + 冲击通道 |
| 每帧遍历求生效机位 | Brain 每帧遍历全部机位 | 竞争关系变化时才重算并缓存 |
| 待命机位白跑 | 只要有跟随目标就每帧更新（含未激活的） | `standby_update` 三档策略，无跟随需求时完全不跑 |
| `look_at` 奇异翻转 | 上方向写死 +Y，俯仰接近垂直时翻转 | `look_at_up` 可配，奇异时自动改用相机右轴 |
| 运行期改 fov 失效 | 只在 `_ready` 快照一次 | 外部改动自动同步为基础 fov |
| 冷机位飘移 | 待命机位姿态陈旧，上台后从旧位置飘来 | 上台瞬间先 `snap_pose()` 对齐 |

---

## 九、典型搭建示例

```gdscript
# 面板类 UI(通用做法): 打开时激活机位, 关闭时退出, 无需代码记录上一个机位
func _on_opened() -> void:
	shop_vcam.set_active(true)

func _on_closed() -> void:
	shop_vcam.set_active(false)
```

固定机位占绝大多数时，场景里通常只有：一个挂 `CameraBrain3D` 的相机 + 若干摆好姿态的 `VirtualCamera3D`，
面板/流程信号直连机位的 `set_active`，动态手感（鼠标跟随等）由继承 `CameraBrain3D` 的子类写叠加偏移。
