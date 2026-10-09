# Godot Voxel Support
[English](https://github.com/QinZhuo/GodotVoxelSupport/blob/main/README.md) | [中文](https://github.com/QinZhuo/GodotVoxelSupport/blob/main/zh/README.md)

[Github](https://github.com/QinZhuo/GodotVoxelSupport) • [资产库](https://godotengine.org/asset-library/asset/4480) 

> MagicaVoxel大型体素模型支持，更快的导入速度，自动材质贴图

- 合并模型 
- 多线程生成Mesh
- 自动生成 金属 粗糙 自发光 等贴图
- 解决导入大于256x256x256的.vox模型过慢导致卡死的问题

![alt text](Showdown_of_Luck.png)

[《Showdown of Luck》](https://store.steampowered.com/app/4666770/?utm_source=github)这个游戏中可以看到使用插件导入的体素模型渲染效果 是现在我正在制作的独立游戏 一款融合卡牌与老虎机的异步联机PVP自走棋游戏 感兴趣可以加一个愿望单
> 如果您的游戏使用了这个插件 跟我说一下我会很开心 我也愿意通过我的方式帮你宣传一下
![](/images/cards.png)
![](/images/teapot.png)

## 体素运行时使用方法

### 架构

```
VoxelData                    — 体素数据存储与修改（材质、chunk 缓冲）
  ├─ VoxelStream (@abstract)     — 存储：chunk 级持久化 API（全部方法 @abstract）
  │    ├─ QVoxelStream             — .qvx 单文件块流世界存档（磁盘）
  │    └─ VoxelMemoryStream      — 纯内存（不落盘；程序化世界的编辑落脚处）
  └─ VoxelGenerator (@abstract)  — 生成：给定 key 算出数据（不碰 I/O、无状态）
       └─ 子类覆写 @abstract `_generate_chunk()` / `_generate_chunk_lod()`
VoxelRenderer              — 异步网格生成、LOD、流式加载、碰撞
VoxelDestructible          — 继承 VoxelRenderer：破坏、崩塌、掉落碎片
```

**"存"与"造"是两个并列的部件**：`stream` 负责存（磁盘 / 内存），`generator` 负责造
（程序化地形）。二者可以同时存在（程序化世界 + 破坏存档），取数优先级恒为
**流 > 生成器**——存过的必须权威，不能被重新生成覆盖。
登记 / 去重 / 后台派发 / 回填集中在 `VoxelAsyncLoader` 一处，两个数据源都只回答
"存了吗"与"能造吗"两个同步问题。

**数据访问顺序**（每 chunk）：内存缓冲 → 流 → 生成器。
所有网格生成在后台线程（`WorkerThreadPool`），主线程不阻塞于体素生成/建网格。

### 静态世界（磁盘流式）

```gdscript
var data := VoxelData.new()
# ... 添加材质、填充体素（set_voxels / load_voxels_dict）

var stream := QVoxelStream.new()
stream.file_path = "user://my_world/world.qvx"
data.stream = stream

var renderer := VoxelDestructible.new()
renderer.data = data
renderer.voxel_scale = 0.2
renderer.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
renderer.view_distance = 60.0
renderer.unload_distance = 100.0
renderer.lod_count = 4   # 多级 LOD：4 层（LOD0 全精度 + LOD1/2/3 每级 ×2 粗化），
                         # 各层距离由 view_distance 自动等比（×2）推导
```

### 程序化无限世界

```gdscript
class_name MyWorld
extends VoxelGenerator

## 覆写基类 @abstract 方法：返回 32³ PackedInt32Array（值 = 材质ID，0 = 空）。
## 必须确定性：同 chunk_key → 同地形。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	# 例如基于噪声的高度图 —— 用【绝对体素 y】判断，保证跨层连续
	...

# 使用：生成器"造"，存储"存"（可自由替换，互不影响）
var data := VoxelData.new()
data.stream = QVoxelStream.new()          # 玩家修改落盘，重启保留
data.stream.file_path = "user://world_edits/world.qvx"
data.generator = MyWorld.new()          # 未编辑的部分按 key 确定性生成
# 赋值给 VoxelRenderer.data（建议 visibility_mode = STREAMING）
```

> `stream` 换成 `VoxelMemoryStream` 即"修改只存内存、退出即丢"；留空则由引擎自动兜底
> 建一个内存流。生成器代码一行都不用改。

特性：
- **确定性** — 同 chunk_key → 同地形，chunk 边界与 origin shift 后世界连续
- **动态原点重定位（origin shift）** — 相机远移自动平移世界基准，坐标保持小（float32 精度安全）→ 真正的无限世界
- **修改持久化** — 玩家修改的 chunk 由 `stream` 负责，重启保留
- **异步生成** — chunk 生成在后台线程（`WorkerThreadPool`），主线程只提交/回填
- **自动卸载** — 超出距离的网格、LOD0 chunk 数据与粗层 LOD 块都会被释放，回来时重新加载/生成。
  LOD0 **数据**的卸载半径比网格更宽（`unload_distance` 再加最粗层 block 的覆盖范围），
  以保证粗层降采样仍有 LOD0 来源；这是无限世界内存有界的前提

### 破坏与崩塌

```gdscript
var target := renderer as VoxelDestructible
target.damage_sphere(center, radius)
target.damage_voxel(pos)
target.damage_ray(origin, direction, max_distance)
```

可选配置：`use_voxel_health` / `damage_per_voxel` / `collapse_mode` / `local_collapse` /
`falling_mode` / `stress_force` / `spawn_debris_on_damage` 等。
碎片基于 GPU 粒子（无逐 chunk 物理刚体）。

### 配置项 — 不生效时自动隐藏

相关属性在 **Inspector 中条件不满足时自动隐藏**（避免设置后无效）：

| 属性 | 生效条件 | 隐藏条件 |
|---|---|---|
| `view_distance` / `unload_distance` / `lod_count` | visibility_mode ≠ FULL | visibility_mode = FULL |
| `_stream_load_per_frame` / `_stream_unload_per_frame` | visibility_mode = STREAMING | 其他 |
| `_lod1_build_per_frame` / `_lod1_build_budget_ms` | lod_count > 1 | lod_count = 1 |
| `_collision_rebuild_per_frame` | generate_collision = true | generate_collision = false |
| `max_debris_per_hit` / `debris_*` | spawn_debris_on_damage = true | spawn_debris_on_damage = false |

### 常见易错点

- **程序化世界**：使用 `visibility_mode = STREAMING` — 无限世界必然按距离驱动（FULL/FRUSTUM 曾会导致空白，已自动修复）
- `lod_count = 1` 表示关闭 LOD（全部全精度）；大世界设 `lod_count >= 2`。
  分带半径自动推导：LOD0 = `view_distance / 2^lod_count`，LOD_i（i≥1）= `view_distance / 2^(lod_count-1-i)`
  ——自 LOD0 起逐级 ×2，对齐 Voxel Tools 标准做法
- `unload_distance = 0` 会自动回退到 `view_distance * 1.2`
- `generate_collision` **默认 false** — 需要物理碰撞时开启
- `voxel_scale` = 每个体素的世界单位（数据坐标是 1 体素单位）；所有距离参数都是世界单位
- **原生库是硬依赖** —— 网格生成 / 破坏 / CRC 全在 `addons/VoxelSupport/Native/`（GDExtension
  `VoxelNative`）。库缺失或版本不匹配时插件只报一次明确错误、不做 GDScript 兜底。
- **资产原点由导入选项 `mesh/origin` 统一控制（Mesh 与 Data 两个导入器同名同义）** —— 默认
  `world_origin` = 原样保留文件里的坐标：`.vox` 就停在作者把它放在 MagicaVoxel 世界里的位置
  （模型自己的 `SIZE` 盒中心 + 每层 `nTRN`/`NODE` 变换）；`.qvx` 没有"世界"这一层，此时就是
  "文件里的坐标原样"。这也正是本插件网格导入一直以来的行为，因此升级不会挪动已有资产，多模型装配
  的相对位置也保得住。需要游戏资产惯用的原点（按内容 X/Z 居中、底面落在 `Y=0`）就显式选
  `bottom_center`，要三轴内容居中（与 Blender 导入器的 "Center Origins" 同思路）就选
  `content_center`。
- **`.vox` 与 `.qvx` 各有自己的资产适配器** —— `.vox`（MagicaVoxel 场景图）走
  `VoxAsset.from_asset()`；`.qvx`（一个 `VOX0` 一个模型 + `NODE` 摆放）走
  `QVoxelAsset.from_file()`。对 `.qvx` 调 `VoxAsset.from_asset()` 会**报错并返回 null**：
  把 MagicaVoxel 的形状硬套到 QVX 上会静默丢掉 `NODE` 场景图与除第一个之外的全部模型。
  编辑器的导入插件已按扩展名自动分派，无需手动区分。

### 流式 demo

`res://demo/streaming_demo.tscn` — 按键 **0** 在 磁盘文件流 与 程序化无限世界 间切换。
操作：WASD 移动、Q/E 升降、空格加速、1 流式开关、2 视锥剔除开关。
