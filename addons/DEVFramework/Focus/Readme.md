# Focus 焦点遮罩

`FocusMask` 做一次屏幕空间合成：读已画好的整帧，目标区域取屏幕原样（可提亮），区域外压暗。
不挖洞、不改目标节点的 `z_index` / `modulate` / 父子关系，所以 CanvasLayer、SubViewport 嵌套天然正确。
`FocusMaskTool` 是全局唯一遮罩的门面，首次使用时自动挂到最高层 `CanvasLayer`；气泡由 Dialogue 绘制。

| 入口 | 说明 |
|---|---|
| `FocusMaskTool.focus(items, opts = {}, host = null)` | 聚焦一组节点，返回 `FocusMask` |
| `FocusMaskTool.clear()` | 取消聚焦并隐藏（不释放节点，下次复用） |
| `FocusMaskTool.set_tip(text)` | 换提示文案，锚点用当前目标包围盒 |
| `FocusMaskTool.is_active()` / `is_blocking()` | 查询状态；`is_blocking` 用于外部禁用快捷键 |
| `FocusMaskTool.reset()` | 释放遮罩及其 CanvasLayer（切场景/回标题） |
| `FocusMask.focus` / `clear` / `get_hit_rects` / `get_focus_rect` | 直接使用实例时的底层接口 |

`opts` 键：`dim`（Color）、`focus_boost`（float）、`block`（bool）、`click_to_complete`（bool）、`advance_action`（StringName）、`drag_checker`（Callable）、`tip`（String）。

```gdscript
var mask := FocusMaskTool.focus([$Panel/ConfirmButton, $World/Desk], {
	"dim": Color(0.0, 0.0, 0.0, 0.7),
	"block": true,
	"click_to_complete": true,
	"tip": "点这里继续",
})
mask.blank_pressed.connect(func(): FocusMaskTool.clear())

if FocusMaskTool.is_blocking():
	pass    # 目标外输入已被吞掉，快捷键不要再响应
FocusMaskTool.reset()

var m := FocusMask.new()      # 不用门面时
add_child(m)
m.focus([$Target], {"dim": Color(0, 0, 0, 0.8)})
```

## 坑

1. 一次最多 16 个目标（`MAX_RECTS`），超出不点亮也不描边、只 `push_warning` 一次；目标矩形面积超过屏幕 90% 会被当成"没定位到"跳过。
2. 2D 目标没有真实轮廓，用控件矩形 + 样式盒圆角；3D 默认走"只渲染目标"的层分离轮廓（`outline_3d`），纯 `Area3D` 或无可见网格退化成矩形。`highlight_layer`（1..20）必须未被项目占用。
3. `block_input` 吞掉目标外的一切指针与导航输入，但**不拦 `ui_cancel`**：返回/ESC 仍走项目的统一返回决策点。
4. 目标在子视口（`SubView3D` 贴面）里时遮罩逐层映射到主视口坐标；只映射一层会把高亮画到左上角。headless 下视口尺寸可能是 0，此时按项目设计分辨率计算。
5. `FocusMaskTool` 全局只有一个遮罩，`focus()` 复用同一节点；`reset()` 释放的是自动创建的 `CanvasLayer`，不是项目场景节点。该层是 `ALWAYS`，暂停时仍拦截。
6. `dim_color.a = 1` 时目标外是纯黑，不是"比别处更暗"；`focus_boost > 1` 让目标比平时更亮。不要往 `FocusMask` 下挂气泡控件。
