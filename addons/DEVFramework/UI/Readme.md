# UI 面板与交互视图

`UIPanel` / `UIPanel3D` 负责面板的打开、关闭与栈管理，`ButtonView` / `ButtonView3D` 负责悬停与按下反馈，
`DragView3D` 负责 3D 拖拽排序；`OptionSelector`、`Background`、`ShaderProgressBar` 是可直接挂到场景的小控件。
状态机集中在纯静态的 `UIPanelTool`，面板本身只保留数据与信号。

## 怎么用

| 类 | 职责 |
|---|---|
| `UIPanel` / `UIPanel3D` | 2D Control / 3D Node3D 面板基类：`show_tween`、`layer`、`back_tip`、`dismiss_on_blank_click`、`is_open` 与四个生命周期信号 |
| `UIPanelTool` | `open` / `close` / `toggle` / `popup` / `await_closed[_since]`，并负责 `UITool` 注册/注销 |
| `ButtonView` / `ButtonView3D` | 悬停/焦点反馈、`enter_tween`、点击提示 `click_tip`；3D 版另有 `press_tween` / `visible_tween` / `outline_mesh` |
| `DragView3D` | 继承 `ButtonView3D`，拖拽拾起/归位/排序；自动发现祖父级 `SlotArrayView3D` |
| `OptionSelector` | SPINNER / TOGGLE 两种选项选择器，`option_changed(index)` |
| `Background` | 收集子级 `Parallax2D`，统一写 `screen_offset` |
| `ShaderProgressBar` | 把 `Range` 的 `ratio` 映射到 `[from_value, to_value]`，写进目标材质的 `progress_key` 参数 |

```gdscript
class_name SomePanel extends UIPanel

func _ready() -> void:
	on_opened.connect(func(): print("opened"))
	await open()
	var version := open_version()        # 必须在本轮 open() 之后捕获
	# ... 等一次交互 ...
	await await_closed_since(version)   # 期间被重新 open 则返回 false
```

```gdscript
# 弹窗：打开并等到关闭；面板被 free 时提前结束等待（popup 本身无返回值）
await panel.popup()
```

```gdscript
@onready var selector: OptionSelector = $OptionSelector

func _ready() -> void:
	selector.options = ["低", "中", "高"]
	selector.option_changed.connect(func(i: int): print(selector.get_current_value()))
	selector.set_index_no_signal(1)     # 初始化时不触发信号
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

1. 不要用 `visible = true/false` 代替 `open()` / `close()`：面板必须经 `UIPanelTool` 注册/注销，否则 `UITool.back()`、`get_top()`、层级互斥全部失真。`_exit_tree()` 只是兜底注销，不会再发 `on_opened`。
2. `open()` / `close()` / `popup()` 都是协程：调用即开始推进（不 `await` 也会跑），但要等动画结束或拿结果必须 `await`。`close()` 先把 `is_open` 置 `false` 并从栈中注销，再发 `on_close`、播离场动画，所以动画期间它已经不在栈里。
3. `await_closed()` 用版本号判断“这一轮”：版本要在本轮 `open()` 之后捕获，若在 `open()` 之前先取，`open()` 自增版本会让旧等待对不上并返回 `false`。正确写法是 `await open()` 后 `var v = open_version()`，再 `await await_closed_since(v)`；面板在关闭动画中途被释放时返回 `false`，调用方应跳过后续动作；调用时已经关闭则立即返回 `true`。
4. `UIPanelTool` 是纯静态门面，不要 `new`，也不要挂到节点上。它按鸭子类型访问 `_open_version` / `on_open` / `on_opened` / `show_tween` / `apply_visibility` 等成员，自定义面板必须保持这套接口。`UIPanel` 与 `UIPanel3D` 无法共享基类（`Control` vs `Node3D`），公共逻辑改动要同时落到两边。
5. `layer` 只在 `DIALOG` 做同层互斥，`PANEL` 可以叠多层；`TOOLTIP` 不入栈，只保留当前 tooltip。`show_tween` 为空时直接切显隐。
   两个面板都支持 `back_tip`（`open()` 成功后 `TipTool.show_tip`，`close()` 先隐藏）与 `dismiss_on_blank_click`
   （由 `UITool.dismiss_on_blank_click()` 按属性名探测，查看类面板置 true）。2D/3D 的公开成员保持一致，改一边就补另一边。
6. `OptionSelector` 的 `current_index` setter 每次都发 `option_changed`（包括 clamp 成同值），批量初始化用 `set_index_no_signal()`；禁用只置灰并 disable 按钮，键盘焦点链要自行跳过。`Background` 只收 `Parallax2D` 子节点；`ShaderProgressBar` 换 `item` 会重连 `value_changed`，`item.material` 为空时静默跳过。

## 文件结构

UI/ 平铺：两个面板基类 + `UIPanelTool` 状态机；`ButtonView` / `ButtonView3D` 是对应维度的事件与动画基类，
`DragView3D` 在其上增加拖拽；其余三个是独立小控件。
