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
  └─ VoxelStream (@abstract) — chunk 级持久化 API（全部方法 @abstract，
                               子类漏实现任一将无法编译）
       ├─ VoxelFileStream         — 磁盘 region 流式存储（体素世界存档）
       └─ VoxelProceduralStream (@abstract) — 程序化无限世界
            └─ 子类覆写 @abstract `_generate_chunk()`
VoxelRenderer              — 异步网格生成、LOD、流式加载、碰撞
VoxelDestructible          — 继承 VoxelRenderer：破坏、崩塌、掉落碎片
```

**数据访问顺序**（每 chunk）：内存缓冲 → 磁盘流 → 程序化生成。
所有网格生成在后台线程（`WorkerThreadPool`），主线程不阻塞于体素生成/建网格。

### 静态世界（磁盘流式）

```gdscript
var data := VoxelData.new()
# ... 添加材质、填充体素（set_voxels / load_voxels_dict）

var stream := VoxelFileStream.new()
stream.directory = "user://my_world"
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
extends VoxelProceduralStream

## 覆写基类 @abstract 方法：返回 16³ PackedInt32Array（值 = 材质ID，0 = 空）。
## 必须确定性：同 chunk_key → 同地形。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	# 例如基于噪声的高度图 —— 用【绝对体素 y】判断，保证跨层连续
	...

# 使用
var stream := MyWorld.new()
stream.persist_directory = "user://world_edits"   # 可选：持久化玩家修改，重启保留
var data := VoxelData.new()
data.stream = stream
# 赋值给 VoxelRenderer.data（建议 visibility_mode = STREAMING）
```

特性：
- **确定性** — 同 chunk_key → 同地形，chunk 边界与 origin shift 后世界连续
- **动态原点重定位（origin shift）** — 相机远移自动平移世界基准，坐标保持小（float32 精度安全）→ 真正的无限世界
- **修改持久化** — 玩家修改的 chunk 写入 `persist_directory`，重启保留
- **异步生成** — chunk 生成在后台线程（`WorkerThreadPool`），主线程只提交/回填
- **自动卸载** — 超出 `view_distance` 的 chunk 丢弃，回来时重新生成

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
  LOD_i 半径自动 = `view_distance / 2^(lod_count-1-i)`（每级 ×2，对齐 Voxel Tools 标准做法）
- `unload_distance = 0` 会自动回退到 `view_distance * 1.5`
- `generate_collision` **默认 false** — 需要物理碰撞时开启
- `voxel_scale` = 每个体素的世界单位（数据坐标是 1 体素单位）；所有距离参数都是世界单位

### 流式 demo

`res://demo/streaming_demo.tscn` — 按键 **0** 在 磁盘文件流 与 程序化无限世界 间切换。
操作：WASD 移动、Q/E 升降、空格加速、1 流式开关、2 视锥剔除开关。
