# GameCommand 模块

"命令即数据"：把一次玩家/AI 决策记录为可序列化的数据单元，用于回放、战绩审计与 headless 自动化测试。

## 组成

| 类 | 职责 |
|---|---|
| `GameCommand` | 一条命令记录：`type`(StringName 类型名) + `tick`(时序序号，回合制下即回合号) + `params`(决策参数数组) |
| `CommandHistory` | 按序记录命令；按 tick 过滤/弹出；整体序列化 |
| `InputSource` | 决策输入策略基类（tick 轮询模型，回合制/实时通用）。模拟层通过 `poll(tick) -> Array` 获取决策，空数组=本 tick 无输入 |
| `ReplayInputSource` | 回放输入源：按序弹出预录输入（`inputs`），并记录已消费的 `consumed` 供校验 |

## 典型流程

1. 实战时：模拟层通过真实 UI 的 InputSource 获取决策 → 成功后构造 `GameCommand` 写入 `CommandHistory`
2. 存档：`history.save_data()` 得到纯 Array，可随存档保存
3. 回放/测试：`GameCommand.load_data()` 还原 → 把 params 决策段喂给 `ReplayInputSource.inputs` → 重放模拟，结束时比对 consumed 与 inputs 确定一致

## 示例

```gdscript
# 记录
var history := CommandHistory.new()
history.append(GameCommand.new(&"pick_column", tick, [3]))
var data: Array = history.save_data()

# 回放
var replay := ReplayInputSource.new([[3]])
var value: Array = replay.poll(0)   # -> [3]
assert(replay.consumed == [[3]])
```

演示场景：`Scenes/GameCommandDemo/GameCommandDemo.tscn`

## 约定

- `InputSource.poll(tick)` 返回空数组表示本 tick 无输入（实时每帧轮询为常态）；回合制可事件驱动入队 + 轮询消费
- 取消等操作用显式命令表达（如 &"cancel"），不用哨兵值
- `params[0]` 惯例为命令主体标识
- 同一命令序列 + 相同初始状态 ⇒ 必须复现相同结果（确定性回放）
