# DEVFramework 分层约定（框架 = 机制 / 项目 = 内容）

> 本文档是框架与使用它的项目之间的**边界契约**。新增任何代码前请先过一遍第二节的判定清单。
> 历史背景：2026-08 已将 Buff/Attribute 全家从框架下沉到项目层（见第七节案例），本文档即那次重构的规则沉淀。

---

## 一、核心原则

**框架回答"怎么做"（How / 机制），项目回答"做什么"（What / 内容）。**

- 框架（`addons/DEVFramework/`）：换一款游戏仍然成立的东西 —— 数学、结构、协议、管线。
- 项目（`Scripts/`、`Assets/`）：只对当前游戏成立的东西 —— 玩法规则、数值语义、资源、文案。

对标业界：Unreal GAS 把属性聚合数学做成通用件、把效果定义留给数据与游戏层；ModiBuff 明言"绝大多数游戏的 buff/debuff 系统都是各游戏自己实现的"。本约定的结论与之完全一致。

---

## 二、归属判定清单（新代码放哪？）

按顺序自问，命中即停：

| # | 问题 | 是 → |
|---|---|---|
| 1 | 换一款不同玩法/题材的游戏，这段代码**一字不改**还能用吗？ | **框架** |
| 2 | 不能整体复用，但去掉具体语义后剩下一个通用骨架？ | 骨架进**框架**（抽象基类/协议），具体实现在**项目**继承 |
| 3 | 它引用 `res://Assets/`、`res://Scripts/` 下的具体资源或类吗？ | **项目** |
| 4 | 它含游戏语义（伤害公式、Buff 业务规则、存档字段格式、联机权威策略）吗？ | **项目** |
| 5 | 它是纯数学/纯结构（状态机、修饰符计算、排序、序列化协议）？ | **框架** |

---

## 三、三种合法协作模式

框架与项目之间只允许以下三种关系（附本仓库实例）：

### 1. 继承扩展（项目 extends 框架）
```
DamageEffectDef extends EffectDef      # Scripts/Def/Effect/
BuffDef        extends EntityDef       # Scripts/Def/（2026-08 起）
CartridgeInputSource extends InputSource
```

### 2. 组合调用（项目调用框架工具）
```gdscript
await ActorTool.game_ready(self)       # Actor.gd 调度子组件生命周期
SaveTool.save_async(path, data)
```

### 3. 鸭子类型回调（框架不认识项目类型）
框架侧的 context 参数**不带类型注解**，或由项目注入 Callable：
```gdscript
# EffectDef（框架）：apply(context) ← 无类型，运行时是项目的 GameContext
# BuffComponent.context_provider：项目注入 func(b): return GameContext.new(...)
```
框架永远不 `preload/load` 项目脚本，不写 `var x: GameContext`。

---

## 四、红线（禁止事项，附历史案例）

| # | 禁止 | 历史案例（均已修复） |
|---|---|---|
| 1 | 框架代码出现项目资源路径默认值 | `BuffComponent.defs_dir` 曾默认 `"res://Assets/Def/Buff"` |
| 2 | 框架类型注解/导入项目类 | `Buff.apply(data)` 的 data 实为 GameContext，靠鸭子类型假装不知道——允许；但写成 `data: GameContext` 不允许 |
| 3 | 游戏策略写死在框架组件里 | `is_multiplayer_authority()` 联网判断、`save_data()` 字段格式曾内置在框架 BuffComponent |
| 4 | 框架注释用项目专属类名举例 | `Entity.gd` 注释曾以 Buff/Modifier 为例，类迁走后注释过时 |

> 判断口诀：**路径、类型名、策略、注释，四处都不要让框架认识项目。**

---

## 五、本仓库现行分层对照表

| 职责 | 框架（addons/DEVFramework） | 项目（Scripts/ 等） |
|---|---|---|
| 属性数学 | `Modifier` / `ModifierValue`（base_value+修饰链重算） | — |
| 属性/Buff 容器与语义 | — | `Buff` / `BuffComponent` / `AttributeComponent` / 各 Def 与 TagDef |
| 效果系统 | `EffectDef`(协议) / `EffectsDef` / `SystemEffectDef` | 70+ 具体效果 Def、`GameContext` |
| 流程状态 | `StateMachine` | MonitorGame 的状态枚举与转换表 |
| 步进顺序 | `TickTool`（物理 tick 步进队列，按 `order_key` 定序）/ `GameTimer` | `Actor._tick_order()`（玩家先于敌方的策略）、`MonitorGame._physics_process`（接线点） |
| 任务系统 | `Task`/`TaskDef` 协议 | 教程任务 .tres 定义 |
| 回放命令 | `GameCommand`/`CommandHistory`/`InputSource` 协议 | `&"use_equip"` 等具体命令、`CartridgeInputSource` |
| AI | Goap 全套（暂未使用） | — |
| 镜头 | `VirtualCamera3D` / `CameraBrain3D` / `CameraTool`（机位竞争 + 混合数学 + 叠加偏移协议） | `PlayerCamera`（鼠标跟随手感、震屏参数、场景机位摆放） |
| 其余 | ECS / Tween / View / Tool | Actor 及其组件、View 子类 |

---

## 六、违规自查（定期可跑）

```powershell
# 1. 框架是否引用了项目路径（应只剩脚手架/翻译CSV等框架自身约定）
grep -E "res://(Scripts|Assets|Scenes)/" addons/DEVFramework -r --include="*.gd"

# 2. 框架是否出现游戏语义名词（注意词边界，factor/buffer 会误报）
grep -E "\b(damage|card|fight|buff|Buff|health|gold|shop)\b" addons/DEVFramework -r --include="*.gd"
```

MCP 辅助：改/删共享资源前先 `find_resource_users` 查双向依赖；移动脚本必须连同 `.gd.uid` 一起 `git mv`（场景/资源靠 uid 寻址）。

---

## 七、目录组织双轨制（分层轴 vs 功能轴）

框架目录存在两条合法轨道，**按内聚度判定归属，不做全局二选一**（对齐 Feature-Sliced Design 的 layers+slices 与 Modular Monolith 的 modules+内部自由组织）：

| 轨道 | 目录 | 放什么 |
|---|---|---|
| **分层轴** | `Def/` `Entity/` `View/` `Tool/` 根部 | 核心骨架：被所有功能共用的基类协议（EffectDef/ValueDef/SignalDef）、纯数学原语（ModifierValue）、横切工具 |
| **功能轴** | `<Module>/{Def,Entity,Tool}/` 自包含 | 可拔插功能域：AI、ECS、Task、GameCommand、Tween、Camera |

**归属三问**（新增功能时按序自问）：
1. **删除测试**：整文件夹删掉后框架其余部分还能编译运行吗？能→功能轴；不能→分层轴
2. **API 宽度**：对外是少量入口类（GoapAgent/ECSWorld/CameraTool）→功能轴；是被广泛继承的基础协议（EffectDef 被 70+ 类继承）→分层轴
3. **共变率**：一个需求总是同时改这组文件吗？是→功能轴

**红线**：禁止把同一功能域的 Def 与 Entity 劈到分层轴两处（2026-08 已归位 Task/Audio，见第八节）。
跨模块依赖必须单向且显式注释（如 GameCommand→ECS、Camera→UI，各模块不得反向依赖）。

---

## 八、历史决策记录

> **现状标注**：以下条目记录 **PCG**（已拆为独立项目）与**程序化音频合成**（2026-10 整体删除，未拆出）
> 两个模块在本仓库存续期间的设计决策，相关目录均已移出，路径描述仅作历史存档。
> 3D 程序化生成现为独立插件项目 `d:\Work\GodotProject\PCG`；查当前用法请去该项目的 Readme。
> 音频合成无对应项目；历史条目里的 `Audio/`、`AudioGenDef` 等路径均已不存在，勿据此新建代码。

**2026-10：PCG 全量重构为「3D 生成运行时」，SDF 并入（功能轴）**
- 动因：模块原为「2D 栅格地图生成 + 3D 体素补丁」，2D 占代码量 92.6%；这类产物是俯视地图数据，与"3D 模型"是两类产物，混在一处会让真正的 3D 能力被淹没。需求明确：PCG 专职服务 3D 模型世界生成，同一份数据既能产体素模型也能产 lowpoly 场景。
- 做法一（收敛产物类别）：整体移除 2D 能力 —— 2D 栅格 8 种算法、生物群系、河流道路、程序化纹理、L-System、模板拼接、内容进化，以及配套的约 64 个 `.tres` 与 2D 演示/测试。保留 3D 栅格（4 种算法）、3D 散布、分块世界、生成管线。
- 做法二（合并平行系统）：原与PCG 平行的 `SDF/` 模块整体并入 `PCG/`，重构为六层：`Core/`（SdfField + 几何算子 + MeshExtractor + 噪声层，统一中间表示）、`Voxel/`（3D 栅格 + 体素产物）、`Model/`（PropGen/PropBuild/PropGenTool/PropLayoutTool/ModelGraph/ModelBaker）、`Pipeline/`、`Style/`（三渲二）、`World/`（SceneStylePack）。
- 核心主张（成为模块的轴）：**烘焙只做一次**。`SdfField` 是唯一中间表示，MeshExtractor 与 VoxelExtractor 各自只是投影；实测烘焙占总耗时 99.9% 以上，所以双产物几乎不加钱、两产物必然同形、换画风不必重算几何。
- 分层落点：`SceneStylePack` 留在框架但只含机制（画风+配色+配方表+布局参数+输出形态），三套具体预设引用项目生成器脚本，故拆到 `Scripts/Gen/SceneStylePresets.gd`；`WorldAssembler.from_pack()` 建在项目层，依赖方向单向（项目 → 框架）。
- 决策：**不保留 2D 兼容层**。保留会让"只做 3D"这件事在代码里失效，而 2D 产物已有替代路径（地图可由体素栅格顶视导出）。
- 遗留：`PCGErode` / `PCGLSystem` 等 PCG 原生类已随 PCG 模块移出，其源码已删，但已编译的 `dev.gdextension` 仍注册着它们（无调用方，不阻塞运行，重编译后消失）。
- 验证：`Scripts/Test/pcg/` 8 个测试经 `test_pcg.gd` 单桥接接入 TestRunner；演示收敛为 `Scenes/PCG/` 5 个 3D 场景。

**2026-10：SDF 模块按「生成 / 布局」双契约定位（功能轴）**〔本条已被上一条取代：`SDF/` 已整体并入 `PCG/`，文档迁至 `PCG/Readme.md`〕
- 动因：单体造型与世界摆放若揉在一个生成器里，会同时烂掉两头——换风格要通读世界逻辑，布局无法复用于新物体，存档只能存网格。需求明确要求「各物体独立生成，最终只做摆放」。
- 做法：新增 `SDF/` 功能轴，内部再切两个**互不通气**的域：`Entity/Tool`（分块稠密 SDF 基座 + Surface Nets / Dual Contouring 提取）与 `Gen/`（`PropGen` 生成契约 / `PropBuild` 局部产物 / `PropGenTool` 烘焙 / `PropLayoutTool` 贴地朝向避让）。两者唯一交接面是 `PropBuild`。
- 分层落点：框架层只保证能力，**不预设任何具体物体**（框架内无「商店/医院」等语义）；`ShopGen`/`HospitalGen`/`VehicleGen`/`StreetGen` 与 `WorldAssembler`、`PropRecipe` 全部落**项目层** `Scripts/Gen/`，换一款游戏整目录可替换。
- 依赖方向单向：`Gen → 基座`。布局层通过鸭子类型（`func(x,z) -> float`）取地面高度，因此**不认识任何地形类**，不反向依赖 PCG 的地形实现。
- 决策：布局层允许 `ground_step` 采样密度参数（长单体必需），但不允许传入地形对象——保持「只认数字」的对偶关系。
- 验证：`Scripts/Test/pcg/` 三层测试（生成 / 布局 / 端到端）经 `test_sdf.gd` 接入 TestRunner，实跑 3 项全过。其中布局层测试**全程不生成真实几何**（夹具手搓 3 顶点假网格），是「布局层不认识几何细节」的可执行证明；生成层断言「包围盒最低点 ≈ 0」，是「纯局部空间」的可执行证明。
- 演示：`Scenes/PCG/PCGWorldAssemble.tscn`（项目层）把三条主张做成可当场验证的交互——点选单体只换 seed 与网格、**站位位移实测 0.0 m**（证明解耦）；存档 14 条每条恰好 `tag/seed/x/y/z/yaw` 6 字段且不含网格；读档 14/14 还原、位置偏差 0.0 m、朝向误差 ~1.5e-7、二次存档与原始存档逐字节一致。
- 补充决策：**分帧组装是框架职责，不是调用方的耐心问题**。`assemble()` 同步跑完会堵住主线程近 20 s（实测 14 单体烘焙 18485 ms / 布局 3 ms），期间窗口不响应、`SceneTree.current_scene` 甚至取不到。故框架直接提供 `assemble_step()` / `assemble_finish()` / `step_progress()` / `step_pending()`，同步 `assemble()` 保留为薄封装以兼容旧调用。
- 教训（已写入 `SDF/Readme.md` §6）：`rng.state = rng.seed` 会让 PCG32 序列退化、不同 seed 塌成同一值，且确定性测试**全过**——测试必须同时断言「同 seed 复现」与「异 seed 不同」。

**2026-08：Buff/Attribute 下沉项目层**
- 动因：框架反向硬编码项目路径、Buff 触发逻辑绑定项目 GameContext、多人权限/存档格式属游戏策略。
- 做法：7 个脚本+uid 以 git mv 迁至 `Scripts/{Def,Entity}`，25 个 .tres + 2 个 .tscn 批量修正 ext_resource 路径；`Modifier`/`ModifierValue`（纯数学）保留框架。
- 依据：GAS（聚合数学通用、效果游戏层）、ModiBuff（buff 语义各游戏自建）、godot-gameplay-attributes（与能力系统解耦）。

**2026-08：VirtualCamera 插件迁入框架功能轴（Camera 模块）**
- 动因：`addons/VirtualCamera` 是独立空插件（plugin.gd 为空壳），却承载通用镜头机制；通过删除测试（整域可拔除）且对外只有 vcam/Brain/CameraTool 三个入口 → 功能轴。
- 做法：`git mv` 连 uid 迁为 `Camera/{VirtualCamera3D,CameraBrain3D}` + `Camera/Tool/CameraTool.gd` + `Camera/Editor/VirtualCameraGizmo.gd`；`MainCamera3D` 更名 `CameraBrain3D`（对齐 Cinemachine Brain 语义），删除旧插件目录并从 `project.godot` 插件列表移除；2 个 .tscn 修正 ext_resource 路径（uid 未变）。
- 重构（第三轮·按"简单易用易拓展"收敛）：跟随/朝向/抖动的 16 个平铺属性收敛为资源化扩展点——`target`（节点引用，属场景）+ `behaviors: Array[CameraBehaviorDef]`（资源，属配置），内置 `FollowBehaviorDef`/`LookAtBehaviorDef`/`NoiseBehaviorDef`，可继承自定义；两个钩子 `apply`(写节点) / `apply_offset`(只修饰画面)；Brain 经 `vcam.get_aim_point()` 代问枢纽点，不认识具体行为类型。同时明确"不重复造轮子"边界：碰撞回避用 `SpringArm3D`、路径运镜用 `PathFollow3D`、物理插值用引擎设置、噪声源用原生 `Noise`，框架不实现。
- 命名归位：行为配置资源采用框架既有 `xxxDef` 约定（同 `TownStepDef`/`TileDef`：叫 Def 但**不继承** `Def` 基类），因为 `Def` 承载的是"翻译走 CSV + 存档序列化"，而相机行为是内嵌场景的技术参数、无翻译无存档；但沿用 `Def` 的核心纪律——行为可被多机位共享故**不存运行时状态**，相位等按机位累积的量向宿主机位取（`get_behavior_time()`）。
- 过渡规则表：机位自身 `blend_*` 仍是就近默认；`CameraBlendDef`（Brain.blends，按机位名匹配、空名通配、精确者胜）补齐"A→B 专属"与"按来源/目标统一"两类低频需求；命中覆盖曲线/轨迹，`time<0` 沿用回退链；Brain 就绪时校验规则引用的机位名（按名匹配的防呆兜底）。`BlendStyle` 枚举归属 `CameraTool`（它是插值数学的参数，供机位/规则/Brain 共用，避免任何一方引用另一方的枚举）。文档红线执行：Camera 模块文档清除全部项目侧类名/场景引用（框架文档必须换一款游戏仍能读懂）。
- 重构（第二轮）：生效机位缓存（不再每帧遍历）、球面/柱面混合轨迹、跟随死区 + 软区、待机更新三档策略、机位手持抖动（只作用于 `get_pose()` 不写回节点）、`CameraTool.impulse/shake` 冲击系统、可配 `look_at_up` 与奇异保护、运行期 fov 同步、底部面板取景器（共享编辑器 3D 视口 World3D 渲染，不复制场景）。
- 重构（第一轮）：优先级竞争取代裸栈、固定时长 + Tween 曲线 + 四元数 slerp 混合、混合后持续跟随、机位 follow/look_at/lens_fov、Brain 叠加偏移层（震屏与鼠标跟随不再与混合争写 transform）。
- 分层落点：机位竞争/混合数学/偏移协议在框架；鼠标跟随手感、震屏参数与机位摆放留在项目 `PlayerCamera`。

**2026-08：Task/Audio 归位功能轴（目录双轨制确立）**
- 动因：两域均通过删除测试（可整体拔除）却按分层轴摆放——Task 劈成 Def/Task+Entity/Task 两处、Audio 散落 Def/Audio+Entity/Audio+PCG 三处，违反就近原则。
- 做法：git mv 连 uid 迁为 `Task/{Def,Entity}` 与 `Audio/{Def,Entity,Tool}` 自包含模块；15 个 task .tres 批量修正路径；AudioGenDef 留守 PCG/Def 作为单向桥接点。
- 验证：全部引用走全局 class_name，代码零改动；资源经 uid 寻址无缝衔接。
