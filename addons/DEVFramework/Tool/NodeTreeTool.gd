class_name NodeTreeTool

## 通用节点树生命周期/存档编排工具(原 ActorTool, 更名以反映通用定位):
## 按约定在子节点上实现 game_init/game_ready/save_data/load_data, 由宿主统一调度。

## 节点是否仍可用于展示/交互：未释放、在树内、父链可见。
## 被回收或隐藏的节点不该再收悬停、提示与焦点。
static func is_alive(v: Variant) -> bool:
	if not is_instance_valid(v):
		return false
	if v is Node:
		var node: Node = v
		return node.is_inside_tree() and node.is_visible_in_tree()
	return true

## 遍历指定节点的子节点，在所有子节点上调用同名函数
static func call_on_children(node: Node, func_name: String):
	for child in node.get_children():
		if func_name in child:
			await child.call(func_name)

## 只调用一次的初始化
static func game_init(node: Node):
	await call_on_children(node, "game_init")

## 游戏初始化，读档时也会调用
static func game_ready(node: Node):
	await call_on_children(node, "game_ready")

## 遍历子节点调用 save_data，返回收集的数据字典
static func save_data(node: Node):
	var data = {}
	for child in node.get_children():
		if "save_data" in child:
			data[child.name] = await child.save_data()
	return data

## 遍历子节点调用 load_data，data 为 null 或缺少子节点 key 时传 null
## 注意：按正向顺序遍历，依赖组件应确保其 load_data 不依赖后续组件的状态
static func load_data(node: Node, data):
	if not data:
		return
	for child in node.get_children():
		if "load_data" in child and data.has(child.name):
			await child.load_data(data[child.name])
