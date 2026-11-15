# GameCommand 命令回放

把一次决策记录成可序列化的数据单元，用于回放、战绩审计与 headless 自动化测试。

## 怎么用

| 类 | 职责 |
|---|---|
| `GameCommand` | `type`（StringName 类型名）+ `tick`（时序序号）+ `params`（决策参数数组） |
| `CommandHistory` | 按序记录、按 tick 过滤/弹出、整体序列化（`save_data()` / `GameCommand.load_data()`） |
| `InputSource` | 决策输入策略基类：`take(request) -> int` 取一次决策，内部 `poll(request) -> Array`，答案登记到 `taken` |
| `ReplayInputSource` | 按 `inputs` 顺序弹出预录输入；`from_answers()` 用记录的决策段构造 |

```gdscript
# 记录
var history := CommandHistory.new()
history.append(GameCommand.new(&"pick_column", tick, [3]))
var data: Array = history.save_data()

# 回放
var replay := ReplayInputSource.new([[3]])
var value: Array = replay.poll()    # -> [3]
var answer := await replay.take()   # -> 3（并登记 taken = [3]）
```

流程：实战时真实 InputSource 取决策 → 成功后写 `GameCommand` 进 `CommandHistory` → `save_data()` 存盘 → 回放时 `load_data()` 还原、params 喂给 `ReplayInputSource.from_answers()`，结束时比对 `taken` 与 `inputs`。

## 坑

1. `InputSource.poll(request)` 返回**空数组**表示本次无输入（实时逐帧轮询为常态）；`request` 是上层定义的交互描述对象，框架只透传。
2. 取消等操作用显式命令（如 `&"cancel"`），不要用哨兵值；`params[0]` 约定为命令主体标识。
3. 同一命令序列 + 相同初始状态必须复现相同结果（确定性回放）。
