extends TestCase

## 命令层契约测试：QVoxPropertyCommand（O(1) 属性撤销）+ QVoxMacroCommand / 撤销栈的宏。
##
## 钉死四条硬承诺 —— 每一条都对应一个"以后重构很容易悄悄弄坏"的点：
##   ① 撤销是**精确还原**而不是反向重算：撤到的是原值，且"没真改"不占一次撤销；
##   ② 链的增删重排也是属性（`modifiers` 数组的前后两份）→ 不需要第二个命令类，
##      而 `before` 必须与活数组**脱钩**（否则撤销拿到的是改完之后的内容，且不报错）；
##   ③ 改 Resource 参数不会自动发信号 → 由命令补发 content_changed 给宿主对象；
##   ④ 宏 = 一条撤销单位：一次 undo 全撤、一次 redo 全恢复，且空宏 / 嵌套有确定行为。


func _obj() -> QVoxObject:
	var obj := QVoxObject.new()
	obj.grid_size = Vector3i(32, 32, 32)
	return obj


## 计数宿主对象的标脏次数（content_changed）。
func _count_hits(obj: QVoxObject) -> Array:
	var hits := [0]
	obj.content_changed.connect(func() -> void: hits[0] += 1)
	return hits


# ----------------------------------------------------------------------------
# ① 精确还原 + 无变化不入栈
# ----------------------------------------------------------------------------

func test_property_command_restores_exact_value() -> void:
	var obj := _obj()
	var cmd := QVoxPropertyCommand.apply(obj, &"object_name", "石山", null, "重命名")
	assert_true(cmd != null, "改名应产生一条命令")
	assert_eq(obj.object_name, "石山", "命令应已把新值写进去")
	assert_eq(cmd.params[0], "object_name", "params 首个是属性名（可审计）")
	assert_eq(cmd.get_label(), "重命名", "自定义显示名直接用于撤销菜单")
	assert_eq(cmd.get_cost(), 1, "属性命令是 O(1)，不抓体素")

	cmd.undo()
	assert_eq(obj.object_name, "Voxel Object", "撤销必须回到原值，而不是反向重算")
	cmd.redo()
	assert_eq(obj.object_name, "石山", "重做必须回到新值")


func test_no_real_change_is_not_a_command() -> void:
	var obj := _obj()
	assert_true(QVoxPropertyCommand.apply(obj, &"object_name", obj.object_name) == null,
			"把值设成原样不该占一次撤销")
	var cmd := QVoxPropertyCommand.begin(obj, &"object_name")
	assert_false(cmd.commit(), "从头到尾没写入的手势不入栈")
	# 拖出去又拖回来：首尾相同 → 同样不该入栈
	var drag := QVoxPropertyCommand.begin(obj, &"object_name")
	drag.set_value("临时")
	drag.set_value("Voxel Object")
	assert_false(drag.commit(), "滑条拖回原位的空手势不入栈")


# ----------------------------------------------------------------------------
# ② 链编辑就是属性
# ----------------------------------------------------------------------------

func test_chain_edit_is_a_property_command() -> void:
	var obj := _obj()
	var sphere := SdfSphere.new()
	sphere.radius = 4.0
	obj.add_modifier(QVoxSdfModifier.of(sphere))
	var n0 := obj.modifiers.size()

	var cmd := QVoxPropertyCommand.begin(obj, &"modifiers")
	var box := SdfBox.new()
	obj.add_modifier(QVoxSdfModifier.of(box, QVoxDomain.Combine.SUBTRACT))
	assert_true(cmd.commit(), "链上加了一条，应产生命令")

	# before 必须与活数组脱钩：若它是同一个数组，这里的 append 会连 before 一起改，
	# 后面撤销就"撤了个寂寞"，而且一声不响。
	assert_eq(cmd.before.size(), n0, "before 必须停在改之前")

	cmd.undo()
	assert_eq(obj.modifiers.size(), n0, "撤销链编辑必须回到原长度")
	assert_true(obj.modifiers[0].op() == sphere, "撤销后原有条目仍是同一个实例")
	cmd.redo()
	assert_eq(obj.modifiers.size(), n0 + 1, "重做再把条目加回来")
	assert_eq(obj.modifiers[1].combine, QVoxDomain.Combine.SUBTRACT, "重做恢复的是同一个条目")


# ----------------------------------------------------------------------------
# ③ 改参数要标脏宿主对象
# ----------------------------------------------------------------------------

func test_modifier_param_marks_owner_dirty() -> void:
	var obj := _obj()
	var mod := QVoxModifierSerializer.new_modifier(QVoxModifier.KIND_SDF)
	obj.add_modifier(mod)
	var hits := _count_hits(obj)

	var cmd := QVoxPropertyCommand.apply(mod, &"blend", 8.0, obj)
	assert_true(cmd != null, "参数变化应产生命令")
	assert_eq(mod.blend, 8.0)
	assert_eq(hits[0], 0, "写入本身不发信号（手势期间静默，live 预览由面板自己刷新）")

	cmd.undo()
	assert_eq(mod.blend, 2.0, "参数撤销回默认值")
	assert_eq(hits[0], 1, "undo 必须标脏宿主对象 —— Resource 参数不会自动发信号")
	cmd.redo()
	assert_eq(mod.blend, 8.0)
	assert_eq(hits[0], 2, "redo 同样标脏")


func test_object_property_marks_itself_dirty() -> void:
	var obj := _obj()
	var hits := _count_hits(obj)
	var cmd := QVoxPropertyCommand.apply(obj, &"object_name", "山")
	assert_true(cmd != null, "target 就是 QVoxObject 时 owner 自动取它")
	cmd.undo()
	assert_eq(hits[0], 1, "对象自身属性同样要标脏")


# ----------------------------------------------------------------------------
# ④ 宏
# ----------------------------------------------------------------------------

func test_macro_folds_multiple_steps() -> void:
	var stack := QVoxUndoStack.new()
	var obj := _obj()
	var mod := QVoxModifierSerializer.new_modifier(QVoxModifier.KIND_SDF)
	obj.add_modifier(mod)

	stack.begin_macro("改参数并改名")
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "山"))
	stack.push(QVoxPropertyCommand.apply(mod, &"blend", 6.0, obj))
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "山"))  # 无变化 → null
	var macro := stack.end_macro()

	assert_true(macro != null, "有两条真实改动，宏应入栈")
	assert_eq(macro.size(), 2, "无变化的子命令不进宏")
	assert_eq(stack.size(), 1, "整段宏只占一条历史")
	assert_eq(obj.object_name, "山")
	assert_eq(mod.blend, 6.0)
	assert_eq(macro.get_cost(), 2, "宏的代价 = 子命令之和（预算淘汰按大单位衡量）")
	assert_eq(stack.undo_label(), "改参数并改名（2 步）", "菜单项文字概括整段")

	stack.undo()
	assert_eq(obj.object_name, "Voxel Object", "一次撤销撤掉整段")
	assert_eq(mod.blend, 2.0, "参数也一并回退")
	stack.redo()
	assert_eq(obj.object_name, "山", "一次重做恢复整段")
	assert_eq(mod.blend, 6.0)


func test_macro_notifies_once_and_keeps_stack_quiet() -> void:
	var stack := QVoxUndoStack.new()
	var obj := _obj()
	var n := [0]
	stack.changed.connect(func() -> void: n[0] += 1)

	stack.begin_macro("批量")
	assert_true(stack.in_macro())
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "A"))
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "B"))
	assert_eq(stack.size(), 0, "宏累积期间不入栈")
	assert_eq(n[0], 0, "宏累积期间不通知 —— UI 不该看到中间态的历史项")
	stack.end_macro()
	assert_false(stack.in_macro())
	assert_eq(n[0], 1, "宏入栈只通知一次")
	assert_eq(stack.size(), 1)


func test_empty_and_nested_macro() -> void:
	var stack := QVoxUndoStack.new()
	var obj := _obj()

	stack.begin_macro("什么都没干")
	assert_true(stack.end_macro() == null, "空宏不入栈（与空手势同一约定）")
	assert_eq(stack.size(), 0)
	assert_false(stack.in_macro(), "end_macro 必须把状态清干净")

	# 嵌套：内层并入外层，等最外层结束才入栈
	stack.begin_macro("外层")
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "甲"))
	stack.begin_macro("内层")
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "乙"))
	stack.end_macro()
	assert_eq(stack.size(), 0, "外层还没结束，栈上仍应为空")
	stack.end_macro()
	assert_eq(stack.size(), 1, "内层并入外层，仍只占一条")
	assert_eq(obj.object_name, "乙")

	stack.undo()
	assert_eq(obj.object_name, "Voxel Object", "一次撤销撤掉内外两层")


func test_tick_is_monotonic_across_macro() -> void:
	var stack := QVoxUndoStack.new()
	var obj := _obj()
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "一"))
	stack.begin_macro("宏")
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "二"))
	stack.end_macro()
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "三"))
	assert_eq(stack.size(), 3, "宏只占一条，故总长为 3")
	assert_eq(stack.commands[0].tick, 0)
	assert_eq(stack.commands[1].tick, 1, "宏自己占一个 tick，子命令不占")
	assert_eq(stack.commands[2].tick, 2, "tick 在宏前后保持单调（回放/审计据此排序）")


func test_clear_drops_open_macro() -> void:
	var stack := QVoxUndoStack.new()
	var obj := _obj()
	stack.begin_macro("半截宏")
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "A"))
	stack.clear()
	assert_false(stack.in_macro(), "clear() 是完全重置，不留半截宏")
	assert_eq(stack.size(), 0)


# ----------------------------------------------------------------------------
# 撤销栈的通用语义（属性命令作为最轻的命令载体来验证）
# ----------------------------------------------------------------------------

func test_push_truncates_redo_branch() -> void:
	var stack := QVoxUndoStack.new()
	var obj := _obj()
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "A"))
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "B"))
	stack.undo()
	assert_eq(obj.object_name, "A")
	assert_true(stack.can_redo())
	stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "C"))
	assert_false(stack.can_redo(), "新操作入栈必须丢掉 redo 分支（标准撤销语义）")
	assert_eq(obj.object_name, "C")
	assert_eq(stack.size(), 2)


func test_budget_evicts_oldest() -> void:
	var stack := QVoxUndoStack.new()
	stack.max_cost = 3
	var obj := _obj()
	for i in 5:
		stack.push(QVoxPropertyCommand.apply(obj, &"object_name", "N%d" % i))
	assert_eq(stack.size(), 3, "超预算时从队首淘汰最老的历史")
	assert_true(stack.can_undo(), "淘汰后剩余历史仍可撤销")
	assert_eq(stack.undo_label(), "属性 object_name", "未给 label 时退化为\"属性 <名>\"")
