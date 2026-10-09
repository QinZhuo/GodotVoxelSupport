@tool
class_name QVoxEvalCache
extends RefCounted
## 树形求值的逐节点结果缓存（节点实例 id → 上一次结果）。
##
## 【为什么缓存是显式对象，而不是引擎里的静态变量】引擎是纯函数式的一层 —— 同样的输入给同样的
## 输出、可无头测试、可放进 worker 线程。静态缓存会把它变成有状态的单例，还会把"这份缓存属于
## 哪个视图"这件事藏起来（两个视口各有一份缓存，谁都不该看见对方的）。故缓存由消费方持有并
## 传进引擎 —— 谁持有，谁负责它的生命周期与失效。
##
## 【为什么按实例 id 分桶】签名（QVoxNode.signature / QVoxModifier.signature）已经回答了
## "这个节点变了没有"；缓存只需回答"上一次结果放在哪"。实例 id 稳定、廉价，且天然按节点分桶
## —— 两个内容完全相同的节点不会互相顶替（与 QVoxEvalEngine.inputs_key 含实例 id 同一条理由）。
##
## 【与 QVoxModelGenerator._last 的关系】那个是"一个生成器一个模型"的缓存（单模型链路径）；
## 本类是"一棵树里每个节点各一份"（树形路径）。两者不会同时作用于同一节点：
## 模型由生成器渲染时走前者，模型被当树上的子节点求值时走后者。

var _by_node := {}


## 该节点上一次的求值结果（无则 null）。直接喂给 QVoxEvalEngine.evaluate_node 的 previous。
func previous_of(node: QVoxNode) -> QVoxEvalResult:
	if node == null:
		return null
	var r: QVoxEvalResult = _by_node.get(node.get_instance_id())
	return r


func store(node: QVoxNode, res: QVoxEvalResult) -> void:
	if node != null:
		_by_node[node.get_instance_id()] = res


## 丢弃某节点及其整棵子树的缓存。节点被删除时调用 —— 否则缓存会一直攥着已删节点的结果，
## 而实例 id 会被引擎复用（"新建的节点恰好拿到旧 id"），于是新节点一上来就命中旧结果。
func forget(node: QVoxNode) -> void:
	if node == null:
		return
	_by_node.erase(node.get_instance_id())
	for c in node.children():
		forget(c)


func clear() -> void:
	_by_node.clear()
