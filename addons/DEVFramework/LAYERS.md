# 分层与命名

新增代码前过一遍；命名不对就别提交。

## 一、框架还是项目

| # | 自问 | 是 → |
|---|---|---|
| 1 | 换个游戏一字不改还能用？ | 框架 |
| 2 | 去掉具体语义还剩通用骨架？ | 骨架进框架，具体留项目 |
| 3 | 引用具体项目资源或类？ | 项目 |
| 4 | 含游戏语义（伤害公式、存档字段、联机策略）？ | 项目 |
| 5 | 纯数学 / 纯结构（状态机、修饰符、序列化）？ | 框架 |

**三种合法协作**：① 继承框架基类 ② 调用框架工具 ③ 注入 `Callable`。
框架永不 `load` 项目脚本。

## 二、形态（命中即停）

1. 编辑器可配、要存档 → `Def`（`Assets/Def/*.tres`，必带 `@tool`）
2. 只有运行时存在、有状态 → `Entity` / `Entity2D` / `Entity3D`
3. 玩家看得见或要交互 → `View`（一律 `.tscn` 搭）
4. 横切、无实例状态 → `Tool`（全 static）
5. 每帧被批量调度 → `XxxSystem`
6. 都不是 → 你在造第五种角色，停下重想

禁用同义词：`Service` / `Processor` / `Handler` / `Driver` / `Runner` / `Brain` / `Planner`。

## 三、目录

| 位置 | 放什么 |
|---|---|
| `Core/{Def,Entity,Tool,Async,Pool,Editor}` | 跨能力复用、无业务语义 |
| `<能力>/{Def,Entity,View,Tool,Editor}` | 一个能力一个目录，自包含 |
| `Native/` | 原生库 + `dev.gdextension`，**禁止移动** |

**目录名 = 能力名**。找不到对应能力 = 这个能力还没起名，先起名再建目录。
内部层名固定五个；**少于 3 个文件就扁平**（单一角色的模块即使文件多也保持扁平：`Value/ Signal/ UI/ Audio/`）。
例外：
- `MCP/` 扁平（内部 preload 硬编码网 + autoload）
- `ECS/` 按内容分层 `Component / System / World / Timer / Render`：列存储 + 系统调度的语义比 Def/Entity/View 更准
- `Render/` 下再分 `Lightmap/`、`Screenshot/` 两个子能力目录

## 四、命名

| 对象 | 规则 | 例 |
|---|---|---|
| 脚本文件 | **文件名 = 类名，PascalCase**（本项目不用官方 snake_case 文件名） | `DialogueTool.gd` |
| 用途后缀 | `*Def` 配置 / `*Entity` 运行时 / `*View` 展示 / `*Tool` 入口 / `*System` 调度 | `BubbleView` |
| 基类 | 短名 | `Def` / `Pool` / `UIPanel` |
| 其余类 | 领域前缀 | `GoapAgent` / `ECSWorld` |
| 目录 | PascalCase，= 模块名 | `Dialogue/` |
| 场景 | PascalCase；演示用 `*Demo.tscn` | `RankView.tscn` |
| 演示脚本 | 与场景同目录同名 | `Scenes/Dialogue/DialogueDemo.gd` |
| 资源 `.tres` | snake_case | `stat_damage.tres` |
| 测试脚本 | `test_<模块>.gd`（唯一 snake_case，`TestRunner` 按前缀扫描） | `test_dialogue.gd` |
| 引擎入口 | 小写（引擎约定） | `plugin.gd` |

方法：`_foo()` 回调 · `on_xxx` 信号（过去式=完成）· `get_/is_/has_` 纯读 · `apply/revert` 成对 · `await_*` 协程（禁 void）。

返回：`bool` 是否生效 · `void` 已受理 · `Error` 仅 IO · `null` 查询未命中。

## 五、红线

1. 框架里出现项目资源路径
2. 框架类型注解项目类
3. 游戏策略写死在框架
4. 框架注释用项目类名举例

**路径、类型名、策略、注释 —— 四处都不要让框架认识项目。**

## 六、搬迁纪律

1. `git mv`，`.gd` 与同名 `.uid` 一起移
2. 替换**所有**引用：不止 `.gd` —— `plugin.gd` 有 `.tscn`/`.png`，`project.godot` 有 autoload
3. 跑 `test_framework_compile`（路径存在性校验会兜住漏改）

不动的：`Native/`（二进制 + 写死路径）、`MCP/`（preload 硬编码网）。

## 七、已知例外

### 1. Core 反向引用能力模块（33 处 / 9 文件）

方向规则是"模块可引用 Core，Core 不引用模块"。以下是为了**能力不要重复实现**而保留的反向边；
动这些位置时两边一起改，不要只看一侧。

| Core 侧 | 引用 | 站点 |
|---|---|---|
| `Core/Entity/Entity.gd` `Entity2D.gd` `Entity3D.gd` | `ECSLink` `ECSWorld` | 12 处（含类型化成员 `var _ecs: ECSLink`，删 ECS 必编译失败） |
| `Core/Def/Def.gd`、`Core/Tool/CSVDataAccess.gd`、`Core/Editor/EditorScriptMenuTool.gd` | `TranslationTool` / `EditorTranslationTool` | 14 处（路径与本地化只有一份实现） |
| `Core/Tool/ResetTool.gd` | `FocusMaskTool` `AudioTool` `CameraTool` `TaskTool` `DialogueTool` | 5 处（"重置全部进程级状态"必须列全所有 Tool） |
| `Core/Tool/InputTool.gd` | `CameraTool` | 2 处（键盘输入直接驱动相机） |
| `Core/Tool/TipTool.gd` | `TweenAnimation` | 2 处（提示动画复用 Tween 组件） |

判据：**删除测试**（删掉该模块，框架仍能编译运行）对这些点不成立。新增模块不要加入这张表。

### 2. 无项目引用的模块

`Audio/`（3 文件 507 行）与 `Value/`（11 文件）在项目侧没有任何 `.tscn` / `.tres` / 脚本引用。
删除它们要同时动 `Core/Tool/ResetTool.gd:17`（`AudioTool.reset`）与 `Signal/ValueConditionDef.gd`（`ValueDef` 字段），
故先保留并在此登记，避免误认为是死代码就随手删。

- `Audio/AudioTool.gd`（264 行）运行时播放入口：2D/3D 同接口、音乐交叉淡化、总线音量与静音。
- `Audio/AudioMixerTool.gd`（170 行）编辑器/启动期配置：效果预设与总线布局的构建、应用、保存。
- `Audio/AudioBakeTool.gd`（76 行）仅编辑器：经效果链真播一遍并用 `AudioEffectRecord` 录回、写 WAV。

要用音频却没接线的项目，直接调 `AudioTool.play` 这类静态入口即可（容器节点 `_Audio` 挂在 `SceneTree.root` 下跨场景存活），
不必先搬模块；只有在确定整块不要音频时才按上面两处解绑后删除。

`Value/` 里 `DivideValueDef`（公式 A/B，除零给 ±INF）与 `FractionValueDef`（分数/比例，除零回 0）
看着都是除法，语义并不同，**不要合并**。

### 3. MCP/ 用路径加载脚本（结构必须，不是遗留）

`MCP/` 是唯一"按路径取脚本"的目录，规则自洽：**会被动态重编译的域文件不声明 `class_name`，
不会被重编译的三个才声明**（`MCPDevServer`、`MCPTcpHttpServer`、`MCPDebuggerPlugin`）。

- 域装配走 `_mod("MCPResult")` → `_script_from_disk(MCP_DIR + name + ".gd")`：读磁盘源码、`GDScript.new()` 重编译成新对象。
  这样改完框架代码 `refresh_tools` 就能拿到新逻辑，不必重启编辑器（编辑器不打断正在服务的 MCP 连接）。
- 换成全局 `class_name` 在这里**做不到**：动态副本与已注册全局类重名，`reload()` 直接 `ERR_PARSE_ERROR (43)`，
  报 `Class "X" hides a global script class`（4.7.2 实测）。所以域脚本的身份 = 路径 + 文件名。
- 域里引用别的域用 `const X := preload(...)`。**叶子不随域换代**：重编译域只换域自身的代码，域内 preload
  仍绑定缓存里的叶子对象（`ResourceLoader.load(CACHE_MODE_REPLACE)` 也拿同一对象且不同步刷新源码）。
  故 `refresh_tools` 会自检并以 `stale_leaves` 回报"磁盘已改但当前仍是旧版"的叶子；改名/移位域文件必须 `restart_editor`。
- 域外没有这条约束：其余 20 个模块照常用 `class_name`（181 个），`preload` 只用于类型/工具类。
  插件禁用/启用（`EditorInterface.set_plugin_enabled`）能重扫新增全局类，但会掐断 MCP 自己的连接，只用于
  "改了 `MCPDevServer.gd` 本身"时替代 `restart_editor`。

