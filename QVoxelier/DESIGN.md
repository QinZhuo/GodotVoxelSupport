# QVoxelier 设计文档

> **目标**：一个**专为体素建模**的建模软件。对标 MagicaVoxel，但要求更优雅、更易用、功能更完整、
> 更通用、更易拓展。
>
> **本文只保留两样东西**：**核心设计目标（不可动摇的契约）** 与 **未来路线图（还没做的事）**。
> 已完成部分的实现细节写在代码注释里（本仓注释即规格，且随代码同生共死），本文不重复。

---

## 1. 定位与边界

| 维度 | QVoxelier 负责 | 明确不负责（由插件的扩展层负责，§2.12） |
|---|---|---|
| 世界 | **一棵节点树（组 / 模型）**；每个模型 = 一块 `grid_size` 立方体（MagicaVoxel 语义） | 无限世界、流式加载、LOD、原点漂移 |
| 分辨率 | 世界级固定 `voxel_size`，改它触发全链重算 | 逐视点 LOD 切换 |
| 交互 | 手绘体素 + 非破坏修改器链（可挂在任意节点上）+ 撤销重做 | 运行时破坏（`VoxelDestructible`） |
| 时间 | **交互期（编辑器内）** | 每帧游戏循环 |
| 输出 | 体素数据 / 网格 / `.qvx` 世界文件（**无损存档**）/ `.vox`（**给外部工具的导出**） | 游戏内渲染调度 |

**两条出口，别混**：`.qvx` 存的是"下次还能接着编辑"的全套（修改器链 / 材质 PBR / 相机 / 帧），
`.vox` 只留**烘出来的体素与调色板** —— 它是给 MagicaVoxel 这类外部工具的交换格式，不承担存档职责
（也因此不写 MATL：`.vox` 的交换语义就是调色板）。导出走 `VoxAsset.from_world` 把整棵树求值成
**一块**体积：世界怎么合成这件事全项目只有 `QVoxelEvalEngine.evaluate_world` 一份实现，导出不该
再有一套"编辑器版合成"。多模型的层级结构不保留 —— `.vox` 表达"多个对象"要靠场景图，而那是另一条
语义路径（需先有"每个模型独立摆放"的概念）。

**为什么必须先划这条界**：体素域算子（侵蚀、风化、连通性清理）需要**完整邻域**，这与
"惰性按 chunk 生成、只持有 32³"的流式架构天然冲突。把每个模型定位成"有界盒"、世界只是
"若干有界盒的一棵树"，这个矛盾就消失了 —— 而这正是 MagicaVoxel 的定位。两者互补，不是替代关系。

**这条界也决定了插件的分层**：既然有界模型与视点无关，插件里"LOD / 流式 / 剔除 / 原点漂移"
就都属于**扩展层**（§2.12），与内核的模型求值链路互不引用 —— 模型定位的一次决定，同时解开了
插件最大的耦合源。

---

## 2. 核心设计目标（红线；改任何代码前先读）

### 2.1 分层与依赖方向

```
┌────────────────────────────────────────────────────────────────┐
│ App/Editor 层  QVoxelier/View   Dock / 视口 / 工具栏 / 面板      │
│                                 只管 UI，不含算法                │
├────────────────────────────────────────────────────────────────┤
│ App/Command 层 QVoxelier/Command + Editing（应用能力）           │
│                QVoxelCommand ─ QVoxelUndoStack ─ QVoxelEditSession     │
│                （撤销 = 应用能力；extends 框架 GameCommand）     │
├────────────────────────────────────────────────────────────────┤
│ View 层        addons/VoxelSupport/Render                        │
│                VoxelRenderer（MeshInstance3D）—— 持 QVoxelSource │
│                投影成网格：求值 → 切片 → 网格化 → 上传           │
│                （唯一的场景节点；它之上才有"渲染"这回事）        │
├────────────────────────────────────────────────────────────────┤
│ Modifier 层    addons/VoxelSupport/Modifier（插件内的编辑模型）  │
│                World ─ Node ─ Group ─ Model ─ Modifier ─ Engine  │
│                （纯逻辑，无场景节点 / 渲染，可无头）             │
├────────────────────────────────────────────────────────────────┤
│ Operators 层   算子资源（FIELD / VOXEL 两域）                   │
│                Sdf/（FIELD）+ Model/（VOXEL）                    │
├────────────────────────────────────────────────────────────────┤
│ Kernel 层      addons/VoxelSupport/Runtime + Importers           │
│                格式 QVoxelSpec / QVoxelFile / Codec             │
│                体素 VoxelChunk / VoxelMaterial                  │
│                网格 VoxelMesh / VoxelMeshGenerator / Batch      │
│                Native（C++ 网格化 / QVX 编解码）                │
├────────────────────────────────────────────────────────────────┤
│ Framework 层   addons/DEVFramework（机制库，项目通用）           │
│                SaveTool / LogTool / AsyncTool / UITool / Def     │
└────────────────────────────────────────────────────────────────┘
```

**红线（不可违反）**：

1. 依赖方向只有向下。`addons/VoxelSupport` 与 `addons/DEVFramework` **两插件互不引用**，
   也**永不 import `QVoxelier`**；只有 `QVoxelier` 单向依赖两者。
2. 因此**撤销命令**（需引用 `GameCommand`）只能待在 `QVoxelier/Command`，不能放进 World 层；
   World 层只提供被操作的数据与链，不懂"谁按了 Ctrl+Z"。
3. QVoxelier 是纯消费者：内核稳定，且 QVoxelier 可以整体删掉而不影响任何现有功能。
4. **View 层在 Modifier 层之上**：`VoxelRenderer` 持 `QVoxelSource`（§2.11），后者持 `QVoxelNode`
   （Modifier 层），而 Modifier 层**永不知道渲染** —— 它不认识 `MeshInstance3D`、不认识任何 `Node`。
   这条是"Modifier 层可无头"的全部依据。**反向即错**：渲染器若留在 Kernel 层（底层），就必然逼出
   "体积容器 / 取数器"这道中间缝 —— 因为底层无法向上要 node。

**目录即域，且域要能被名字说清**：目录名回答"这一类东西是什么"，不是"这里有几件东西"
（一律单数：`Command/`、`Tool/`、`Modifier/`）。**不用 `Core/` 这种包罗万象的名字** —— 它回答不了
"新文件该放哪"，于是一时想不清归属的文件都会流进去，最后它就是个筐。

**算子文件零改动**：算子契约用鸭子类型（§2.5），不给 `Sdf` / `PcgDetail` 加新基类 —— 共用基类会把
两个本可独立演化的模块永久绑在一起。

### 2.2 数据模型：一棵节点树

```
QVoxelWorld  extends QVoxelNode     一份世界 = 一个 .qvx 工程（常驻内存的唯一真值）
├── head / node / cach          HEAD、NODE、CACH 原样保留（格式层不解释未知键）
├── voxel_size                  世界级体素边长（改它触发全链重算）
├── materials / palette         材质ID → 材质（含基色 / 粗糙度 / 金属度 / 透明度 / 自发光；[0] 恒为空气）
├── children: Array[QVoxelNode]  场景树顶层（有序）—— 即 NODE.nodes 的来源
└── revision                    世界级版本号（UI 刷新用）

QVoxelNode（抽象基类）            树上一个节点的共同契约 —— 世界 / 组 / 模型都继承它
├── node_name / visible / locked
├── modifiers: Array[QVoxelModifier]  本节点自己的滤镜链（**摆放也是其中一条**）
├── parent                      运行时结构（不入档；子→父不存，避免 RefCounted 环）
└── children()                  子节点表（组与世界有值，模型为空）

QVoxelGroup  extends QVoxelNode     组 = 文件夹（容器；唯一可持有子节点）
└── children: Array[QVoxelNode]

QVoxelModel  extends QVoxelNode     模型 = 图层（叶子；唯一持有手绘体素）
├── grid_size                   模型级分辨率上限（有界盒）
├── blocks                      手绘基础体素：块坐标 → PackedInt32Array(B³)
│                               **分块稀疏**：空块 = 块坐标缺失（不占内存、不落盘）
└── base_revision               每次手绘编辑自增 → 求值增量复用的钥匙
```

**为什么是树，而不是"对象数组 + 扁平图层"**：层与对象本是同一件事的两半 —— 层负责分组、可见性、
顺序，对象负责内容。拆成两张表，改一处就得同步另一处（删一层要连带撤销层内对象的归属）。合成
一棵树后，"分组 / 可见 / 锁定"是节点属性，"挂滤镜 / 摆放"是链上的条目 —— **每样只有一处真值**，
也不需要"层"这个概念 —— **组就是层**。

**为什么组也能挂修改器**：这就是"在层级上挂滤镜"（PS 的组调整图层 / 组蒙版）。组的链作用于
**子树合并结果**，于是"给整组岩石统一去色 / 侵蚀 / 镜像"是一件事，而不是逐个模型做十遍。

**为什么模型是叶子**：模型是唯一持有手绘体素的东西（§2.4）。组不存体素，它的内容是子树的合成
结果 —— 这条界线让"组"的内存成本为零，也让"组"不需要画布尺寸（见 §2.3 紧致盒）。

**为什么世界也是节点**：`QVoxelWorld` 继承 `QVoxelNode`。世界本就是这棵树的根 —— 它拥有"一组顶层节点"，
这层关系就是 `children()`。于是世界也能挂修改器（对**整世界合成结果**施加，与组滤镜同构），
"根节点"也不再是一个特例。

**组与世界的子节点是同一个概念**：顶层节点表就是 `QVoxelWorld.children()`，也是 `NODE.nodes` 的来源，
**没有序列化代价** —— 顶层节点的父是 `World`，而 `World` 自己不写进 `NODE.nodes`，嵌套形状不变。

**命名**：`QVoxelModel` 对标 MagicaVoxel 的 model，也贴合"图层"心智。

> **与格式层的分工**：`QVoxelWorld` 是活的编辑状态，`QVoxelFile.QVoxelDocument` 只是解析 / 序列化那一
> 瞬间的传输结构，两者由 `to_document()` / `from_document()` 显式转换连接，**不允许同时常驻**
> （否则同一份体素会有两个账本）。

**体素布局只有一份权威**：`PcgModel.index_of`（x 步长 1、y 步长 w、z 步长 w·h）。
任何重排 / 重采样都不得自造第二种下标约定。

**材质 PBR 标量只有一对入口**：`QVoxelWorld.material_scalar()` / `set_material_scalar()`
（键 `metal` / `rough` / `emission`，值域 0–1）。UI 与渲染都从这对入口走，不各自解释 MATE 字节。
**其中自发光按"相对强度"存**：MATE 用 `e_r/e_g/e_b` 存**发光颜色**（= 基色 × 强度），单通道强度只能从它
还原 —— 若照 `VoxelMaterial.to_mate` 那样写"基色 × 强度"，读回 `max()` 会再乘一遍基色亮度，滑条一松手
就跳值。故写入时按基色的最大分量归一，使 `max(e) == 强度`（读回恒等于写入）；渲染侧（`emission_color`）
仍是"基色 × 强度"，语义不变。

**`.vox` 出口只有一处实现**：`VoxAsset.from_result()`（世界 / 组 / 模型三条出口共用它）。
"一块体积怎么变成 `.vox`"含 Z 翻转那套约定，多一条出口就多一处能写错的地方；故批量导出新增的是
`VoxAsset.from_node()`（换求值来源），而不是第二份搬运代码。
**上限判据也只有一处**：`VoxAsset.fits_magica()`（MagicaVoxel 的 256³ 按**单轴**判，超了它不报错、
直接截断）—— 单次导出与批量导出问的是同一句。
**批量切分是应用层纯逻辑**：范围枚举 / 命名消毒去重 / 空与超限的跳过判定都在 `QVoxelBake`，
视口只递一个范围编号进来、拿一句提示语回去。理由与 `QVoxelProject` 同：这三件事错了都不报错，
只会让用户拿到"看起来正常"的错东西（文件名带 `/` 写到别处、同名节点互相覆盖、超限文件被静默截断），
住在视口里就一条都测不了。

### 2.3 树形求值：自底向上 + 紧致盒

```
eval(node) -> 体积 + 摆放（在 node 自己的局部盒里）
  QVoxelModel: v = blocks → 密集体积（node.grid_size 盒）
             v = 依次应用 node.modifiers          # 含变换 / 平移条目（可改盒尺寸与摆放）
  QVoxelGroup: acc = 空
             for child in children（可见者）:
                 cv  = eval(child)
                 acc = composite(acc, cv, cv.origin)   # 摆放取自子结果（链的产出），恒为并集
             acc = 依次应用 node.modifiers        # 组滤镜作用于合并结果
  世界     = 把所有顶层节点按各自 origin 合成进世界盒
```

- **紧致盒**：组的中间体积取"子树内容的并集包围盒"，而不是世界级画布。于是组不产生全量分配
  （512³ 的一次分配就是 537 MB），也不因为"组里只有两个小模型"而付整张画布的代价。组因此
  **没有"固定画布"字段** —— 需要补边时用一条"画布 / 补边"修改器表达。
- **顺序即语义**（与 Blender 修改器栈同理）：模型的滤镜作用于"自己的手绘体素"；组的滤镜作用于
  "已经摆好的子树合成结果"。链**内**的顺序仍由 §2.5 的单向降级规则约束。
- **可见性 / 锁定沿树继承**：父节点不可见 → 整棵子树不参与求值；父节点锁定 → 整棵子树不可编辑
  （但仍照常求值，因为它可能是别的节点的输入）。

**为什么摆放（`position`）也是一条"变换修改器"，而不是节点字段**：摆放（我在父画布里站哪儿）与
"对内容做一次变换"要回答同一组问题 —— 谁先谁后、能否旁通、怎么撤销、怎么落盘。留在节点上就等于
给"变换"开第二个入口：链上的旋转 / 镜像得回答"我和节点摆放谁先谁后"，而"拖一下组"要另写一套命令、
另写一套存档、另写一套重排规则。入链之后它自动获得链上的一切待遇（§2.7 的 `QVoxelTransformModifier`
+ `PcgTransform` 的 `TRANSLATE`），**全项目只有一种画法**。

**它为什么不改盒尺寸**：平移改的是"盒站哪儿"而不是"盒里怎么排"。硬按"往盒里补零把内容推到偏移处"
来做，负偏移就无从表达（盒的左下角恒在 0），远处的一个模型也会撑出一只巨盒。故 `reshape()` 对平移
原样交还体积与尺寸，位移由 `PcgTransform.origin_delta()` 单独回答、引擎累加进 `QVoxelEvalResult.origin`
（详见 `PcgTransform` 类头）。

**节点上没有 `combine`**（"我怎么并进父画布"）：那是个**父侧**问题（要同时看见父已累积的内容与本子
节点的内容），而链只能看见自己，故它没有链上的等价物。组这一层因此**恒为并集**，"挖空"改由节点
自己的链表达（链上的差集条目）。真要跨节点布尔时，引入的是显式的**布尔节点**，而不是节点字段。

### 2.4 手绘体素是链的**输入**，不是链的一环

画笔编辑是**高频、增量、要撤销**的；链是**低频、全量、参数化**的。把画笔做成链上的算子，会让
每次落笔触发整链重算，撤销还得回滚链参数。Blender 用"编辑模式 / 物体模式"分界，QVoxelier 保留
同一条界线但形式更简单：

> **`blocks`（手绘基础体素）是链的输入，不是链的一环。**

于是两条编辑路径职责彻底清晰，且**可以组合**（手绘一块石头，再挂 SDF 修改器挖洞
`combine = SUBTRACT`）：

- 手绘 → 写 `blocks`，`base_revision++`，手势封口成一条 `QVoxelEditCommand` 入栈；
- 程序化 → 改修改器 / 节点属性，入栈一条 `QVoxelPropertyCommand`，链的对应部分被脏化。

### 2.5 两个域与**单向降级**

| 域 | 数据表示 | 契约（鸭子类型） | 现有实现 |
|---|---|---|---|
| FIELD | 一棵 `Sdf` 表达式树 | `sample(p) -> Vector2(距离, 材质ID)`；可选 `bounds() -> AABB` | `Sdf` + 子类 |
| VOXEL | `PackedInt32Array` + `Vector3i grid_size` | **源**：`build(grid_size)`；**就地改写**：`apply(volume, grid_size, seed)`；**重排**：`reshape(volume, grid_size) -> [volume, grid_size]` | `PcgModel` / `PcgDetail` / `PcgTransform` |

**能力探测集中在 `QVoxelDomain` 一处**（全项目只此一份签名表）：

```gdscript
const CAP_SAMPLE     := &"sample"      # FIELD
const CAP_BUILD      := &"build"       # VOXEL 源（整体产出）
const CAP_APPLY      := &"apply"       # VOXEL 就地改写
const CAP_RESHAPE    := &"reshape"     # VOXEL 重排（**可改盒尺寸**）
```

**"源"与"算子"的区别**（与 `godot_voxel` 的 `VoxelGenerator` vs `VoxelModifier` 同构）：源自足产出
（`sample` / `build`），算子就地改写既有数据（`apply` / `reshape`）。判据是"有没有 `build`"
（`QVoxelDomain.is_source()`）。这不是闲区分：**拿不到输入的算子无法做布尔** —— `PcgWeather` 已经
吃到了整块体积，引擎不能在事后替它做"并/差"。

**两条硬规则**：

1. **域只能单向降级**：`FIELD(0) ≤ VOXEL(1)`，链上的域序号必须非递减。违反 → 编辑器
   **实时**在该修改器上打红标并给出理由（而不是等到求值崩）。
2. **降级点由引擎自动插入**，用户看不见。这就是"易用"的来源：用户只管"我要在这儿加个侵蚀"，
   引擎知道那意味着"先把前面的 SDF 光栅化，再侵蚀"。

**为什么必须单向**：体素被钉死在格点上，一旦光栅化就回不到连续距离场。Blender 只有一个域
（Mesh）所以没这个问题；体素有。把域显式化，歧义就消失了。

**为什么没有第三个域（MESH）**：体素格点本身就是这种表现形式的最小可改元素（同像素画的像素）。
倒角 / 减面 / 平滑改的是**网格拓扑**，而拓扑不是体素这一侧的语义 —— 让体素"更精致"的办法是把它
画得更细。因此 VOXEL 就是链的终点，不设 MESH 域，也不留网格算子钩子。

### 2.6 线性链承载 DAG

- Blender = **线性列表**（简单，但表达力受限，且只能单域）。
- Houdini = **全 DAG**（表达力强，但门槛高）。
- **QVoxelier = 线性链 + 每修改器可挂一棵子图**。

两条路径：① FIELD 段靠 `combine` —— 链上第 i 个 FIELD 修改器语义是"把 `op_i` 以该方式合成进已累积
的场"，线性读下来就是 `((op0 \ op1) ∪ op2)`，**链天然表达了一棵左结合二叉树**；② **复合修改器**
（路线图三期）：一个修改器内部是**子链**，折叠成一个算子，**默认不暴露**，只在双击该条目时展开。

> **结论：用线性链的心智模型承载 DAG 的表达力。** 这就是"更优雅 + 更强大"的具体含义。

### 2.7 修改器：参数在修改器，算法核可共享（含"变换即修改器"）

```
QVoxelModifier               共同基类：管"这一次怎么用"
├── op: Resource        算法核（SdfBox / PcgWeather / PcgTransform / …），可被多个修改器共享
├── enabled: bool       旁通（Houdini 的 bypass）
├── combine: Combine    合成方式，只对 FIELD 域的**第一个**修改器有意义
├── blend: float        SMOOTH_UNION 的过渡宽度
├── seed: int           该条目的确定性骰子
    ├── QVoxelSdfModifier       核 = Sdf 子树       域 = FIELD（引擎调 op.sample）
    ├── QVoxelModelModifier     核 = PcgModel       域 = VOXEL 源（引擎调 op.build）
    ├── QVoxelVolumeModifier    核 = PcgDetail      域 = VOXEL 改写（引擎调 op.apply）
    └── QVoxelTransformModifier 核 = PcgTransform   域 = VOXEL 重排（引擎调 op.reshape）
```

**域是类型而不是探测结果**：引擎不必再问"这个核有没有 `sample` 方法" —— 子类本身就是那份契约，
因此不可能构造出"自称连续域、核却只会 `apply`"的非法状态。

**为什么是"修改器持有使用参数"而不是"算子持有参数"**：同一个 `SdfBox` 资源可被两个修改器引用，
各自给不同的 `seed` / `combine`。这比 Blender"每次添加都新建实例"更接近 Houdini 的"节点实例 +
共享资产"，也更省资源。

#### 变换即修改器（万物皆修改器）

镜像 / 旋转 90° / 平铺 / **平移**都是链上的普通修改器，不是"独立的特殊功能模块"：

```
QVoxelTransformModifier   核 = PcgTransform   域 = VOXEL（变换 / 摆放）   引擎调 op.reshape(volume, grid_size)
```

- **好处**：变换因此**可重排、可旁通、可参数化、可撤销**（就是链上的一条），并与其它修改器共用
  同一套面板 / 校验 / 序列化 —— 没有"变换面板"这第二个入口，也没有"变换不入链、改完不可逆"。
  **摆放（平移）搭的就是这趟车**：节点上因此没有 `position`，也没有"节点摆放 vs 链上旋转谁先谁后"
  这个必须回答两次的问题（§2.3）。
- **代价**：VOXEL 算子契约要加一个**可选**的 `reshape(volume, grid_size) -> [volume, grid_size]`
  （"能改盒尺寸"的能力）。这是 `apply`（就地改写）之外的第二类能力，判据仍是**方法存在性**
  （§2.5 的零改动接入原则不变：不给算子加基类）。平移借用同一条通道，但它的 `reshape` 是恒等 ——
  位移由 `origin_delta()` 单独回答（§2.3 已述）。
- **实现**：整数格语义完全复用现成的 `QVoxelTransform`（置换 + 符号的 48 种双射 + 平铺复制族）
  —— 它已经是纯数据重排、可无头测试，只是从"App 的变换面板直接改写对象"改为"由链上的修改器驱动"。
- **校验**：`reshape` 条目只能是**替换**（整块结果的盒尺寸 / 摆放由它自己决定，谈不上"并进已累积
  结果"）—— 这条并入 `QVoxelDomain.chain_errors`；且它必须消费"已光栅化的当前累积结果"，故其域恒为
  VOXEL。

**校验的单一真值**：`QVoxelDomain.chain_errors(modifiers) -> [{"index", "message"}]` 是规则的唯一实现
（`validate_chain()` 只是它投影出的字符串数组）。UI 据此**在出问题的那一行**打红标，而不是解析中文串。

### 2.8 撤销 = 应用能力

**位置**：`QVoxelier/Command/`（应用层）。`QVoxelCommand extends GameCommand`、
`QVoxelUndoStack extends CommandHistory` —— 撤销栈与命令日志本是同一串数据，只差一个游标
（`commands[0..cursor)` 已生效，`[cursor..]` 是 redo 分支），于是"撤销栈"与"可回放日志"不必各存
一份、各写一遍序列化（`save_data()` 白得）。

| 命令 | 记录什么 | 代价 |
|---|---|---|
| `QVoxelEditCommand` | 被改动的块坐标 → 该块 `before` / `after` 整块内容 | 与实际改动的块数成正比，通常几十 KB |
| `QVoxelPropertyCommand` | 一次属性赋值：节点改名 / 可见锁定 / 修改器参数（**含平移条目的偏移，即摆放**） / **链与树的结构增删重排** → `(目标, 属性名, 改前, 改后)` | O(1)：只存前后两个值 |
| `QVoxelMacroCommand` | 一组子命令（按序 redo / 逆序 undo），子命令不进栈 | 子命令代价之和 |

- **体素命令按块懒采集**：一块 256³ 是 64 MB，全量快照会爆内存；改为写入时按块抓"改动前"、
  松手时收集"改动后"，并丢掉前后相同的块。内存只与**实际改动量**成正比。
- **手势即命令**（不学 `QUndoCommand.mergeWith`）：`begin() → 拖拽中写入（不入栈）→ commit() →
  push()`。拖拽中不入栈既避免高频命令，又天然满足"一次拖拽 = 一条撤销"；`push()` 会对命令调一次
  `redo()`，故 `redo()` 必须**幂等**（语义是"置为 after"，不是"施加增量"）。
- **链与树编辑不需要新命令类**：`nodes` / `modifiers` 本身就是属性 —— 加节点、移父级、重排 = 同一个
  属性的两种取值。让增 / 删 / 排各写一个命令类就是把同一段采集逻辑抄三遍，且迟早有一处忘了采
  "改后"。工具只剩一件事：**把改动夹在 `begin()` 与 `commit()` 之间**。
- **属性命令不能撤销 `resize_grid()`**：改分辨率会丢掉超出新尺寸的体素，而"被丢掉的体素"只有记差值的
  `QVoxelEditCommand` 记得住。改分辨率必须走体素命令（`QVoxelEditSession.apply_transform` 即范例）。
- **标脏由命令负责**：`QVoxelModifier` 是 `Resource`，Godot 不会替我们监听它的 `@export` 改动，所以
  "改参数要标脏"由 `QVoxelPropertyCommand` 在 `redo()` / `undo()` 之后补发；`set_value()` 刻意**不发信号**
  （改参数触发整链重算，一次拖拽若逐帧发信号就是成千上万次重算，live 预览由发起手势的面板自己刷新）。
- **刻意不从存档恢复撤销历史**：存档里只有参数记录、没有 `undo()` 能用的差值，恢复出来会是"看着能
  撤销、按下去就报错"的假栈；明确报错好过静默给假栈。
- **预算淘汰**：命令流超预算时从**队首**丢最老的（游标随之前移）。**宏**（`begin_macro` / `end_macro`）
  把"改参数 + 重命名"这类多步 UI 操作折叠成一条，其间的 `push()` 只攒进当前宏。

### 2.9 工程文件：单一 `.qvx`（qvx 3）

**单一 `.qvx`**：没有 ZIP 容器，也没有 `VSDS` 之类的额外文档块。

| 内容 | 落在哪 |
|---|---|
| 世界级设置（名称、`voxel_size`、作者） | `HEAD` 的 `world` 键 |
| **节点树**（组 / 模型、名称、可见 / 锁定） | `NODE` 的 `nodes`（**嵌套**） |
| 每个节点的修改器链（**摆放也是其中一条**） | 各节点的 `steps`（有序 `{type, params}`） |
| 相机书签 | `NODE` 的 `cameras` |
| 每个**模型**的手绘体素 `blocks`（**真值**） | `VXEL`（按 `model_id` 分块、**分块稀疏**、空块零字节） |
| 求值结果缓存、缩略图 | `CACH`（按 kind 区分，可随时删） |

节点条目形状：

```json
{"kind":"group","name":"岩石组","visible":true,"locked":false,
 "steps":[],
 "children":[
   {"kind":"model","model_id":3,"name":"岩石A","size":[32,32,32],
    "steps":[{"kind":"transform","combine":0,"type":"PcgTransform",
              "params":{"mode":3,"offset":[2,0,0]}}]}]}
```

- `kind` 是判别键：`"group"` / `"model"`；**未知 kind 按"失联即丢弃"处理**（读盘失败不造空壳）。
- `size` 只写在模型上（组没有自己的画布尺寸，见 §2.3）。
- **摆放不是节点字段**：它是 `steps` 里的一条平移条目（上例），合成方式由各条目自己的 `combine`
  承载。没有平移条目 = 原样堆在原点。
- **算子参数存"类型名 + 普通 JSON"**，不存 `Resource` 序列化（`var_to_bytes`）—— 后者不可读、
  跨版本脆弱，插件类一改名就全部失联。`Sdf` 子树按类型名 + 参数递归表达。
- **帧动画不走 `animations` 键**：节点局部的 `anim` 键（时间轴元数据）+ 新块类型 `FRAM`（块级增量帧），
  完整方案见 `docs/QVX_FORMAT.md` §12。

**版本门：不提供兼容读取路径**：

`HEAD.qvx` 必须等于当前版本，否则整个文件拒绝（见 `QVoxelSpec.VERSION`）。**宁可拒绝，不可误读** ——
让每个读者都长期背着一份只对历史文件有用的折叠 / 迁移逻辑，是纯负担。

### 2.10 复用优先（遵循"实现功能优先用框架"）

| 需求 | 用框架的 | 而不是 |
|---|---|---|
| 工程文件原子写 + 版本 + 备份 | `Tool/SaveTool.gd` | 自己 `FileAccess` + 手写备份 |
| 日志 | `Tool/LogTool.gd` | `print` |
| 后台求值任务 | `Tool/AsyncTool.gd`（或 `WorkerThreadPool`，与插件一致） | 自建线程池 |
| 编辑面板 / 面板栈 | `View/UIPanel.gd` + `Tool/UITool.gd` | 从 `Control` 重新拼 |
| 可配置资源（参数模板、默认值） | `Def/Def.gd` | 散落的 `@export` 默认值 |
| 输入映射（单键切画笔模式） | `Tool/InputTool.gd` | 硬编码 `Input.is_key_pressed` |

**不用的**：`ECS`（SoA 列存）。体素数据是**单块稠密数组**，本身已经是 SoA 的极致形态
（`PackedInt32Array` 连续内存、无指针追逐）；套一层组件系统只会增加间接层且让既有契约失效。

### 2.11 `QVoxelSource`：渲染目标 = **一个节点**

**渲染器持 `QVoxelSource`，而 `QVoxelSource` 持 `QVoxelNode`**。

```
VoxelRenderer（View 层，MeshInstance3D）
  └── 持 source: QVoxelSource
        └── 持 node: QVoxelNode          ← 可以是 World、Group，也可以是一个 Model
             QVoxelEvalEngine.evaluate_node(node, ctx, prev, cache) → 体积
             → 切片（VoxelChunk）→ 网格化（VoxelMeshGenerator）→ 上传
```

**为什么是"节点"而不是"世界"**：`QVoxelNode` 的契约对 World / Group / Model 完全一致（`children()` /
`signature()` / `modifiers`），而引擎**已经**能求值任意节点 —— `evaluate_node(node, ctx, prev, cache)`
按 `kind()` 分派（Model → 跑链；Group / World → 合成子树）。于是**同一个接口既能渲染整世界，
也能只渲染一堆数据里的某一个 node** —— 预览单个模型、只显示某棵子树，都不需要第二条渲染路径。

**`QVoxelSource` 只有一个"数据从哪来"的入口 —— `node`**："体积从哪来"的答案恒为"求值这个节点"。
它自己持有的是**这一份渲染数据**的状态：`_chunk_buffers` / `_dirty` / `_damage` / `_snapshots` /
`_chunk_voxel_counts`，加上描述"这份数据用什么材质画"的 `materials` / `center_offset`。
这些状态不属于世界，故不该住在 Modifier 层。

**没有"生成器"这一层**：整块体积 → 逐 chunk 切片、缓存体积，这两件事就在 `QVoxelSource` 里
（`generate()` + 体积缓存）；程序化产出一律是**链上的源条目** —— 链上本来就有一个源：`PcgModel`
（§2.5 的 `build` 契约）。故渲染链路里不存在 `VoxelGenerator` 这类中间层。

**`VoxelAsyncLoader` 单输入**：`configure(source)`，`request()` 只做一件事 —— 问 source 要一个 chunk。
它仍是全项目**唯一**持有"在途 / 就绪"状态的地方（★保留）。

**`grid_size` 只有一处真值**：`evaluate_node` 对 Model 走 `ctx.at_grid_size(m.grid_size)`、
对 Group / World 由 `_evaluate_group` / `_composite` 算出**紧致盒** —— 两种情况都不依赖调用方预先
告知尺寸，求值结果自带 `grid_size` 与 `origin`。

**磁盘流不在核心取数路径**：`stream` 不是 `QVoxelSource` 的字段（§2.12）；"大于内存的世界"
由扩展层负责，核心取数只经过 `node`。

**存档链路不经过渲染数据**：编辑器走 `QVoxelWorld ⇄ QVoxelFile.QVoxelDocument ⇄ 字节 ⇄ SaveTool`
（`QVoxelier/Editing/QVoxelProject.gd`）。

### 2.12 扩展面：内核 / 扩展的判据

**判据**：**内核** = "渲染任意 `QVoxelNode` 所必需的最小集合"；**扩展** = "只在特定项目里才需要的策略"。
扩展**可以**依赖内核；**内核不得依赖扩展**。

| 类别 | 类 | 归属 |
|---|---|---|
| 无限层 | `VoxelInfiniteLayer`、`VoxelLodGrid` | **扩展**。内核不引用；需要无限世界的项目自行挂上 |
| 运行时破坏 | `VoxelDestructible`、`VoxelDestructionPresenter`、`VoxelDamageStore` | **扩展**。破坏值经 `QVoxelSource` 的覆盖层参与取数，不改变内核求值 |
| 磁盘流 | `VoxelStream` / `QVoxelStream` / `VoxelMemoryStream` | **扩展**。不在内核取数路径（§2.11），负责"大于内存的世界" |

**`VoxelSupport` 是通用体素插件，`QVoxelier` 只是它的一个消费者** —— 插件能力（无限世界、运行时
破坏、磁盘流）不因编辑器不用而消失，它们只是不与渲染链路耦合。

### 2.13 快照 = 同一份求值结果的**第二条消费路径**

快照（`QVoxelierSnapshotSection`）与 `.vox` 导出（`QVoxelBake`）都从 `QVoxelEvalEngine.evaluate_world`
取结果 —— 区别只在消费方式：导出把结果写进 `.vox`，快照把结果装进一份**私有**的 `QVoxelSource`
（`QVoxelSource.from_eval_result`）再离屏渲染。于是"快照里的模型"与"导出写出的模型"必然一致，
不会出现"导出的和截图的不一样"。

**为什么快照不复用视口里的渲染器**：视口渲染器是"每个模型一个"、数据源按相机距离**惰性**生成
chunk 的（§2.11 的取数路径）。快照要的是确定性 —— 一次求值出整块体积、一次渲完 —— 故它自备
数据源，并挂一套 `own_world_3d` 的离屏 `SubViewport`：主视口的网格地板、选区线框、朝向指示器
都不跟进来（这正是"干净出图"要的）。

**为什么"整块体积 → 数据源"必须收成一条入口**（`from_eval_result`）：它同时做"装体积 + 装调色板 +
标脏"三件事。拆开让调用方自己拼，迟早漏掉标脏 —— 而漏标脏的表现是**画面全空且不报任何错**。

---

## 3. 树形层级视图（唯一的层级入口）

> **一切都在同一棵树里**：组（文件夹）、模型（图层）、修改器（滤镜）是同一棵树上的三种行。
> 这是 QVoxelier 的**唯一层级入口** —— 层级关系只在这一处可见可改，不另设对象 / 图层 / 变换面板。
> 一切关系一眼可见、随手可改。

### 3.1 三种行

| 行 | 图标 | 行内控件 | 可展开为 |
|---|---|---|---|
| 组 | 文件夹 | 可见 / 锁定 / 名称（双击改名） | 内容子节点 + 自己的滤镜 |
| 模型 | 方块 | 可见 / 锁定 / 名称 / 体素数 | 自己的滤镜 |
| 修改器 | 滤镜 | 旁通开关 / 名称 / 域徽标 / 错误红标 | 参数（内嵌 Inspector）/ 复合修改器的子链 |

一个节点的展开区里，**内容子节点在前、滤镜在后**，滤镜区以一条浅色分隔行「滤镜」标识。

### 3.2 拖拽语义

| 拖到哪 | 结果 |
|---|---|
| 行之间（上 / 下半） | 同父重排 |
| 行**正中** | 移入该组，成为最后一个子节点 |
| 拖到空白处 | 移出到顶层 |
| 修改器行之间 | 链内重排 |

**拖拽只改模型，视图整棵重建** —— 树视图是模型（§2.2 的 `children`）的**纯投影**，绝不在 `TreeItem` 上
做增删（`TreeItem` 的 `move_before` / `move_after` 只支持同父移动，跨层要 `add_child` + `free`，
极易漏掉 `free` 或留下重复节点）。落位 → 改 `children` → 一条 `QVoxelPropertyCommand` → 重建。

**约束**：模型不能有子节点（拖到模型上 = 移到该模型的**父组**里、与它同级）；修改器不能拖出它所属
节点的滤镜区（拖到别的节点 = 移入那个节点的链）。

### 3.3 实时校验

`QVoxelDomain.chain_errors()` 返回 `[{index, message}]`（`index = -1` 表示链级问题）。树面板据此：

- 给**出问题的那一行**打红标 + 行尾徽标，悬停显示 `message`；
- 组行汇总其子树内的错误数（"这组里有 2 处问题"），于是折叠着也能看见。

### 3.4 控件选型：自绘树

**不用 Godot 的 `Tree`**：它自带整套滚选 / 焦点语义，行内只能放"单元格 + 图标 + 按钮"，且触摸命中区
不达标（这是本仓既有约定，见 `QVoxelUi`）。**改用自绘树**：

- 渲染 = `ScrollContainer` + 嵌套缩进的 `VBoxContainer`，每行是**整行按钮**（`QVoxelUi` 的既定约定），
  行内可放任意控件（图标 / 名称 / 徽标 / 开关）；
- 展开 / 折叠 = 组与模型行的 `expanded` 状态（与 `QVoxelierSection` 同构）；
- 拖拽 = `Control` 的三个虚方法 `_get_drag_data` / `_can_drop_data` / `_drop_data`，落位判据用
  `get_local_mouse_position()` 落在哪一行的上 / 中 / 下三段（自己算，因为不是 `Tree`）。

**代价**：滚动与拖拽要自己写；**收益**：与 QVoxelUi 的触摸 / 主题约定完全一致，且行内控件不受限。

---

## 4. 未完成清单（唯一的工作队列）

> **这是本项目唯一的工作队列。做完一条就从这里删掉**，不留"✅ 已完成"的历史 ——
> 已经具备的能力请读 §2（架构红线）与 `docs/QVX_FORMAT.md`（格式），本节不重复描述它们。
>
> 本节只回答两件事：**还剩什么**、**动手前该想什么**。规则见 §4.3。

### 4.1 功能

| # | 待做 | 边界（已定） | 契合度 | 依赖 |
|---|---|---|---|---|
| F3 | **复合修改器（子链）** | "同一条链上，同一个中间结果分两路处理、再合并"目前表达不出来。具体场景：一块基础体素 → 同时做**侵蚀**与**膨胀** → 两者求交（骨架化 / 中轴提取）。树上的组节点能表达分叉与汇合，但要**复制两份**上游定义，且两份会各自演化、不再同步。§2.6 的路径②本来就规划了它 —— 它不冲突，是**未兑现** | **高**（§2.6 已写明，不是新增机制）。但落地要同时动三处：求值器的紧致盒合成、`.qvx` 的链序列化、树面板的三级行 | 需先定做不做（Q5） |
| F7 | **脚本化 API** | **后置**：它不是"一个功能"，而是"哪些编辑器操作该成为公共 API"—— 属 §2 级决定。框架已有 `EditorScript` 菜单，真要自动化可直接操作数据层（`QVoxelWorld` / `.qvx`），不必先给 QVoxelier 开 API | **待定，须先改 §2** | Q6 |

### 4.2 重构 / 优化

| # | 待做 | 说明 |
|---|---|---|
| R1 | `QVoxelierApp.gd` **减重** | 原 1789 行 → 目标 ≤750 行（DESIGN §2.1 要求 View 层"只管 UI，不含算法"）。**第 1 步已完成**：世界 / 会话装配与工程状态已下沉到 `QVoxelierSession`（现 1651 行）。剩第 2~6 步：搬 9 组同构的"手势即命令"编排、搬工程 I/O 编排、搬刷新编排，最后去重收敛 |

### 4.3 推进约定

每条动手前先回答两问，并写进提交说明：

1. **必要吗** —— 不做会怎样？有没有更小的等价办法？
2. **契合吗** —— 与 §2 的红线冲突吗？复用了哪个既有机制？若必须引入新机制，**先改 §2 再写代码**。

做完后：从 §4.1 / §4.2 **删除该条**；若产生新的架构结论，写进 §2；若动了格式，写进 `docs/QVX_FORMAT.md`。

**测试基建的一条硬约束**：测试运行器在 `SceneTree._initialize()` 里跑用例，而此刻根窗口**尚未入树** ——
于是 `TestCase` 里 `add_child()` 的 `Control` 永远不会触发 `_ready`，**界面类无法用挂树的方式断言**
（实测 `is_inside_tree()` 为 `false`，控件字段全为 `null`）。界面改动以"实跑 `QVoxelier.tscn` 且无脚本错误"
为准；只有纯逻辑（工具 / 格式 / 求值）才进 `Scripts/Test`。

### 4.4 待定问题（需先拍板）

| # | 问题 | 卡住谁 |
|---|---|---|
| Q5 | **复合修改器（子链）做不做？** §2.6 把它写成路径②，但它是一次链上的大特性（求值 / 格式 / 树面板三处都要动）。若不做，就得把 §2.6 的路径②删掉，并明确写"分叉与汇合一律由组节点表达" | F3 |
| Q6 | **脚本化 API 的边界**：要暴露哪些操作、以什么形态暴露？这是 §2 级的"什么该成为公共 API"决定，先定了才动手 | F7 |

---

## 5. 文档缺口（未完成）

| # | 待做 | 说明 |
|---|---|---|
| D1 | 补齐 `docs/QVX_FORMAT.md` | 该文件目前**只有 61 行**（§0 设计原则 + §1 块类型），但代码里已经引用它**不存在的**章节：`QVoxelFile` 引 §9（FATAL）/ §10（能力门），`QVoxelWorld` 引 §12.2（`FRAM` 的 `HEAD.require` 门控）。`VXEL` / `FRAM` / `NODE` / `CACH` 的字段细节、`require` 门控规则、帧增量编码，目前只存在于代码注释里 —— 换个人接手读不到规范 |