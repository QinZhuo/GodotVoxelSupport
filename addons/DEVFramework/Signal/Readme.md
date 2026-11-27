# Signal 信号与条件

把"监听哪个信号的哪一次触发、要满足什么条件"表达成 Def 资源；本模块只提供 Def 层，何时连接由消费方决定。
`Task` 的 `SignalTask` / `CountTask` 是现成消费方，`ConditionDef` 同时被 Task 前置条件与 AI 的 GOAP 条件复用。

| 类 | 职责 |
|---|---|
| `ConditionDef` | `@abstract`：`is_met(context) -> bool` |
| `ValueConditionDef` | 两个 `ValueDef`（`value` / `target`）按 `mode` 比较（Equal / NotEqual / Greater / Less / GreaterEqual / LessEqual） |
| `SignalDef` | `@abstract`：`connect_signal(data, callable)` / `disconnect_signal(data, callable)`；`static get_root(data)` 解析宿主根节点 |
| `NodeSignalDef` | `node_path` + `signal_name`：连接上下文 root 下某节点的某信号 |
| `ConditionSignalDef` | 包装另一个 `signal_def`，只有 `condition.is_met(data)` 时才转发回调 |

连接上下文约定是 `Dictionary{"root": Node}`，也接受直接传 `Node` 或带 `root` 属性的对象。

```gdscript
var sig := NodeSignalDef.new()
sig.node_path = ^"Button"
sig.signal_name = &"pressed"
var data := {"root": self}
sig.connect_signal(data, Callable(self, "_on_fired"))
sig.disconnect_signal(data, Callable(self, "_on_fired"))

var guard := ConditionSignalDef.new()
guard.signal_def = sig
guard.condition = cond
guard.connect_signal(data, cb)      # 条件不满足时不转发
```

## 坑

1. `SignalDef` 不得保存运行时状态：Def 是共享资源，同一份会被多个持有者复用；连接状态只存在于调用方传的 `data` 与 `callable`。
2. 断开必须传与连接时同形的 `Callable`：`Callable` 相等性只比较"对象 + 方法"，`bind()` 的参数不参与比较；`ConditionSignalDef` 两端都用 `_on_signal.bind(data, callable)` 就是为了让 connect / disconnect 对得上。
3. 上下文解析不出 root 时 `NodeSignalDef` 会 `push_error` 而不是静默跳过；日志里"上下文缺少 root 节点"就是 `data` 传错了。
4. `ValueConditionDef` 用 `get_int`（向上取整）比较，不是 `get_float`；任一 `ValueDef` 留空直接返回 false 且不报错，容易误判成"条件没满足"。
5. `NodeSignalDef` 连接前用 `is_connected` 去重、断开前也判一次；自己写子类时这套去重必须保留。
6. 本模块只有 Def 层：建连与断开在消费方（如 `SignalTask.activate` / `_teardown`），消费方持有 `Array[SignalDef]`，激活时逐个 connect、释放时逐个 disconnect。
