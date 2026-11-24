@tool
extends RefCounted

## ======= MCP 资源(静态文档)注册表 =======
## 本文件**必须导出安全**(不得出现 EditorInterface 等编辑器引用): resources/list|read 在

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")

## 已注册文档(provider 声明顺序 = 稳定顺序, 满足规范"确定性排序"要求)。
static var _docs: Array = []

## ---- 内置长文(见 register_builtin; 工具描述里按 uri 引用它们) ----
const BUILTIN_REFRESH := """# refresh_tools 的适用范围

## 它能做什么

把 MCP 目录下的**域脚本**重新从磁盘加载, 再按注册路径重建工具表, 然后跑一遍契约自检。
响应里的 `schema_fingerprint` 是"注册表内容"的哈希: **跨次对比指纹, 相同即工具表没变**——
这是判断"我改了代码到底生效没有"的唯一可靠依据(别拿响应文本判断, 它永远说成功)。

## 它做不到什么(一定会骗你的那种)

1. **MCPDevServer.gd 自身的方法体不会被热替换。** 那个文件里的 `_register_*` 函数、handler
   内联实现、常量化描述, 改了之后 refresh 仍返回"成功", 但注册表原样不动 —— 指纹不变即是证据。
   改它必须 `restart_editor`(或禁用再启用 DEVFramework 插件重建服务器实例)。
2. **客户端不会自动刷新工具表。** 本服务器是短连接 HTTP, capabilities 里如实报了
   `tools.listChanged = false`, 发不出变更通知。客户端(IDE/Agent)缓存的 tools/list 仍是旧的,
   要在 IDE 侧重连 MCP。排查时以直接请求 `tools/list` 的结果为准, 别信会话开始时的快照。

## 典型误用

- 改了域脚本 → refresh → 看到"工具数没变"就以为改错了。**先看 fingerprint 有没有变**:
  没变说明注册路径没走到(比如新工具没被 register 函数调用), 变了但数量没变说明是替换而非新增。
- refresh 之后立刻发现客户端侧工具消失: 重连 MCP 即可(服务器本身是好的, 用 tools/list 直查可验)。
"""
const BUILTIN_EVAL := """# eval_code 的执行环境

## 两个进程

`process=editor`: 在**编辑器进程**里跑(读写编辑态、操作未运行的游戏场景、查编辑器服务)。
`process=game`: 在**正在运行的游戏进程**里跑(读运行期状态、改变量、触发业务逻辑)。

导出/独立运行时没有编辑器进程, 此时 `process=game` 指"本进程"。

## 新鲜度闸门(只在 process=game 生效)

引擎**不会热重载游戏进程里的脚本**。改过 .gd 之后:
1. 工具会先尝试把磁盘版本热重载进去;
2. 对"已有既存实例的脚本"和"全局类", 热重载是**不可靠**的, 于是直接拒绝执行并返回
   `error_category = stale_code`;
3. 此时正确做法是 `game_control(action=start)` 重启游戏再验, 而不是 `allow_stale=true`。
   `allow_stale` 只给"只读排查"用 —— 拿它验证改动是否生效会得到假结论。

## 代码形状

传的是**方法体**(缩进由服务器处理), 用 `return` 交回值。支持 `await`, 超时
`timeout_ms` 默认 8000、上限 15000。节点访问用 `/root/...` 或
`get_tree().current_scene.get_node(...)` —— eval 实例不是场景节点, 相对路径不指向你的场景。

## 副作用

这是**真执行**: 会改状态、触发信号、走进业务逻辑(扣血/存档/切场景)。重复调用会叠加副作用。
纯观测优先用专用只读工具(get_scene_tree / get_node_info / get_logs / perf / get_interactables),
它们不会因为"多看一眼"改变游戏状态。
"""
const BUILTIN_TESTS := """# run_tests 的 job 模型

## 为什么是 job 而不是一次调用

全量测试可能跑几十秒到几分钟, 而 MCP 客户端有请求超时。所以:
- `wait_sec`(0..25) 是"我愿意在这个调用里等多久";
- 窗口内跑完 → 直接返回完整汇总;
- 没跑完 → 返回 `{job_id, running: true, ...}`, 之后用 `job_wait(job_id)` 轮询。

`job_wait` **固定等 28 秒**(不跑重跑任务), 完成即带完整结果返回; 仍未完成则回进度快照,
接着调它即可。别用 sleep 循环去猜。

## job 归属

job 状态存在**启动它的进程**里(editor 段的 job 在编辑器进程, game 段的 job 在游戏进程)。
进程重启 = job 蒸发, 此时 `job_wait` 会明确报找不到, 不会假装成功。

`job_cancel` 在下一个检查点生效; 正在 await 的协程无法中途掐断, 所以可能要等当前用例跑完。

## 段落与跳过

`process=editor`: 只跑进程无关用例。`process=game`: 跑 need_game_process 用例(没有运行中的
游戏时会自动启动一个)。`process=both`: 同步阻塞跑两段并合并 —— 长任务, 别配大 wait_sec。
被跳过的用例在 `skipped` 里带原因(例如"需要游戏进程"), 别当成通过。
"""
const BUILTIN_SIM := """# UI 自动化: ref 语义与三类注入路径

## 先查后点

`get_interactables` 返回的 `ref`(e1/e2...)是**服务端解析的实时位置**, 不是坐标快照。
界面在查询后有动画/位移, 用 ref 点击仍然命中; 若报"未知 ref", 说明界面已变, 重新查一次。

## 三条注入路径(工具替你选, 但知道差别才不会误判)

1. **普通 2D 控件**: 按 window 坐标注入鼠标事件, 走完整 GUI 链路(悬停/焦点/按下/释放)。
2. **子视口里的 UI**(贴在 3D 显示器/平板上的那种): 事件**直接 push_input 进那个 SubViewport**。
   它不在窗口 GUI 层, 只按主窗口坐标点永远点不到 —— 这类元素只能靠 ref, x/y 无解。
3. **3D 物体**: 刻意**不给矩形/坐标**(3D 投影点随相机漂移, 算出来的坐标必然漂)。
   工具改为在物体自身激活一次(`activate()` 若存在, 否则 mouse_down + mouse_up)。

## 各类工具的边界

- `simulate_click` / `simulate_scroll`: 真注入输入事件, 走业务链路。重复调用 = 重复触发。
- `simulate_text`: **不注入按键**, 直接调控件的 `insert_text_at_caret` —— 否则中文进不去。
  所以它验证的是"输入之后的业务链路"(校验/提交/回填), 不是输入法本身。
- `simulate_key`: 只认工具内置的键名表(space/enter/escape/tab/方向键/修饰键/单字符)。
"""
const BUILTIN_CONV := """# 本 MCP 服务器的工具契约约定

## 命名

`get_*` 读、`set_*` 写、`list_*`/`search_*` 枚举、`simulate_*` 注入输入。
读写合一或多动作的工具用参数区分, 名字取动词(`save(scope=scene|all)`、
`crash_report(scope=exits|full)`、`resource_inspect(mode=tree|thumbnail|render)`)。

## 错误分类(error_category)

结果里的 `error_category` 决定调用方该"改参数"还是"等一等"还是"重启":

| 分类 | 含义 | 正确反应 |
|---|---|---|
| validation | 参数/前置条件不满足 | 按 message 改参数, 重试无意义 |
| transient | 临时失败 | 重试 |
| game_stopped | 游戏没跑 | `game_control(action=start)` |
| game_breaked | 游戏被断点/脚本错误暂停 | `game_control(action=continue)` |
| stale_code | 磁盘改了但进程还是旧代码 | `game_control(action=start)` 重启 |
| internal | 服务器内部错误 | 看日志, 别盲目重试 |

## 多实例路由

每个工具都有可选 `instance`(实例 id / 唯一前缀 / 端口号), 省略则用 `use_instance`
设的默认目标、没设过就作用于本实例。**目标不在线时报错而不是就地执行**。
详见 resources: devframework://docs/instances。

## 注解语义

- `readOnlyHint`: 不改任何状态(纯观测)。
- `destructiveHint`: 改动不可轻易撤销/不可重建(删文件、删节点、启动进程)。
  未登记的写工具**默认按破坏性处理**, 由客户端决定要不要弹确认。
- `idempotentHint`: 重复调用结果等价(重放安全)。

## 长任务

可能超过客户端超时的动作(构建、全量测试)返回 `{job_id, running: true}`, 用 `job_wait` 轮询,
`job_cancel` 取消。job 状态在启动它的进程里, 进程重启即消失。
"""


const BUILTIN_INSTANCES := """# 多实例路由: instance 参数到底怎么填

## 为什么有这个参数

装了本框架的多个 Godot 编辑器**共用一个端口**(默认 9988), 请求先到 Hub, 再由 Hub 转给目标实例。
所以每个工具都有可选 `instance` —— 它不是业务参数, 是"这条命令发给谁"。

## 三种填法

1. 实例 id, 形如 `MyGame@a1b2c3d4`(项目名 + 进程短哈希)—— 最精确, 先 list_instances 拿。
2. 唯一前缀, 形如 `MyGame` 或 `a1b2c3` —— 只在该前缀能唯一命中一个实例时成立。
3. 端口号, 形如 `9988` —— 直连那个实例的端口。

**不知道怎么填就先 `list_instances`**, 它只列在线的。

## 省略时的行为

- 用 `use_instance` 设过的**默认目标**(跨重启保留);
- 没设过默认目标 → **本实例**(也就是 Hub 自己所在的编辑器)。

默认目标存在但**此刻离线** → 直接报错, **不会**悄悄就地执行。理由: 宁可这次失败,
也不要改错项目。错误正文里会给出恢复动作(看看 list_instances / 重设默认目标)。

## 歧义

唯一前缀命中多个实例时, 报"有歧义"并列出候选; 与"实例不存在"是**两种不同错误**,
不要用同一个 catch 一起处理。

## 不参与路由的工具

`list_instances` / `use_instance` 自己就在操作"实例"这个维度, 没有 instance 参数,
永远在收到请求的进程上执行。

## 成员进程

被转发的那个进程没有路由能力(它只是被转发的一端), 直连它的端口时 instance 无效。
"""


## 清空(每轮工具注册前由 MCPDevServer 调用, 与 _reset_tools 同节奏)。
static func clear() -> void:
	_docs = []


## 合并一批文档。uri 重复时后者覆盖前者(便于同一 provider 分多次声明)。
static func register(docs: Array) -> void:
	for d in docs:
		if not (d is Dictionary):
			continue
		var doc: Dictionary = d
		if str(doc.get("uri", "")).is_empty() or str(doc.get("content", "")).is_empty():
			continue
		var i := _index_of(str(doc["uri"]))
		if i >= 0:
			_docs[i] = doc
		else:
			_docs.append(doc)


## resources/list 的响应体。
static func list_all() -> Array:
	var out: Array = []
	for d in _docs:
		out.append({
			"uri": d["uri"],
			"name": str(d.get("name", d["uri"])),
			"description": str(d.get("description", "")),
			"mimeType": str(d.get("mimeType", "text/markdown")),
		})
	return out


## resources/read 的 result 体。成功 {contents:[...]}; uri 未知返回 MCPResult 的 validation
static func read(uri: String) -> Dictionary:
	var i := _index_of(uri)
	if i < 0:
		return MCPResult.err_validation("未登记的资源 uri: %s" % uri,
			"先调 resources/list 取可用 uri(共 %d 份)" % _docs.size())
	var d: Dictionary = _docs[i]
	return {
		"contents": [{
			"uri": uri,
			"name": str(d.get("name", uri)),
			"description": str(d.get("description", "")),
			"mimeType": str(d.get("mimeType", "text/markdown")),
			"text": str(d.get("content", "")),
		}],
	}


## ======= 内置文档(本框架自带的"长文档在此, 别塞进工具描述") =======
## 为什么要有它: tools/list 是**常驻**开销(每个会话开始都要交一次全部工具的 description+schema),
## 而 resources 是**按需**的 —— 只有真要按这份说明操作时才读。
## 所以凡是"背景/为什么/例外/踩坑"这类长文都放这里, 工具描述只留"什么时候用、关键约束"。
## 这些 uri 是稳定契约(工具描述里直接引用了它们), 改名等于改 API。
static func register_builtin() -> void:
	register([
		{
			"uri": "devframework://docs/refresh_tools",
			"name": "什么时候 refresh_tools 有用、什么时候必须重启",
			"description": "工具注册表热重建的适用范围与 schema_fingerprint 判据",
			"content": BUILTIN_REFRESH,
		},
		{
			"uri": "devframework://docs/eval_code",
			"name": "eval_code 的执行环境与新鲜度闸门",
			"description": "editor/game 双进程差异、stale_code、await 与副作用边界",
			"content": BUILTIN_EVAL,
		},
		{
			"uri": "devframework://docs/run_tests",
			"name": "run_tests 的 job 模型",
			"description": "wait_sec 窗口、job_wait 固定 28 秒、job 状态归属进程",
			"content": BUILTIN_TESTS,
		},
		{
			"uri": "devframework://docs/simulate_ui",
			"name": "UI 自动化: ref 语义与三类注入路径",
			"description": "window/subviewport/3d 的差别, 为什么 3D 不给坐标",
			"content": BUILTIN_SIM,
		},
		{
			"uri": "devframework://docs/conventions",
			"name": "本 MCP 服务器的工具契约约定",
			"description": "命名、错误分类 error_category、instance 路由、job 模型、只读/破坏性标注",
			"content": BUILTIN_CONV,
		},
		{
			"uri": "devframework://docs/instances",
			"name": "多实例: instance 参数怎么填、省略时打给谁、离线为何报错",
			"description": "实例 id / 前缀 / 端口三选一, 默认目标与歧义判定",
			"content": BUILTIN_INSTANCES,
		},
	])


static func _index_of(uri: String) -> int:
	for i in _docs.size():
		if str((_docs[i] as Dictionary).get("uri", "")) == uri:
			return i
	return -1
