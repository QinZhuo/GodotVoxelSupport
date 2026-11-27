# UI 面板与交互视图

`UIPanel` / `UIPanel3D` 管面板开关与栈，`ButtonView` / `ButtonView3D` 管悬停与按下反馈，`DragView3D` 管 3D 拖拽排序；`OptionSelector`、`Background`、`ShaderProgressBar` 是可挂场景的小控件。
状态机集中在纯静态的 `UIPanelTool`，面板本身只保留数据与信号。

| 类 | 职责 |
|---|---|
| `UIPanel` / `UIPanel3D` | 2D Control / 3D Node3D 面板基类：`show_tween`、`layer`、`back_tip`、`dismiss_on_blank_click`、`is_open` 与四个生命周期信号 |
| `UIPanelTool` | `open` / `close` / `toggle` / `popup` / `await_closed[_since]`，并负责 `UITool` 注册/注销 |
| `ButtonView` / `ButtonView3D` | 悬停/焦点反馈、`enter_tween`、`click_tip`；3D 版另有 `press_tween` / `visible_tween` / `outline_mesh` |
| `DragView3D` | 继承 `ButtonView3D`，拖拽拾起/归位/排序；自动发现祖父级 `SlotArrayView3D` |
| `OptionSelector` | SPINNER / TOGGLE 两种选项选择器，`option_changed(index)` |
| `Background` | 收集子级 `Parallax2D`，统一写 `screen_offset` |
| `ShaderProgressBar` | 把 `Range` 的 `ratio` 映射到 `[from_value, to_value]`，写目标材质的 `progress_key` |

```gdscript
class_name SomePanel extends UIPanel

func _ready() -> void:
	on_opened.connect(func(): print("opened"))
	await open()
	var version := open_version()        # 必须在本轮 open() 之后捕获
	await await_closed_since(version)   # 期间被重新 open 则返回 false
```

```gdscript
await panel.popup()                     # 打开并等到关闭；面板被 free 时提前结束

@onready var selector: OptionSelector = $OptionSelector
selector.options = ["低", "中", "高"]
selector.set_index_no_signal(1)         # 初始化时不触发信号
selector.set_enabled(false)
```

```gdscript
class_name ItemDragView extends DragView3D

func _can_drag() -> bool:
	return not locked

func _on_drag_ended() -> void:
	super._on_drag_ended()   # 默认按 drag_container 重排 data 并 resync_views()
```

## 坑

1. 不要用 `visible = true/false` 代替 `open()` / `close()`：面板必须经 `UIPanelTool` 注册/注销，否则 `UITool.back()`、`get_top()`、层级互斥全部失真；`_exit_tree()` 只是兜底注销。
2. `open()` / `close()` / `popup()` 都是协程：调用即推进（不 `await` 也会跑），要等动画结束或拿结果必须 `await`。`close()` 先置 `is_open = false` 并出栈，再发 `on_close`、播离场动画。
3. `await_closed()` 用版本号判"这一轮"：版本要在 `open()` 之后捕获，否则自增对不上会返回 `false`。关闭动画中途面板被释放也返回 `false`；调用时已关闭立即返回 `true`。
4. `UIPanelTool` 是纯静态门面，不要 `new`、不要挂节点。它按鸭子类型访问 `_open_version` / `on_open` / `on_opened` / `show_tween` / `apply_visibility`，自定义面板必须保持这套接口。2D/3D 无法共享基类（`Control` vs `Node3D`），公共改动要同时落两边。
5. `layer` 只在 `DIALOG` 做同层互斥，`PANEL` 可叠多层，`TOOLTIP` 不入栈只保留当前。`show_tween` 为空时直接切显隐。`back_tip` 在 `open()` 成功后 `TipTool.show_tip`、`close()` 先隐藏；`dismiss_on_blank_click` 由 `UITool` 按属性名探测。
6. `OptionSelector.current_index` 的 setter 每次都发 `option_changed`（含 clamp 成同值），批量初始化用 `set_index_no_signal()`；禁用只置灰并 disable 按钮，键盘焦点链要自行跳过。`Background` 只收 `Parallax2D` 子节点；`ShaderProgressBar` 换 `item` 会重连 `value_changed`，`item.material` 为空时静默跳过。
