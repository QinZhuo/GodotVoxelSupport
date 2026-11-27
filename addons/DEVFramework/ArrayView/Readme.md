# ArrayView 数据驱动的视图容器

`data` 的每一项对应一个 `view_scene` 实例。`ArrayView` 是流式布局（视图就是子节点，数量随数据变）；
`SlotArrayView2D/3D` 把场景里预置的子节点当固定槽位，`OffsetArrayView2D/3D` 在槽位基础上按 `offset` 自动排布。
所有算法只有一份实现：`ArrayViewTool`。

| 类 | 职责 |
|---|---|
| `ArrayView` | 继承 `FlowContainer`；`view_scene`、`pool_key`、`items_per_frame`、`data`、`views` |
| `SlotArrayView2D` / `3D` | 子节点即槽位；`refresh`、`resync_views`、`refresh_at`、`add_item`、`set_item`、`remove_at` |
| `OffsetArrayView2D` / `3D` | 槽位版加 `offset`、`centered`、`max_length`，`update_layout()` |
| `ArrayViewTool` | 池化、绑定、按数据找视图、释放、槽位重排的全部实现 |
| `Pool`（Core/Pool） | `pool_key` 对应的对象池；`pool_size > 0` 时同时是预热数量与空闲上限 |

```gdscript
@onready var list: ArrayView = $ArrayView

func _ready() -> void:
	list.view_scene = load("res://some_view.tscn")
	list.pool_key = "some_view"
	list.data = [item_a, item_b]
	await list.wait_finished()          # items_per_frame > 0 时分帧生成
	var view := list.get_view(1)
	list.refresh_item(item_a)           # 定位不到就当新增
	list.remove_item(item_b)
```

```gdscript
@onready var slots: SlotArrayView3D = $Slots   # 子节点按顺序就是槽位

slots.data = items
slots.resync_views()        # 拖拽排序 / 删项后：只重绑，不重建节点
slots.set_item(0, preview)  # 临时改这一格显示

@onready var offset: OffsetArrayView3D = $Offset
offset.offset = Vector3(0.8, 0.0, 0.0)
offset.centered = true       # 当前位置是整排中点；false = 第一项
offset.max_length = 4.0      # 整排超长时等比压缩间距
offset.update_layout()
```

3D 拖拽排序由 `DragView3D` 驱动：拖拽视图的祖父节点必须是 `SlotArrayView3D`，排序后容器调 `resync_views()`。

## 坑

1. `views` 才是索引真源，不要拿 `get_child(index)` 当第 index 项：`ArrayView` 有分帧生成与池化，`SlotArrayView` 的 `views` 允许 `null` 空位。
2. `data` 是唯一真相。`set_item()`（Slot）只临时改这一格显示，下次 `refresh` / `resync_views` / `refresh_item` 会按 `data` 纠回；`remove_at()` 只释放视图、不改 `data`。
3. `remove_item(null)` 什么都不做：`null` 是空槽位的合法值。
4. Slot 的槽位数固定等于场景里预置的 `Node2D` / `Node3D` 子节点数；`data` 比槽位多时多余项被丢弃并 `LogTool.error`。`auto_hide_empty` 只隐藏槽位节点，不改 `views` 长度。
5. `ArrayView.refresh()` 在 `items_per_frame > 0` 时分帧，刷新后立刻取视图可能还是 `null`，用 `await wait_finished()`；`clear()` 也必须发 `view_finished`，否则等待中的协程永远不醒。
6. 比较两个数据项要用 `ArrayViewTool.same_data()`：GDScript 的 `==` 在类型不同时会直接抛错（bool vs String）。池化只在运行时且 `pool_key`、`view_scene` 都有效时启用；释放统一走 `ArrayViewTool.free_view()`。
