# 分层约定（框架 = 机制 / 项目 = 内容）

> 新增任何代码前先过第二节清单。改动理由写进提交信息，不写进本文件。

## 一、核心原则

- 框架（`addons/DEVFramework/`）：换一款游戏仍成立的数学、结构、协议、管线。
- 项目（`Scripts/`、`Assets/`）：只对当前游戏成立的玩法规则、数值语义、资源、文案。
- Def 的身份 = 资源路径（存档只存路径，DLC 靠同路径覆盖）。
- **简单 · 易用 · 易拓展**：一条路径实现 / 一行调用 / 只加文件即可扩展。三者缺一即未完成。

## 二、归属判定（按序自问，命中即停）

| # | 问题 | 是 → |
|---|---|---|
| 1 | 换个游戏这段代码一字不改还能用？ | 框架 |
| 2 | 去掉具体语义后剩一个通用骨架？ | 骨架进框架，具体实现在项目 |
| 3 | 引用具体项目资源或类？ | 项目 |
| 4 | 含游戏语义（伤害公式、存档字段、联机策略）？ | 项目 |
| 5 | 纯数学 / 纯结构（状态机、修饰符计算、序列化协议）？ | 框架 |

**形态判定（归属定了，再定它长什么样，命中也即停）**

1. 编辑器可配、要存档 → `Def`（`Assets/Def/*.tres`，必带 `@tool`）
2. 只有运行时存在、有状态 → `Entity` / `Entity2D` / `Entity3D`
3. 玩家看得见或要交互 → `View`（一律 `.tscn` 搭，不代码生成）
4. 横切、无实例状态 → `Tool`（`class_name XxxTool extends RefCounted`，全 static，状态放 `static var`）
5. 每帧被批量调度 → `XxxSystem`
6. 以上都不是 → 在造第五种角色，停下重想

同义词禁用：`Service` / `Processor` / `Handler` / `Driver` / `Runner` / `Brain` / `Planner`。

## 三、三种合法协作

1. **继承扩展**：项目 `extends` 框架基类（`DamageEffectDef extends EffectDef`）。
2. **组合调用**：项目调框架工具（`SaveTool.save_async`、`NodeTreeTool.game_ready`）。
3. **鸭子回调**：框架侧参数不带类型，或由项目注入 `Callable`。框架永不 `load` 项目脚本。

## 四、红线

| # | 禁止 |
|---|---|
| 1 | 框架代码出现项目资源路径默认值 |
| 2 | 框架类型注解 / 导入项目类 |
| 3 | 游戏策略（联机权限、存档格式）写死在框架组件里 |
| 4 | 框架注释用项目专属类名举例 |

口诀：**路径、类型名、策略、注释，四处都不要让框架认识项目。**

## 五、目录组织（目录名 = 能力名）

| 位置 | 放什么 |
|---|---|
| `Core/{Def,Entity,Tool,Async,Pool,Editor}` | 跨能力复用、无业务语义：基类协议、纯数学原语、横切工具、基础设施 |
| `<能力>/{Def,Entity,View,Tool,Editor}` | 一个能力一个目录，自包含（`Dialogue`、`Task`、`AI`、`Camera`、`ECS`、`Tween`…） |
| `Native/` | 原生库 + `dev.gdextension`。**禁止移动**：库路径写死在配置里 |

- 内部层名固定五个：`Def` / `Entity` / `View` / `Tool` / `Editor`；**少于 3 个文件就扁平**，不要为 1 个文件建子目录。
- 不再有 `View/` `Tool/` `Def/` `Entity/` 这类"跨能力层目录" —— 那是旧结构，内容已按能力拆散。
- 例外只有一个半：`MCP/` 因内部 `preload` 硬编码网 + autoload 保持扁平；`Native/` 因二进制路径保持顶层。

归属三问：**删除测试**（整文件夹删掉还能编译？）→ **API 宽度**（少量入口类，还是被广泛继承）→ **共变率**（是否总一起改）。
红线：同一功能域的 Def 与 Entity 不许劈到两处。

搬迁纪律（改目录时必做）：`git mv`（含 `.uid`）→ 替换**所有**引用（不止 `.gd`：`plugin.gd` 有 `.tscn`/`.png`，`project.godot` 有 autoload 路径）→ 跑 `test_framework_compile`（内含路径存在性校验）。

跨模块依赖白名单（单向，新增必须先登记）：

| 从 → 到 | 理由 |
|---|---|
| `Entity → ECS` | `ECSLink` 内建桥接 |
| `MCP → Camera` | 调试工具读取机位 |

`ECS/` 是**核心能力**而非可拔插件：`Entity` / `Entity2D/3D` 通过 `ECSLink` 与它内建桥接，删除测试对它不成立。

## 六、命名与标注

| # | 规定 |
|---|---|
| 1 | 类名占全局命名空间。基类保留短名（`Def` / `Entity` / `UIPanel` / `Pool`），其余带领域前缀（`GoapAgent` / `ECSWorld`）；项目与第三方不得同名，新增前全仓搜一次 |
| 2 | `@tool` 只在被编辑器调用时加（`EditorScript`、DefTable、gizmo）；运行时工具不加，省编辑器加载开销 |
| 3 | Hook 签名基线 `game_init()` / `game_ready()` / `save_data() -> Dictionary` / `load_data(data: Dictionary) -> void`；现存多参写法保留，新增与修改归一到基线 |
| 4 | `LogTool` 标签用固定短词（`存档` / `对象池` / `Def` / `MCP`），新标签先搜已有，不造同义词（设置项 `ignored_tags` 靠它对账） |

## 七、违规自查

```powershell
grep -rE "res://(Scripts|Assets|Scenes)/" addons/DEVFramework --include="*.gd"
grep -rE "\b(damage|card|fight|buff|health|gold|shop)\b" addons/DEVFramework --include="*.gd"
# 禁用后缀: Service / Processor / Handler / Driver / Runner / Brain / Planner 一律违规
grep -rnE "class_name \w*(Service|Processor|Handler|Driver|Runner|Brain|Planner)\b" addons/DEVFramework
```

改/删共享资源前先查引用（MCP `find_resource_users`）；移动脚本连 `.gd.uid` 一起 `git mv`。

## 八、Def 寻址（路径即身份）

| # | 纪律 | 违反后果 |
|---|---|---|
| 1 | 不改名、不移动已有 Def 文件 | 老存档路径失效，读取返回 null |
| 2 | 同一路径只换实现，不换语义 | 老存档静默读到另一份配置 |
| 3 | 关键存档数据不用内嵌子资源 | 无法被 DLC 覆盖，子资源改名/重排即失效 |

新增内容一律用新路径（覆盖只用于替换，不用于扩展）。
