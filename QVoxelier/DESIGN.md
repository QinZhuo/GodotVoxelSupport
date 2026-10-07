# QVoxelier 设计文档

> 目标：一个**专为体素建模**的建模软件。定位对标 MagicaVoxel，但要求更优雅、更易用、
> 功能更完整、更通用、更易拓展。
>
> 本文档回答四件事：**能不能做（可行性）→ 别人怎么做（参考架构）→ 我们选哪条路（方案对比）
> → 底层怎么搭（目标架构）**。

---

## 修订说明（2026-10-08，优先级高于本文其余部分）

本文初稿的架构前提已被推翻，以下为**当前有效**的定位。冲突处以本节为准：

1. **核心能力全部在插件内，编辑命令在应用层**。世界结构（对象模型 + 修改器链）在
   `addons/VoxelSupport/Modifier/`，类名前缀统一为 `QVox*`
   （`QVoxWorld` / `QVoxObject` / `QVoxModifier` / `QVoxDomain` / `QVoxEvalContext`）；
   撤销命令（`QVoxCommand` / `QVoxUndoStack` / `QVoxVoxelEditCommand`）在
   **`QVoxelier/Core/`**（它要引用 `DEVFramework.GameCommand`，而两个插件之间必须零引用）。
   原 `QVoxRasterizer` 已**折叠**为 `PcgSdfGenerator.rasterize_field()`，不再单独存在。
2. **插件需要重构**，而不是"一行不改"（见 `docs/REFACTOR_PLAN.md` 的 P0~P4）。
3. **QVoxelier 是独立仓库**的薄壳应用：一个可运行的独立场景，"根据输入合理调用插件功能"，
   让普通用户能方便地建模。它不实现任何体素算法。
4. **`.qvox` 是唯一工程文件格式**（qvox 3 起原生承载世界结构，**不兼容 qvox 2**）。
   初稿提过的 ZIP 容器与 `.vstudio` 扩展名均作废。
5. 术语：顶层容器叫**世界（World）**，不叫"文档（Document）"。

---

## 0. 定位与边界（先划边界，否则所有讨论都会漂）

| 维度 | QVoxelier 负责 | 明确不负责（由插件的可选层负责，且该层要从内核抽离） |
|---|---|---|
| 世界 | **一个有界体素模型 = 一块 `grid_size` 立方体**（MagicaVoxel 语义） | 无限世界、流式加载、LOD、原点漂移 |
| 分辨率 | 世界级固定 `voxel_size`，改它触发全链重算 | 逐视点 LOD 切换 |
| 交互 | 手绘体素 + 非破坏修改器链 + 撤销重做 | 运行时破坏（`VoxelDestructible`） |
| 时间 | **交互期（编辑器内）** | 每帧游戏循环 |
| 输出 | 体素数据 / 网格 / `.qvox` 世界文件 | 游戏内渲染调度 |

**为什么必须先划这条界**：体素域算子（侵蚀、风化、连通性清理）需要**完整邻域**，这与
"惰性按 chunk 生成、只持有 32³"的流式架构天然冲突。现有插件已经在 `PcgSdfGenerator` 的
注释里承认过这个矛盾（"`details` 那条链需要完整邻域，与 SDF 惰性按 chunk 生成不兼容，
于是岛体/多孔岩一直吃不到风化"）。**把建模软件定位成"有界模型"，这个矛盾就消失了** ——
而且这正是 MagicaVoxel 的定位。两者互补，不是替代关系。

**这条界也决定插件自身要动的刀**：既然有界模型与视点无关，插件的
"LOD / 流式 / 剔除 / 原点漂移"就应当作为**可选·无限层**从内核抽离（见 `REFACTOR_PLAN.md` §4）。
即：模型定位的一次决定，同时解决了插件里最大的耦合源。

---

## 1. 可行性分析

### 1.1 核心结论：不是"能不能重构"，而是"只差一层"

盘点后得到一个非常明确的事实：

> **现有插件的 PCG/SDF 通路，本身就已经是一条修改器链 —— 只是被硬编码成了三步，
> 且不可重排、不可插中间节点、不可增删。**

现状的实际数据流：

```
field(SDF 树)
  │  ① FIELD 段：Sdf 组合算子构成表达式树（SdfUnion / SdfSmoothUnion / SdfSubtract / …）
  ▼  由 PcgSdfGenerator._material_at() 逐体素格心光栅化
volume(PackedInt32Array)
  │  ② VOXEL 段：PcgModelGenerator.details 数组按顺序执行 PcgDetail.apply()
  ▼  由 VoxelChunkGenerator / VoxelMeshGenerator 网格化
mesh(ArrayMesh)
  │  ③ MESH 段：目前为空
  ▼
renderer
```

对照 Blender 的修改器栈，**要素已有一半以上**：

| 要素 | 现状 | 差距 |
|---|---|---|
| 有序单向求值链 | ✅ 有，但固定 3 段且写死在两个生成器类里 | 泛化为可变长链 |
| 输出不写回原始数据（非破坏） | ✅ `Sdf`/`PcgDetail` 都是纯函数或原地改写后可丢弃 | 无 |
| 参数即 Resource（Inspector 可编辑、可存 .tres） | ✅ `Sdf`(15 类) / `PcgDetail`(2 类) 全是 `@tool Resource` | 无 |
| 脏标记 / 缓存 / 求值副本 | ⚠️ 部分：`PcgModelGenerator` 有 `_built` + `Mutex` 缓存，但没有"哪里变了、从哪复用" | 需要签名比对 |
| 对象模型（文档里的一个"物体"） | ❌ 没有。现在是 `VoxelData + VoxelGenerator + VoxelRenderer` 三件套手工组装 | 需新增 |
| 撤销 / 重做 | ❌ 全项目零 `UndoRedo` 引用 | 需新增 |
| 编辑器 UI（工具、面板、参数 Inspector） | ❌ 只有 `EditorImportPlugin` | 需新增 |

### 1.2 可直接复用的内核资产（**复用契约，但要重构实现**）

> 初稿写的是"一行不改"。**该结论已作废**：插件要按 `REFACTOR_PLAN.md` 的 P0~P4 重构
> （一致性收敛 → 拆 God 类 → 抽离无限层与表现层 → 统一流水线 → 格式收口）。
> 下表说的"可直接复用"指**契约与算法不需要重新发明**，不表示文件不动。

| 资产 | 位置 | 为什么契约可原样复用 |
|---|---|---|
| `Sdf` + 14 子类 | `addons/VoxelSupport/Sdf/` | 已是干净的 FIELD 域算子集；`sample(p) -> Vector2` 就是契约本身 |
| `PcgDetail` + 2 子类 | `Model/PcgWeather.gd`、`Model/PcgSurfaceTint.gd` | 已是干净的 VOXEL 域算子；`apply(volume, grid_size, seed)` 就是契约本身 |
| `PcgModel` 布局工具 | `Model/PcgModel.gd` | `index_of / empty_volume / set_voxel` 是体积布局的唯一权威，不再写第二套 |
| `VoxelChunk` 坐标工具 | `Runtime/VoxelChunk.gd` | chunk 尺寸 / halo / origin shift 的唯一权威 |
| `PcgSdfGenerator` | `Sdf/PcgSdfGenerator.gd` | FIELD → VOXEL 的光栅化器（其内联表面层按 §1.3 合并进修改器链） |
| `PcgModelGenerator` | `Model/PcgModelGenerator.gd` | VOXEL 源 → 逐 chunk 的适配器 |
| `VoxelChunkGenerator` / `VoxelMeshGenerator` | `Runtime/` | VOXEL → MESH 网格化器（贪婪合并已调优） |
| 原生层 | `Native/` + `gdextension/` | 网格生成 / LOD 降采样 / QVox 块编解码；C++ 性能热点 |
| QVox 编解码 | `Importers/` | 块式（块类型 + CRC + 自足头），工程数据可直接进 `HEAD`/`NODE`（§5 of REFACTOR_PLAN） |
| 世界结构（对象模型 + 修改器链） | `addons/VoxelSupport/Modifier/` | 已在内核内，前缀 `QVox*`；`QVoxDomain` 定义域契约，`QVoxModifier` 是链上的一个条目 |

**结论：不需要重新发明内核算法；但需要重构内核的组织方式。**
这是"重写"与"重构"的差别 —— QVoxelier 的价值不依赖推翻算法，而依赖把算法组织成可组合的链。

### 1.3 需要重新定位（"降级/抽离"而非"重写"）的部分

| 资产 | 现状问题 | 处置 |
|---|---|---|
| `VoxelRenderer.gd`（113 KB） | 单节点同时承担分块调度、LOD、流式、视锥剔除、碰撞体、材质、任务派发 | **在插件内重构**：mesh 构建管线/碰撞/材质缓存留下，LOD/流式/剔除/原点漂移抽成**可选·无限层**（`REFACTOR_PLAN.md` P2-1）。QVoxelier 只消费内核 API |
| `VoxelDestructible.gd`（78 KB） | `VoxelRenderer` 子类，兼"可编辑对象" | 拆出 `VoxelEditKernel`（无节点、无 `_process`、可无头调用）；粒子/掉落/健康度/级联进**可选·表现层** |
| `PcgSdfGenerator` 的内联表面层（`surface_ramps`/`top_tints`/`erode_strength`，约 130 行） | 把"体素域算子"**内联在光栅化器里**，于是同一功能有两条互不相通的实现路径（SDF 生成器内联一套、`PcgSurfaceTint`/`PcgWeather` 又一套），且**不能组合** | 按 P3-2 合并成一条链：先生成完整体积，再进修改器链。有限内核使这条合并第一次成为可能（完整邻域问题消失） |

> 注意初稿曾说"QVoxelier 侧只调用其纯光栅化形态（表面开关全关）"——**这也是错的**：
> 与插件解耦的正确做法不是绕开它，而是把它内部那条重复的路径合并掉。

### 1.4 风险点

| 风险 | 说明 | 对冲 |
|---|---|---|
| R1 内存 | VOXEL 段要求整块体积常驻：256³ × 4 B = 64 MB/对象 | 对象粒度化（MagicaVoxel 同样一次一块）；后续加"分块视口 + halo"的流式求值路径 |
| R2 分辨率变更作废一切 | 逐体素算子的缓存在 `voxel_size` 改变后全废 | 把 `voxel_size` 当**文档级不可变属性**（改它 = 明确的"重采样"命令，提示代价） |
| R3 MESH 段不可逆 | 网格域算子（倒角/减面）做完回不到体素 | 由"域只能单向降级"这条硬约束**明确禁止**，不假装能回去 |
| R4 FIELD→VOXEL 失真 | 体素化后再改 SDF 参数必须整块重光栅化 | 链的 FIELD 段是前缀；引擎缓存"光栅化结果"作检查点，改后半段不动前半段 |
| R5 主线程阻塞 | 全链重算可能数百毫秒 | 求值走 `WorkerThreadPool`；`ArrayMesh` 构建回主线程（与插件现有约束一致） |
| R6 算子契约被迫改基类 | 想让 `Sdf`/`PcgDetail` 继承新基类会很诱人 | **红线**：QVoxelier（独立仓库）→ 插件单向依赖，插件永不依赖 QVoxelier。算子契约用鸭子类型（§5.3）—— 世界结构本身已在内核的 `World/` 内，不需要新基类 |

---

## 2. 参考架构与借鉴取舍

### 2.1 Blender：Depsgraph + 修改器栈

抓到的关键机制：

- `obj.modifiers` 是**有序列表**，由 depsgraph 自顶向下求值；**结果不写回 `obj.data`**，
  只存在于 depsgraph 拥有的"求值副本"里。
- 由此推出三条：**顺序即语义**、`Apply` = 把求值结果固化回原始数据、无头读取必须用
  `evaluated_get(depsgraph)`。
- 修改器工作在**物体局部空间**，所以度量类参数（bevel 宽度、solidify 厚度）随物体缩放变化
  —— 这就是"加倒角前必须先应用缩放"的根因。
- 规范顺序：`生成拓扑(Mirror/Array) → 切割(Boolean) → 加厚(Solidify) → 倒角(Bevel) →
  平滑(Subsurf) → 形变(Armature) → 修着色 → 收尾(Triangulate)`。顺序颠倒有实测差异
  （Mirror→Subsurf = 171v/176f，Subsurf→Mirror = 196v/192f）。
- "禁用"只有 `show_viewport` 一个 Python 可见开关，且它是**全局性**的（对显示与一切
  Python 求值同时生效）。

**借鉴**：
- ✅ **original / evaluated 分离** → `QVoxObject`（参数 + 手绘体素）vs `QVoxEvalEngine.Result`
  （求值产物）。UI 与视口只读求值产物，撤销只回滚参数。
- ✅ **顺序即语义、非破坏** → 链有序单向，改参数不改数据。
- ✅ **修改器 = Resource** → 与插件现有 `Sdf`/`PcgDetail` 的设计一致，直接继承这个决定。
- ✅ **规范顺序** → 变成"域只能单向降级 + 编辑器实时校验并高亮违规修改器"，比 Blender 靠用户
  记住顺序更稳（Blender 无法阻止你把 Subsurf 放在 Mirror 前面）。
- ❌ **完整 depsgraph 不借鉴**。Godot 没有 depsgraph，硬造会引入大量样板而收益不明。
  我们用"单对象线性链 + 每修改器签名比对"实现同一目的（§6.1）。
- ❌ **不借鉴 `show_viewport` 这种"全局副作用式禁用"**。我们的 `modifier.enabled` 只影响该条目。

### 2.2 Zylann/godot_voxel（Voxel Tools）—— 最直接的对标

抓到的关键事实：

- 有完整的**生成器节点图** `VoxelGeneratorGraph`，**按体素求值**（"graph generators only
  work per voxel"），速度接近 C++ 生成器但只有基本指令。
- 图在内部会被**展开 + 优化掉**（`VoxelGraphFunction` "fully unpacked and optimized out
  internally"），于是**无法回溯到原节点**，编辑器里的 profiling / output preview /
  range analysis 在函数内部都不支持。作者自述"未来会把工具抽出来以通用化"。
- 有**非破坏修改器** `VoxelModifier`（`VoxelModifierSphere` / `VoxelModifierMesh`），
  但"功能有限（limited）"。
- 编辑器里**没有破坏性编辑工具**（"currently no tools to edit voxel volumes destructively
  in the Godot editor"），破坏性编辑只能在游戏内用 `VoxelTool` 做，或自建编辑器插件。
- 调试靠 `SdfPreview` 节点：把 3D 数据的一个**切片**显示成灰度/彩色图（`Ctrl+滚轮` 缩放、
  `Ctrl+中键` 平移、`Debug → Preview Axes` 切换 XY/XZ）；并明确警告"用噪声当 SDF 时梯度
  不一致，靠近表面过陡会导致精度损失或网格块状化"。
- 线程模型：生成器 API **线程安全**，按 block 工作以便多线程拆分；部分参数只能主线程改。

**借鉴**：
- ✅ **切片预览**是体素/距离场调试的最优解 —— 比旋转 3D 视口快得多。QVoxelier 第一版就做，
  但要升级成"预览**任意一个修改器之后**的数据"，这才是真正的逐修改器调试。
- ✅ **编译式求值**（图 → 指令序列 → 逐体素执行）比 GDScript 递归虚函数调用快得多。
  QVoxelier 的 FIELD 段折叠出树后是逐体素递归，这是第一版最大的性能风险，路线图留"折叠成
  平坦指令序列"的位置（§8 第三期）。
- ✅ **子图复用**（`VoxelGraphFunction`）→ QVoxelier 的"复合修改器"。
- ✅ **修改器与生成器分离**（`VoxelModifier` vs `VoxelGenerator`）→ 我们的"源"与
  "就地算子"也是两回事（§5.1）。
- ⚠️ **反例警告**：他们把图优化掉之后失去了与源节点的对应关系，逐节点调试工具就做不成。
  QVoxelier 必须**保留"修改器 ↔ 求值步骤"的映射**，绝不为了速度丢掉可调试性。
- ⚠️ **反例警告**：他们的"破坏性编辑"与"非破坏修改器"是两套互不相通的东西。QVoxelier 要把
  它们放进同一个文档模型（手绘基础体素 + 其上叠加非破坏链），这是易用性的关键。

### 2.3 Houdini SOP —— 全 DAG 范式

一切皆节点，`cook` 惰性求值，参数变更只脏化下游；节点可 bypass、可 lock。表达力最强，
但**门槛最高**：新手要先理解网络拓扑。

**借鉴**：✅ cook / 脏传播（只重算受影响的下游）；✅ bypass → 我们的 `modifier.enabled`。
**不借鉴**：❌ 全 DAG 直接暴露给用户。需求明确包含"使用起来更加简单易用"。

### 2.4 MagicaVoxel / Goxel —— 体素编辑器的直觉标准

- MagicaVoxel：**画笔工具族 + 图层 + 「世界/模型」两级**。它的优雅来自**工具即模式**
  （`V/F/B/L/C/P` 单键切换，没有嵌套菜单）。
- Goxel：稀疏块（brick）+ 每个操作一个 undo snapshot。

**借鉴**：
- ✅ **零层级工具栏**：单键切画笔模式，绝不做嵌套菜单。
- ✅ **图层**（文档模型一等公民，路线图第一期）。
- ✅ **「世界/模型」两级** → 对应我们的"文档 / 对象"。
- ✅ **有界模型语义**（据此划定 §0 边界）。
- ❌ **不做 path tracing 预览**（成本极高，与"通用易拓展"冲突）。改用"切片预览 + 快照渲染"。

### 2.5 稀疏体素存储（SVO vs 块网格）

调研到的工程共识很清晰：

- **全局稀疏 + 局部密集**的块网格（Open3D 的 Voxel Block Grid 语义：globally sparse,
  locally dense）是**编辑友好度与压缩率之间的帕累托最优**；
- 完整 SVO 的随机访问慢、编辑要重建层级，**对编辑型工具不友好**；
- 稀疏块常见三重压缩：存在位图（如 512 B 位图表示 4096 个块）+ 紧凑数组 + GPU 友好布局。

**结论：不换存储。** 现有 `VoxelChunk` 的 32³ 密集块 + 上层 chunk 字典，本来就是
"全局稀疏 + 局部密集"。QVoxelier 第一版连"稀疏"都不需要（有界模型全量常驻），所以这里
**刻意不做任何存储层优化** —— 追求 SVO 的渲染优势会牺牲编辑简单性，而编辑简单性才是目标。

### 2.6 Qt QUndoStack —— 撤销的标准范式

`QUndoCommand` 有 `undo()/redo()`，可用 `mergeWith()` 把连续细粒度命令压成一条，并有
`beginMacro/endMacro` 组合命令。

**借鉴**：✅ `QVoxCommand` 的 `redo/undo` + 栈 + 宏。
⚠️ **刻意不借鉴 `mergeWith`**：体素编辑的合并要处理盒子并集与中间态，容易出错。改用
**手势级单一命令**（一次拖拽 = 落笔前抓整个笔画的包围盒 `before`，拖完抓 `after`，只入栈
一条），语义等价而实现简单一个数量级（见 `QVoxVoxelEditCommand`）。

---

## 3. 方案对比

### 方案 A：轻量改造（在原插件内加对象模型 + 撤销）

- 做法：在 `addons/VoxelSupport/` 内新增 `QVoxObject`/`QVoxWorld`/`QVoxUndoStack`，给
  `VoxelRenderer` 加"编辑模式"。
- ✅ 改动最小，现有 demo 立刻可用。
- ❌ 插件变成"游戏运行时插件"与"编辑器软件"两副面孔，职责混乱。
- ❌ `VoxelRenderer` 的 113 KB 混合职责会继续膨胀（**这个文件是项目里唯一明确该减重的东西**）。
- ❌ 无法独立提取成单独项目。
- 适用：只想给现有 demo 加个雕刻功能。

### 方案 B：分层重建 ——「域降级链」引擎 + 独立 QVoxelier 目录 ★推荐

- 做法：新建 `QVoxelier/`，**把插件当只读内核库用**（一行不改）；核心四层：
  `Core`（文档 + 修改器链 + 求值引擎 + 撤销）/ `Operators`（三域算子）/ `Editor`（插件 UI）。
- ✅ **插件零改动** —— 内核稳定，现有 demo 与游戏运行时完全不受影响（最大的工程优势）。
- ✅ QVoxelier 目录可整体复制提取（只需同时带上 `addons/DEVFramework` 与 `addons/VoxelSupport`）。
- ✅ "域"显式化解决"体素修改器语义不清"的根本问题（§4.3）。
- ✅ 合并了插件里两条互不相通的表面处理路径（§1.3）。
- ❌ 需要新写求值引擎（预估 600~900 行）。
- ❌ 提取时要连插件一起带（要做到"零依赖提取"就得复制内核，代价是双份维护 —— **不划算，
  接受这个依赖**）。
- 适用：**目标就是独立体素建模软件**（本次需求）。

### 方案 C：完全重写（QVoxelier 自带一切）

- 做法：自研体素存储、网格化、SDF、编解码；插件仅作参考。
- ✅ 架构最干净，零 C++ 依赖。
- ❌ 丢掉原生层（C++ 网格生成 / LOD / QVox 编解码）与已调优的贪婪合并；这些代码质量已
  达标，重写是纯浪费。
- ❌ 成本极高（数千行 + 大量调优经验），收益为负。
- 适用：要彻底脱钩 C++，或目标平台不允许 GDExtension。

### 方案 D：节点图优先（Houdini / VoxelGeneratorGraph 式全 DAG）

- 做法：一切皆节点，UI 就是 `GraphEdit`；像 `VoxelGeneratorGraph` 那样把图编译成指令序列。
- ✅ 表达力最强；子图复用天然；可做全局优化。
- ❌ 直接违背"使用起来更加简单易用"。
- ❌ 体素画笔编辑（高频交互）反而要塞进图里，别扭。
- ❌ 参照 `godot_voxel` 的教训：图一被优化掉，逐节点调试工具就做不成（§2.2）。
- 适用：程序化生成优先、手工编辑为次的场景。

### 推荐

**取 B 为骨架，吸收 D 的子图能力（作为可选深度），保留 A 的渐进性（第一期绝不碰插件）。**

| 方案 | 我们吸收什么 | 我们改什么 |
|---|---|---|
| A | 渐进、复用内核 | 代码放独立目录、插件零改动 |
| B | 分层与域模型 | —— |
| C | —— | 拒绝重写，内核全部复用 |
| D | 子图复用、编译式求值 | 用**线性链**做默认 UI，子图藏进"复合修改器"（§4.4） |

---

## 4. 目标架构

### 4.1 分层

```
┌───────────────────────────────────────────────────────────────┐
│ App/Editor 层  QVoxelier（独立仓库/独立场景）                    │
│               EditorPlugin / Dock / 视口 / 工具栏 / 参数面板     │
│               只管 UI，不含算法                                 │
├───────────────────────────────────────────────────────────────┤
│ App/Core 层    QVoxelier/Core（应用能力）                        │
│               QVoxCommand ─ QVoxUndoStack ─ QVoxVoxelEditCommand │
│               （撤销 = 应用能力；extends 框架 GameCommand/History）│
├───────────────────────────────────────────────────────────────┤
│ Modifier 层    addons/VoxelSupport/Modifier（插件内的编辑模型）  │
│               QVoxWorld ─ QVoxObject ─ QVoxModifier ─ QVoxDomain │
│               QVoxEvalContext（纯逻辑，无场景节点/渲染，可无头） │
├───────────────────────────────────────────────────────────────┤
│ Operators 层  算子资源（FIELD / VOXEL / MESH 三域）             │
│               可直接复用：Sdf*(15) + PcgDetail*(2)             │
├───────────────────────────────────────────────────────────────┤
│ Kernel 层     addons/VoxelSupport（其余部分）                   │
│               PcgModel / PcgSdfGenerator(rasterize_field)      │
│               VoxelChunk / VoxelChunkGenerator / VoxelMesh...  │
│               Native（C++ 网格化 / QVox 编解码）                │
├───────────────────────────────────────────────────────────────┤
│ Framework 层  addons/DEVFramework（机制库，项目通用）           │
│               SaveTool / LogTool / AsyncTool / UITool / Def    │
└───────────────────────────────────────────────────────────────┘
```

**插件物理布局**（与上图的分层不是同一套轴：上图是逻辑分层，这里是文件放哪）：

```
addons/VoxelSupport/
├── Modifier/    9   编辑模型：QVoxWorld / Object / Modifier / Domain / EvalContext + 序列化
├── Sdf/        16   FIELD 域：Sdf 基类 + 14 子类 + PcgSdfGenerator（FIELD→VOXEL 光栅化器）
├── Model/      12   VOXEL 域：PcgModel + 6 子类（build）+ PcgDetail / Weather / SurfaceTint（apply）
│                    + PcgModelGenerator（切片适配器）+ PcgScatter（摆放工具）
├── Runtime/    18   体素运行时：QVoxSpec / QVoxFile / QVoxStream / VoxelChunk / 网格 / 渲染
├── Importers/   7   导入器（.vox / .qvox）
└── Native/          原生库 VoxelNative（构建产物）
```

> **目录即域**：算子的域边界就是它的契约 —— FIELD 域 `sample()` 进 `Sdf/`，VOXEL 域
> `build()` / `apply()` 都进 `Model/`。同一个域不该因为"建"和"改"分成两个目录：`PcgDetail`
> 本来就是 `PcgModel` 产出的后处理，拆开只会让人看两处才拼得出链怎么接。
>
> 每个域目录同时收下**把该域接到框架的那一个适配器**：`Sdf/` 收 FIELD→VOXEL 的
> `PcgSdfGenerator`，`Model/` 收 VOXEL→chunk 的 `PcgModelGenerator`、以及摆放 `PcgModel`
> 产出的 `PcgScatter`。于是"算子 + 它的产出通道"总在同一处，不必为 3 个适配器单开一层。
>
> 历史上被去掉的三层目录，理由都是同一个 —— **目录没能回答"这个文件该放哪"**：
> `Operators/` 只是把类名前缀（`Sdf*` / `Pcg*`）已表达的分类又写一遍；`Volume/` 与
> `Generator/` 各只装 3 个文件，而它们的边界（build vs apply、算子 vs 适配器）本就不是域。
>
> 原 `Shaders/voxel_raymarch.gdshader`（光线步进渲染器）已删除：全仓无任何引用 —— 没有脚本、
> 场景或材质指向它，渲染只走 `VoxelRenderer` 的网格路径。

**红线（不可违反）**：

1. 依赖方向只有向下。`addons/VoxelSupport` 与 `addons/DEVFramework` **两插件互不引用**，
   也**永不 import `QVoxelier`**；只有 `QVoxelier` 单向依赖两者。
2. 因此**撤销命令**（需引用 `GameCommand`）只能待在 `QVoxelier/Core`，不能放进 World 层；
   World 层只提供被操作的数据与链，不懂"谁按了 Ctrl+Z"。
3. QVoxelier 是纯消费者，内核稳定，且 QVoxelier 可以整体删掉而不影响任何现有功能。

### 4.2 文档模型

```
QVoxWorld                     一份世界 = 一个 .qvox 工程（常驻内存的唯一真值）
├── head / node / cach        HEAD、NODE、CACH 原样保留（格式层不解释未知键）
├── voxel_size                世界级体素边长（改它触发全链重算）
├── materials / palette       材质ID → 颜色（MATE 就是调色板本身，[0] 恒为空气）
├── objects: Array[QVoxObject]
│   └── QVoxObject               一块体素模型（对标 MagicaVoxel 的"模型"）
│       ├── grid_size          对象级分辨率上限（有界模型）
│       ├── blocks             手绘基础体素：块坐标 → PackedInt32Array(B³)
│       │                      **分块稀疏**：空块 = 块坐标缺失（不占内存、不落盘），
│       │                      块内布局权威 = QVoxSpec；撤销栈唯一改写的体素数据
│       ├── base_revision      每次手绘编辑自增 → 求值增量复用的钥匙
│       └── modifiers: Array[QVoxModifier]   非破坏链
└── revision                   世界级版本号（UI 刷新用）
```

> **与格式层的分工**：`QVoxWorld` 是活的编辑状态，`QVoxFile.QVoxDocument` 只是
> `QVoxFile` 解析/序列化那一瞬间的传输结构，两者由 `to_document()` / `from_document()`
> 一对显式转换连接，**不允许同时常驻**（否则同一份体素会有两个账本）。

`QVoxModifier`（**关键概念**，与 Blender 的"每条目自带参数实例"不同）：

```
QVoxModifier               共同基类：管"这一次怎么用"
├── op: Resource        算法核（SdfBox / PcgWeather / …），可被多个修改器共享
├── enabled: bool       旁通（Houdini 的 bypass）
├── combine: Combine    合成方式，只对 FIELD 域的**第一个**修改器有意义（§4.3）
├── blend: float        SMOOTH_UNION 的过渡宽度
├── seed: int           该条目的确定性骰子
    ├── QVoxSdfModifier      核 = Sdf 子树      域 = FIELD（引擎调 op.sample）
    ├── QVoxModelModifier    核 = PcgModel      域 = VOXEL 源（引擎调 op.build）
    └── QVoxVolumeModifier   核 = PcgDetail     域 = VOXEL 改写（引擎调 op.apply）
```

**域是类型而不是探测结果**：引擎不必再问"这个核有没有 `sample` 方法" —— 子类本身就是那份
契约，因此不可能构造出"自称连续域、核却只会 `apply`"的非法状态。

**为什么是"修改器持有使用参数"而不是"算子持有参数"**：同一个 `SdfBox` 资源可被两个修改器引用，
各自给不同的 `seed`/`combine`。这比 Blender"每次添加都新建实例"更接近 Houdini 的
"节点实例 + 共享资产"，也更省资源。

### 4.3 求值链与域降级

```
                    FIELD 段（0..n 个修改器）
blocks       ──────▶  fold 成一棵 Sdf 树（左结合）
（手绘体素）          修改器0: REPLACE      → acc = op0
                     修改器1: SUBTRACT     → acc = Subtract(acc, op1)
                     修改器2: SMOOTH_UNION → acc = SmoothUnion(acc, op2, blend)
                                        │
                                        ▼ ★ 隐式降级①：光栅化
                                        │   PcgSdfGenerator.rasterize_field()
                                        ▼
                 blocks ⨝ 光栅化结果   ← 按修改器0的 combine 做体素布尔
                                        │
                                        ▼
                    VOXEL 段（0..n 个修改器）
                      逐修改器 apply(volume, grid_size, seed) 原地改写
                      （PcgWeather 挖 → PcgSurfaceTint 上色）
                                        │
                                        ▼ ★ 隐式降级②：网格化
                                        │   VoxelMeshGenerator（视口/导出器调用）
                                        ▼
                    MESH 段（0..n 个修改器）
                      逐修改器 apply_mesh(arrays)
```

**两条硬规则**：

1. **域只能单向降级**：`FIELD(0) ≤ VOXEL(1) ≤ MESH(2)`，链上的域序号必须非递减。
   违反 → 编辑器**实时**在修改器上打红标并给出理由（而不是等到求值崩）。
2. **降级点由引擎自动插入**，用户看不见。这就是"易用"的来源：用户只管"我要在这儿加个
   侵蚀"，引擎知道那意味着"先把前面的 SDF 光栅化，再侵蚀"。

**为什么必须单向**：体素被钉死在格点上，一旦光栅化就回不到连续距离场。Blender 只有一个域
（Mesh）所以没这个问题；体素有。假装没有就会出现"这个修改器拿到的是距离场还是体素"的
歧义 —— 现有插件把三段写死，本质就是在回避这个歧义。把域显式化，歧义消失。

### 4.4 线性链承载 DAG（本设计的关键取舍）

- Blender = **线性列表**（简单，但表达力受限，且只能单域）。
- Houdini = **全 DAG**（表达力强，但门槛高）。
- **QVoxelier = 线性链 + 每修改器可挂一棵子图**。

两条路径：

1. **FIELD 段的 `combine`**：链上第 i 个 FIELD 修改器，语义是"把 `op_i` 以该方式合成进已累积
   的场"。线性读下来就是 `((op0 \ op1) ∪ op2)` —— **链天然表达了一棵左结合二叉树**，
   用户不需要理解树。
2. **复合修改器**（路线图第二期）：一个修改器内部是**子链**，折叠成一个算子。这是
   `VoxelGraphFunction` 的等价物，但**默认不暴露**，只在用户双击该条目时展开。

**结论：用线性链的心智模型承载 DAG 的表达力。** 这就是"更优雅 + 更强大"的具体含义。

---

## 5. 底层机制设计

### 5.1 三个域的契约

| 域 | 数据表示 | 契约（鸭子类型，见 §5.3） | 现有实现 |
|---|---|---|---|
| FIELD | 一棵 `Sdf` 表达式树 | `sample(p: Vector3) -> Vector2(距离, 材质ID)`；可选 `bounds() -> AABB` | `Sdf` + 14 子类 |
| VOXEL | `PackedInt32Array` + `Vector3i grid_size`（布局由 `PcgModel.index_of` 唯一确定） | 源：`build(grid_size) -> PackedInt32Array`；算子：`apply(volume, grid_size, seed)` | `PcgModel` / `PcgDetail` + 2 子类 |
| MESH | `Array`（`Mesh.ARRAY_*` 组成的 arrays） | `apply_mesh(arrays: Array) -> Array` | 暂无（路线图第三期） |

**"源"与"算子"的区别**（与 `godot_voxel` 的 `VoxelGenerator` vs `VoxelModifier` 同构）：

- **源**自足产出（`sample` / `build`）；
- **算子**就地改写既有数据（`apply`）。

判据是"有没有 `build`"，见 `QVoxDomain.is_source()`。这不是闲区分：**拿不到输入的算子
无法做布尔**——`PcgWeather` 已经吃到了整块体积，引擎不能在事后替它做"并/差"。

### 5.2 手绘基础体素 vs 链：为什么必须分开

画笔编辑是**高频、增量、要撤销**的；链是**低频、全量、参数化**的。把画笔做成链上的算子，
会让每次落笔触发整链重算，撤销还得回滚链参数。

Blender 的答案是把"编辑模式改网格"与"物体模式挂修改器"分成两种模式。QVoxelier 保留同一条
界线，但用更简单的形式表达：

> **手绘基础体素（`blocks`）是链的输入，不是链的一环。**

于是两条编辑路径职责彻底清晰：
- 手绘 → 写 `blocks`，`base_revision++`，手势封口成一条 `QVoxVoxelEditCommand` 入栈；
- 程序化 → 改 `slot`/`op` 参数，入栈一条参数命令（规划的 `QVoxPropertyCommand`），链的对应前缀被脏化。

而**两者可以组合**：手绘一块石头（`blocks`），再挂 SDF 修改器挖洞
（`slot0.combine = SUBTRACT`）—— 这正是"基础建模能力 + 修改器"的落点，也是
`godot_voxel` 缺失的那一环（它的破坏性编辑与非破坏修改器互不相通，§2.2）。

### 5.3 鸭子类型：零插件改动的复用方式

要让 `Sdf` 和 `PcgDetail` 直接当算子用，最直觉的做法是让它们继承一个 `QVoxOperator` 基类。
**不做**，理由有三：

1. 那要改 `addons/VoxelSupport` 的 17 个算子文件 → 违反"算子文件零改动"；
2. 会多出一个只声明方法签名的空壳基类（冗余抽象）；
3. 现有签名**已经就是契约本身**，包装一层没有信息增益。

改用**能力探测**，集中在 `QVoxDomain` 一处：

```gdscript
const CAP_SAMPLE     := &"sample"      # FIELD
const CAP_BUILD      := &"build"       # VOXEL 源（整体产出）
const CAP_APPLY      := &"apply"       # VOXEL 算子（就地改写）
const CAP_APPLY_MESH := &"apply_mesh"  # MESH 算子
```

代价是"能力靠方法名约定"，所以把**签名表集中在 `QVoxDomain` 一处**，全项目只此一份。
已有的 `Sdf`(15 个)/`PcgDetail`(2 个)**无需任何改动**即刻可入栈。

> 这正是 `DEVFramework/LAYERS.md` 里"鸭子类型协作"的用法：框架与项目之间靠方法签名协作，
> 而不是靠共享基类。共用基类会把两个本可独立演化的模块永久绑在一起。

### 5.4 修改器链示例（一张表看完全部语义）

| # | 修改器 | combine | 域 | 引擎动作 |
|---|---|---|---|---|
| — | （手绘石头） | — | VOXEL 种子 | `seed = blocks` |
| 0 | `SdfBox` | `REPLACE` | FIELD | fold 起点：`acc = SdfBox` |
| 1 | `SdfSphere` | `SUBTRACT` | FIELD | `acc = SdfSubtract{a: acc, b: SdfSphere}` |
| 2 | `SdfCapsule` | `SMOOTH_UNION(k=2)` | FIELD | `acc = SdfSmoothUnion{a: acc, b: SdfCapsule, k: 2}` |
| — | ★ 降级① | — | FIELD→VOXEL | 光栅化 `acc` → `field_vol`；`seed = REPLACE(seed, field_vol)` |
| 3 | `PcgWeather` | `REPLACE` | VOXEL | `PcgWeather.apply(seed, gs, 0)` |
| 4 | `PcgSurfaceTint` | `REPLACE` | VOXEL | `PcgSurfaceTint.apply(seed, gs, 0)` |
| — | ★ 降级② | — | VOXEL→MESH | `VoxelMeshGenerator` → `arrays` |
| 5 | `QVoxChamfer`（待实现） | `REPLACE` | MESH | `apply_mesh(arrays)` |

若把修改器 3 挪到修改器 1 前面（体素修改器在连续修改器之前），`QVoxDomain.validate_chain()` 会报
"修改器 1 是连续域，但链上已经降到体素域 —— 域只能单向降级"，编辑器红标该条目。

---

## 6. 求值引擎、撤销与工程文件

### 6.1 求值引擎（`QVoxEvalEngine`）

**契约**：`evaluate(obj, ctx, previous) -> Result`。纯函数，无状态，可无头调用、可多线程。

```gdscript
class Result:
    domain: QVoxDomain.Kind        # 链最终停在哪个域
    grid_size: Vector3i
    field: Sdf                    # FIELD 段折叠结果（保留 → 可做切片预览/调试）
    volume: PackedInt32Array      # VOXEL 结果
    mesh_ops: Array[QVoxModifier]   # 尚未应用的 MESH 修改器（由视口/导出器执行）
    input_signature: String       # 下次求值复用 `volume` 的钥匙
```

**增量复用（学 depsgraph 的 tag，但更简单）**：

1. 每个修改器算出 `signature`（旁通开关 + 算子类型 + 实例 id + 全部 `PROPERTY_USAGE_STORAGE`
   参数 + 合成方式 + 平滑量 + 种子；`Sdf` 子树的嵌套资源递归参与）→ 拼接成 `input_signature`。
   凡影响输出的字段都在签名里（显示名 `label` 不影响输出，故不在）。
2. 若 `previous != null && previous.input_signature == 本次 && 尺寸一致`
   → **直接复用 `previous.volume`，跳过光栅化**。
3. 否则重光栅化；VOXEL 段全量重跑。

**为什么只缓存"光栅化结果"这一个检查点**：光栅化是逐体素递归调用 `Sdf.sample()`
（`grid_size` 次 GDScript 虚函数调用），是整条链里**最贵的一步**；`PcgDetail` 是一次线性
遍历整块数组，便宜一到两个数量级。只缓一步就能吃掉绝大部分收益，而内存只需一份 volume。
若要更细粒度，就在 VOXEL 段每步后存检查点 —— 那是路线图第三期的事，且必须先有实测数据。

**签名为何要含实例 id**：参数只改一个数字时，改动点**之前**的修改器实例 id 与参数都不变，
前缀签名自然相同（虽然当前只用一个检查点，但这个设计为后续细粒度缓存预留了结构）。

**线程模型**（与插件现有约束保持一致，不发明新规则）：

- 求值只在 worker 线程读**快照**（`blocks` 是"块坐标 → `PackedInt32Array`"，按块复制即得快照）；
- 结果经 `call_deferred` 回主线程；
- `ArrayMesh` 构建只能在主线程（`VoxelMeshGenerator` 的既有约束）；
- 主线程改动对象参数时**不能阻塞在途 worker**：用"提交前比对 revision，不一致就丢弃"
  （`PcgModelGenerator._ensure_volume()` 已验证过这个模式，照抄）。

**保留可调试性**（`godot_voxel` 的教训，§2.2）：`Result` 必须携带 `field` 与"每个修改器对应的
求值步骤"，绝不为了速度把中间结果优化掉。切片预览（`SdfPreview` 的等价物）就靠它。

### 6.2 撤销（`QVoxCommand` / `QVoxUndoStack`）

**位置**：`QVoxelier/Core/`（应用层）。`QVoxCommand extends GameCommand`、
`QVoxUndoStack extends CommandHistory` —— 撤销栈与命令日志本是同一串数据，只差一个游标
（`commands[0..cursor)` 已生效，`[cursor..]` 是 redo 分支），于是"撤销栈"与"可回放日志"
不必各存一份、各写一遍序列化（`save_data()` 白得）。放在应用层而非 World 层，是因为它要引用
框架的 `GameCommand`，而两个插件之间必须零引用（§7）。

**命令类**：

| 命令 | 记录什么 | 代价 |
|---|---|---|
| `QVoxVoxelEditCommand` | 被改动的块坐标 → 该块 `before` / `after` 整块内容（`PackedInt32Array`） | 与实际改动的块数成正比，通常几十 KB |
| `QVoxPropertyCommand`（规划） | 对象 `set(prop, old)` / `set(prop, new)` | O(1) |

**体素编辑命令为何既不用全量快照、也不用"手势包围盒"**：一块 256³ 体积是 64 MB，每次落笔存
一份会瞬间爆内存；而一条长对角线笔画的包围盒又是整整 256³。故改为**按块懒采集**：写入时若
该块还没被抓过，先抓一块"改动前"的整块快照，再写；松手时对抓过的块收集"改动后"内容，并丢掉
前后相同的块（空操作零成本）。任意长笔画因此都能精确撤销，内存只与**实际改动量**成正比。

**手势即命令**（不学 `QUndoCommand.mergeWith`，§2.6）：

```
cmd = QVoxVoxelEditCommand.begin(obj)   → 开始手势（必须在任何写入之前，before 从"未改"状态抓）
... 拖拽中经 cmd.set_voxel()/fill_box() 写 obj（不入栈，为了 60fps）
cmd.commit()                            → 封口；返回 false 表示空手势，调用方**不要** push
stack.push(cmd)                         → 入栈并调一次幂等 redo()
```

拖拽过程中**不入栈**是关键：既避免高频命令，又天然满足"一次拖拽 = 一条撤销"。
`push()` 会对命令调一次 `redo()`，故 `redo()` 必须**幂等**（语义是"置为 after"，不是"施加增量"）。

**预算淘汰**：命令流随会话增长，超预算（`max_cost`）时从**队首**丢最老的（游标随之前移），
与 Godot `EditorUndoRedoManager` 的 `history_size` 限制同思路。

**刻意不从存档恢复撤销历史**：存档里只有参数记录、没有 `undo()` 能用的差值，恢复出来会是一个
"看着能撤销、按下去就报错"的假栈；明确报错好过静默给假栈（`QVoxUndoStack.load_data` 直接报错）。

**宏**（规划的 `begin_macro` / `end_macro`）：把"改参数 + 重命名"这类多步 UI 操作折叠成一条。

### 6.3 工程文件

**定案：单一 `.qvox`（qvox 3）**，不再有 ZIP 容器、也不再新增 `VSDS` 之类的文档块。

| 内容 | 落在哪 |
|---|---|
| 世界级设置（名称、`voxel_size`、作者） | `HEAD` 的 `world` 键 |
| 图层属性（可见/锁定/顺序）、相机书签 | `NODE` 的 `layers` / `cameras` |
| 每对象修改器链 | `NODE` 各节点的 `steps`（有序 `{type, params}`） |
| 每对象的手绘体素 `blocks`（**真值**） | `VOX0`（每 `model_id` 一块，**分块稀疏**、空块零字节，与内存布局同形） |
| 求值结果缓存、缩略图 | `CACH`（按 kind 区分，可随时删） |

**为什么不需要新块**：`HEAD` 与 `NODE` 本来就是 JSON，工程数据都是小型结构化数据，
扩展它们是零机械成本；`VOX0` 已经是大数据的合适容器。**"新功能 = 新块类型"这条原则
在工程数据上不适用**，因为工程数据不是"附加信息"，而是 `NODE` 这个块本来就该表达的内容。

**算子参数怎么存**：存**类型名 + 普通 JSON 参数**，不存 `Resource` 序列化
（`var_to_bytes`）—— 后者不可读、跨版本脆弱，一旦插件类改名就全部失联。
`Sdf` 子树按类型名 + 参数递归表达，与 `QVoxModifier` 的域契约一一对应。

**为什么用 QVox**：块类型 + CRC + 自足头已经就位（`Importers/`），且产出物能被现有导入器
直接读（**导出即所见**）。qvox 3 允许不兼容改版，因此结构可以一次做对，
不必靠补丁块堆出来。

---

## 7. 与插件、框架的依赖方向（红线）

QVoxelier 是**独立仓库/独立场景**，插件是它依赖的内核：

| 方向 | 允许 | 说明 |
|---|---|---|
| `QVoxelier`（独立仓库）→ `addons/VoxelSupport` | ✅ | 调用内核的"能力 API" |
| `QVoxelier` → `addons/DEVFramework` | ✅ | 复用机制（见下） |
| `addons/VoxelSupport` ↔ `addons/DEVFramework` | ❌ **禁止互引** | 否则任一插件都无法独立装卸、独立演化 |
| `addons/*` → `QVoxelier` | ❌ **禁止** | 反向依赖会让内核不能独立演化，且 QVoxelier 无法整体删除 |
| 世界结构（`Modifier/`）放哪 | **插件内** | 它是内核能力（对象模型 + 修改器链），不是应用层。QVoxelier 只做显示与操作翻译 |
| 撤销命令（`QVoxelier/Core/`）放哪 | **应用层** | 它要引用 `GameCommand`；放进插件会逼出插件间引用。且"谁响应 Ctrl+Z"本就是应用问题 |

**DEVFramework 的复用点**（遵循"实现功能优先用框架"）：

| 需求 | 用框架的 | 而不是 |
|---|---|---|
| 工程文件原子写 + 版本 + 备份 | `Tool/SaveTool.gd` | 自己 `FileAccess` + 手写备份 |
| 日志 | `Tool/LogTool.gd` | `print` |
| 后台求值任务 | `Tool/AsyncTool.gd`（或直接 `WorkerThreadPool`，与插件一致） | 自建线程池 |
| 编辑面板 / 面板栈 | `View/UIPanel.gd` + `Tool/UITool.gd` | 从 `Control` 重新拼 |
| 可配置资源（参数模板、默认值） | `Def/Def.gd` | 散落的 `@export` 默认值 |
| 输入映射（单键切画笔模式） | `Tool/InputTool.gd` | 硬编码 `Input.is_key_pressed` |

**不用的**：`ECS`（SoA 列存）。体素数据是**单块稠密数组**，本身已经是 SoA 的极致形态
（`PackedInt32Array` 连续内存、无指针追逐）；套一层组件系统只会增加间接层且让
`PcgDetail.apply(volume, grid_size, seed)` 这类既有契约失效。

---

## 8. 分期路线图

**顺序已调整为"先重构插件，再做应用"**（详见 `docs/REFACTOR_PLAN.md`）：

| 期 | 目标 | 交付 | 依赖 |
|---|---|---|---|
| **零期：插件重构** | 把内核从 God 类 + 无限层耦合里解出来 | `REFACTOR_PLAN.md` 的 P0（一致性收敛 + 回归测试网）→ P1（拆 God 类）→ P2（抽离无限层/表现层、抽出 `VoxelEditKernel`） | 无（先做） |
| **一期：可画可存** | 能替代 MagicaVoxel 做基础建模 | 插件侧：P3 统一修改器链 + `QVoxWorld`/`QVoxObject`/`QVoxModifier`/`QVoxEvalEngine`；`QVox`(qvox 3) 世界文件读写。QVoxelier 侧：独立场景 + 画笔工具族（体素/面/盒/线/填充）+ `QVoxUndoStack`/`QVoxVoxelEditCommand` | 零期 |
| **二期：链可用** | 把修改器链用起来 | 修改器面板（拖拽重排 + 域徽标 + 实时校验红标）；算子参数面板（内嵌 Inspector）；图层；复合修改器（子链） | 一期 |
| **三期：快与准** | 性能与网格域 | `FIELD` 段折叠成平坦指令序列（学 `VoxelGeneratorGraph` 的编译式求值）；逐步骤判脏与增量求值；`MESH` 段算子（倒角/减面/平滑） | 实测数据驱动 |
| **四期：走出去** | 与游戏运行时打通 | 导出为 `VoxelData` + `VoxelGenerator` 可用的资产；批量烘焙；脚本化 API | 稳定后 |

**为什么先做零期**：初稿曾主张"一期不碰插件"来规避风险。但这个风险是可以用
P0-6 的无头快照回归测试**量化**的（生成 → 网格 → 逐字节哈希），而绕开插件的代价是
把内核里最大的耦合源（双账本、God 类、无限层）永久固化 —— QVoxelier 会被迫在
它的外围再写一套变通逻辑。**先把内核拆干净，应用才会薄。**

---

## 9. 未决项（需要后续拍板）

| # | 问题 | 现状倾向 |
|---|---|---|
| 1 | 图层（MagicaVoxel 的 signature 能力）进一期还是二期 | 二期。一期的 `blocks` 单层已够验证链模型 |
| 2 | `voxel_size` 究竟是文档级还是对象级 | 世界级（避免"同世界两个对象尺度不同"导出时的换算地狱）。对象级若要，代价是导出要逐对象重采样 |
| 3 | 调色板是"材质ID → 颜色"还是"材质ID → 材质资源" | 颜色（MagicaVoxel 语义）。渲染材质由视口统一配置，与游戏运行时的 `VoxelRenderer` 材质策略分离 |
| 4 | 是否真的需要 MESH 段 | 需要（倒角/减面是"体素看起来更精致"的关键），但它不可逆，所以要显著提示 |
| 5 | 算子参数的"变更粒度为对象还是修改器" | 修改器。已于 `QVoxModifier` 里实现 |
| 6 | 稀疏存储何时引入 | **已引入**（一期）：`QVoxObject.blocks` 分块稀疏，空块不占内存/不落盘；原本"2048³ 以上才需要"的估算只看了上限，漏了"空块零成本"与"与 VOX0 同形、读写零转换"两条收益 |



