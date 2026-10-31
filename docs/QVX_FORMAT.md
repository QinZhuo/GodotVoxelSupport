# QVX 格式规范 — v3

> **定位**：`.qvx` 是一个**体素模型容器**，与 MagicaVoxel 的 `.vox` 同级——
> 可独立分发、可直接观察、可作为项目资产被编辑器导入的**源文件**，
> 不是烘焙中间产物或临时文件。同一个容器**也**能承载"整个世界存档"
> （多模型 + 增量写盘），但那是它的用法之一，不是它的身份。
>
> 配套实现（`addons/VoxelSupport/`）：
> - **格式内核** `QVoxelSpec` / `QVoxelBlockCodec` / `QVoxelFile`（定义、编解码、读写与校验）
> - **资产导入** `QVoxelAsset.from_file()`：`.qvx` 的块级视图（材质 + 每个 `VXEL` 的块 + `NODE` 摆放）。
>   `.vox` 由 `VoxAsset` 承载 —— 两种源格式的概念形状不同（详见 QVoxelAsset 类注释），
>   导入器按扩展名分派，不共用适配器
> - **世界存档** `QVoxelStream`：可写、脏标记、增量落盘
>
> 编辑器导入器（`addons/VoxelSupport/Importer/`）**同时识别 `.vox` 与 `.qvx`**，
> 在导入面板可选四种产物：
> - `Voxel Data Resource` → `QVoxelSource` (.res)：运行时体素数据（可破坏 / 动态修改）
> - `Voxel Mesh` → `ArrayMesh` (.mesh)：静态网格
> - `Voxel MeshLibrary` → `MeshLibrary` (.res)：网格库（by model / node / frame）
> - `Voxel No Import` → 空 `Resource`：只要原始文件、不做导入
>
> `demo/samples/*.qvx` 是可直接 hexdump 对照的样例，同时是
> `Scripts/Test/test_qvox_format.gd` 的测试夹具（随 `.gitattributes` 走 Git LFS）。

> **单一文件。单一数据流。每条事实只存一次。**

---

## 0. 设计原则

五条规则，其余一切由此推导。

| # | 原则 | 学自 | 推论 |
|---|---|---|---|
| **P1** | **整个文件就是一条带类型的块流，别无其他** | PNG / GLB | 文件即块。新功能 = 新块类型。旧读者遇到就跳过。 |
| **P2** | **每条事实只存一次** | ——（第一性原理） | 任何字段不得可由其他字段推导。不存可数出来的计数。 |
| **P3** | **元数据用 JSON，负载用列式二进制** | GLB / SPZ | 人读头部，机器读打包的列；压缩率提升 3–5×。 |
| **P4** | **块头自足：读到块头即知全部** | FlatBuffers | 长度、类型、校验值都在 payload 之前。 |
| **P5** | **缓存是派生的，且可证明可删除** | SPZ / FlatBuffers | 能重算的块就标明"可重算"，与其来源校验，且删之无害。 |

---

## 1. 块类型

文件 = 8 字节签名 + 一个或多个块（第一个必须是 `HEAD`），在最后一个块结束时结束，
没有终止符。当前共七种类型；这个集合应当缓慢增长，且每次增加都需要理由。

| 类型 | 数量 | 必需 | 可删 | 用途 |
|---|---|---|---|---|
| `HEAD` | 恰好 1 个 | ✅ 必须第一 | ❌ | 声明文件。JSON。 |
| `MATE` | ≤ 1 | 否 | ❌ | 材质调色板。 |
| `VXEL` | ≥ 0 | 否* | ❌ | 体素数据（静态）。每个模型一个。 |
| `ANIM` | ≥ 0 | 否* | ❌ | 帧动画数据 + 时序。每个动画一个。 |
| `NODE` | ≤ 1 | 否 | ❌ | 场景树（只放 `nodes`）。JSON。 |
| `CAMR` | ≤ 1 | 否 | ❌ | 相机书签。JSON。 |
| `CACH` | 任意 | 否 | ✅ | 任何可重算的数据。 |

\* 没有 `VXEL` / `ANIM` 的文件是合法的——例如一个纯资产数据库。渲染器需要关心的
体素场景至少有一个。**两者按 `model_id` 互斥**：一个 `model_id` 要么是静态 `VXEL`、
要么是 `ANIM` 动画，不能同时是。

> **v4 的三处收敛**：① `HEAD` 的 `channels` 数组（恒为长度 1、却暗示多通道）改为扁平单键
> `"channel":"material"` + `"bpp":16`；② `NODE` 一肩挑三事拆成 `NODE`/`CAMR`/`ANIM`；
> ③ 动画时序（fps/loop/tags）从 `NODE` 节点条目收进 `ANIM` 块，与体素帧内聚一处。
> 节点摆放轨道 `transform_tracks` 仍属**节点**（组也能做摆放动画，与按 model_id 绑定的
> `ANIM` 粒度不同）。

删除全部 `CACH` 块后，文件必须加载出**完全相同的结果**——只是首次加载更慢（P5）。

---

## 2. 节点摆放（NODE 的 `nodes[]` 条目）

场景树是**嵌套**的：每个节点是一个 JSON 对象，`kind` 取 `group`（容器，带 `children`）或
`model`（叶子，带 `model_id`）。节点的摆放只有一处真值 —— 一个 `transform` 键：

```json
{ "kind": "model", "model_id": 0, "name": "body",
  "transform": { "t": [1, 2, 3], "r": [x, y, z, w], "s": [1, 1, 1] } }
```

- `t` 平移（体素单位，整数）、`r` 旋转（单位四元数，与 glTF 同构）、`s` 缩放（三者皆可缺省）。
- 缺省 = 恒等，**不写字面量**（P2）：`transform` 键整体缺失即恒等。
- 轴对齐 90° 旋转（`.vox` 的 24 朝向的等价物）是**整数保序**的，体素盒不被破坏；
  非轴对齐旋转 / 缩放由运行时导入器逐体素融合处理，编辑器世界按"不旋转 + 告警"处理。
- 读写唯一实现：`QVoxelNode.transform_from_json` / `transform_to_json`。**全项目不得另抄一份**。

逐帧摆放（变换动画）用一个并列的 `transform_tracks` 键 —— `transform_tracks[k]` 是第 k 帧的
`transform`，与 `ANIM` 的体素帧**共用同一帧号**（播放第 k 帧 = 体素取 ANIM 第 k 帧 + 摆放取
本数组第 k 项）。空数组 = 静态（零成本）。`transform_tracks` 留在节点（组也能做摆放动画），
而 `ANIM` 按 `model_id` 绑定（模型专有）—— 粒度不同。

> **分工**：`transform_tracks` 只移动/旋转**整个物件**（组会带着整棵子树），不做骨骼、蒙皮或
> 逐体素重采样；需要"每个体素重新落格"的效果请用 `ANIM` 体素帧。
> 导入 `.vox` 时，nTRN 多帧 → `transform_tracks`，nSHP 逐帧换模型 → `ANIM` 体素帧，两者不混。

## 3. `.vox` ⇄ `.qvx` 的图层 / 组映射

`.vox` 的 `LAYR`（图层，含 `_name` / `_hidden`）与 `.qvx` 的组**一一对应**：
一个图层 = 一个 `QVoxelGroup`，**组名 = 图层名**，**可见性 = `_hidden` 的反**。导入器
（`VoxAsset.to_world()`）从 `node 0` 递归、跳过隐藏图层的整棵子树、同一模型被多个形状引用
就摆多份 —— 于是"世界求值出的体素集合"与 `.vox` 的渲染路径 `VoxAsset.get_voxels()` **逐格一致**。
`.qvx` 与 `.vox` 因此都落到同一个 `QVoxelWorld`，渲染只有一套语义。

## 4. 程序化生成（AI / 脚本）

`.qvx` **不在文件里塞"文本形态"** —— 需要"用代码生成模型"时，直接写一段 GDScript 拼体素、再
`QVoxelFile.serialize(doc)` 落盘即可（范例：`demo/warrior_voxel.gd`）。AI 写代码（循环 / 函数 /
复用 / 参数化）比手写二进制或文本块都更强、更可靠，故格式本身保持纯二进制、单一解析路径。

