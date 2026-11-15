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
内部层名固定五个；**少于 3 个文件就扁平**。
例外：`MCP/` 扁平（内部 preload 硬编码网 + autoload）。

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
