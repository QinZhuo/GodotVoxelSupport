# GameCommand 模块

"命令即数据"：把一次玩家/AI 决策记录为可序列化的数据单元，用于回放、战绩审计与 headless 自动化测试。

## 组成

| 类 | 职责 |
|---|---|
| `GameCommand` | 一条命令记录：`type`(StringName 类型名) + `tick`(时序序号，回合制下即回合号) + `params`(决策参数数组) |
| `CommandHistory` | 按序记录命令；按 tick 过滤/弹出；整体序列化 |
| `InputSource` | 决策输入策略基类（事件驱动轮询，回合制/实时通用）。模拟层通过 `take(request) -> int` 取一次决策（内部 `poll(request) -> Array`，空数组=本次无输入），答案自动登记到 `taken` |
| `ReplayInputSource` | 回放输入源：按序弹出预录输入（`inputs`），绝不触碰 UI；`from_answers()` 可直接用记录的决策段构造 |

## 典型流程

1. 实战时：模拟层通过真实 UI 的 InputSource 获取决策 → 成功后构造 `GameCommand` 写入 `CommandHistory`
2. 存档：`history.save_data()` 得到纯 Array，可随存档保存
3. 回放/测试：`GameCommand.load_data()` 还原 → 把 params 决策段喂给 `ReplayInputSource.from_answers()` → 重放模拟，结束时比对 `taken` 与 `inputs` 确定一致

## 示例

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

## 约定

- `InputSource.poll(request)` 返回空数组表示本次无输入（实时每帧轮询为常态）；回合制可事件驱动入队 + 轮询消费。`request` 是上层定义的"交互描述对象"（如选择请求、目标请求），框架只透传、不感知其类型
- 取消等操作用显式命令表达（如 &"cancel"），不用哨兵值
- `params[0]` 惯例为命令主体标识
- 同一命令序列 + 相同初始状态 ⇒ 必须复现相同结果（确定性回放）
