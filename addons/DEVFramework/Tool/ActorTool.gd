class_name ActorTool

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
