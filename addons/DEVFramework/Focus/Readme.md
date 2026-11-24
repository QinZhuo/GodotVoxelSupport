# Focus 焦点遮罩

`FocusMask` 做一次屏幕空间合成：读取已经画好的整帧，目标区域取屏幕原样（可提亮），区域外压暗。
不挖洞、不改目标节点的 `z_index` / `modulate` / 父子关系，因此 CanvasLayer、SubViewport 嵌套天然正确。
`FocusMaskTool` 是全局唯一遮罩的门面，首次使用时自动挂到最高层 `CanvasLayer`。气泡由 Dialogue 子系统绘制，遮罩只算命中区并提供锚点。

## 怎么用

| 入口 | 说明 |
|---|---|
| `FocusMaskTool.focus(items, opts = {}, host = null)` | 聚焦一组节点，返回 `FocusMask`；`opts` 见下 |
| `FocusMaskTool.clear()` | 取消聚焦并隐藏（不释放节点，下次复用） |
| `FocusMaskTool.set_tip(text)` | 换提示文案，锚点用当前目标包围盒 |
| `FocusMaskTool.is_active()` / `is_blocking()` | 查询状态；`is_blocking` 用于外部禁用快捷键 |
| `FocusMaskTool.reset()` | 释放遮罩及其 CanvasLayer（切场景/回标题） |
| `FocusMask.focus` / `clear` / `get_hit_rects` / `get_focus_rect` | 直接使用实例时的底层接口 |

`opts` 键：`dim`（Color）、`focus_boost`（float）、`block`（bool）、`click_to_complete`（bool）、
`advance_action`（StringName）、`drag_checker`（Callable）、`tip`（String）。

```gdscript
var mask := FocusMaskTool.focus([$Panel/ConfirmButton, $World/Desk], {
	"dim": Color(0.0, 0.0, 0.0, 0.7),
	"block": true,
	"click_to_complete": true,
	"tip": "点这里继续",
})
mask.blank_pressed.connect(func(): FocusMaskTool.clear())
```

```gdscript
if FocusMaskTool.is_blocking():
	# 目标外输入已被吞掉，快捷键不要再响应
	pass
FocusMaskTool.set_tip("再试一次")
FocusMaskTool.reset()
```

```gdscript
# 不使用门面时
var mask := FocusMask.new()
add_child(mask)
mask.focus([$Target], {"dim": Color(0, 0, 0, 0.8)})
var rect: Rect2 = mask.get_focus_rect()
```

## 坑

1. 一次最多 16 个目标（`MAX_RECTS`），超出的不会点亮也不会描边，只 `push_warning` 一次。目标矩形面积超过屏幕 90% 会被当成“没定位到”直接跳过（避免兜底成整屏压暗）。
2. 2D 目标没有真实轮廓，用控件矩形 + 样式盒圆角；3D 目标默认走“只渲染目标”的层分离轮廓（`outline_3d`），纯 `Area3D` 或没有可见网格的目标退化成矩形。`highlight_layer`（1..20）必须未被项目占用，遮罩会临时改目标与灯的 `layers`，`clear()` 时恢复。
3. `block_input` 吞掉目标外的一切指针与导航输入，但**不拦 `ui_cancel`**：返回/ESC 仍走项目的统一返回决策点。键盘导航被限制在目标内；目标没有可聚焦控件时，确认键只有在 3D 焦点落在目标上时才放行。
4. 目标在子视口（`SubView3D` 贴面）里时，遮罩会逐层映射到主视口坐标；只映射一层会把高亮画到左上角。headless 下视口尺寸可能是 0，此时按项目设计分辨率计算。
5. `FocusMaskTool` 全局只有一个遮罩，`focus()` 复用同一个节点；`reset()` 释放的是自动创建的 `CanvasLayer`，不是项目自己的场景节点。遮罩所在的 `CanvasLayer` 是 `ALWAYS`，暂停时仍会拦截。
6. `dim_color.a = 1` 时目标外是纯黑，不是“比别处更暗”；`focus_boost > 1` 让目标比平时更亮。气泡完全由 `DialogueTool` 负责，不要往 `FocusMask` 下挂气泡控件。

## 文件结构

Focus/ 四块：`FocusMask`（合成、命中区、输入拦截）、`FocusMaskTool`（全局单例与生命周期）、
`FocusRectTool`（纯几何换算：节点/2D/3D 的屏幕矩形、圆角、光源收集，全 static 无状态，可单独复用）、
`FocusMaskSpotlight.gdshader`（遮罩/提亮/描边的实际着色器）。
