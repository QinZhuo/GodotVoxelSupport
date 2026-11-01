extends TestCase

## 结构增删移必须能撤销。
## 【为什么专门钉】这曾经是刻意不做的（"结构操作与体素编辑是两类东西"），代价是
## "删错一个模型、按 Ctrl+Z 没反应" —— 用户能踩到的最直接的"东西丢了"。
## 三种操作在数据上同构（节点换了个位置），所以共用一条 `QVoxelStructureCommand`。


## 一条装配好的会话：一个世界、一个模型、已激活。
func _session() -> QVoxelierSession:
	var s := QVoxelierSession.new()
	var w := QVoxelWorld.create_empty()
	w.add_material(Color.RED)
	s.install(w, w.create_model("Model A", Vector3i(8, 8, 8)))
	return s


func test_add_group_undo_redo() -> void:
	var s := _session()
	var before := s.world.all_nodes().size()
	s.add_group(null)
	assert_eq(s.world.all_nodes().size(), before + 1, "新建组")
	s.session.history.undo()
	assert_eq(s.world.all_nodes().size(), before, "撤销后组应消失")
	s.session.history.redo()
	assert_eq(s.world.all_nodes().size(), before + 1, "重做后组应回来")


## 删除当前对象时，命令必须留在**它自己的**历史里（删完 session 就换人了）。
func test_remove_model_undo() -> void:
	var s := _session()
	s.add_model(null)
	var list: Array = s.world.all_models()
	var victim: QVoxelModel = list[list.size() - 1]
	var vid: int = victim.model_id
	var vname: String = victim.node_name
	var hist := s.session
	var before := s.world.all_models().size()
	s.remove_node(victim)
	assert_eq(s.world.all_models().size(), before - 1, "删除生效")
	hist.history.undo()
	assert_eq(s.world.all_models().size(), before, "撤销后模型应回来")
	var back: QVoxelModel = s.world.find_model(vid)
	assert_true(back != null, "按 id 能找回来")
	if back == null:
		return
	assert_eq(back.node_name, vname, "名字保持不变")
	s.activate(vid)
	assert_true(s.session != null and s.session.object == back, "恢复后应能继续编辑")


func test_move_node_undo() -> void:
	var s := _session()
	var g := s.world.create_group("G", null)
	var m: QVoxelModel = s.world.all_models()[0]
	var from_parent: QVoxelGroup = s.world.find_parent(m)
	s.move_node(m, g, -1)
	assert_eq(s.world.find_parent(m), g, "移进组")
	s.session.history.undo()
	assert_eq(s.world.find_parent(m), from_parent, "撤销后回到原来的父")


## 新建模型也能撤：与"新建组"走同一条记录。
func test_add_model_undo() -> void:
	var s := _session()
	var before := s.world.all_models().size()
	s.add_model(null)
	assert_eq(s.world.all_models().size(), before + 1, "新建模型")
	s.session.history.undo()
	assert_eq(s.world.all_models().size(), before, "撤销后应少一个")
