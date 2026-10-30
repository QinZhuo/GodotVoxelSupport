@tool
class_name VoxelCharacterRig
extends RefCounted
## 验证用体素角色 rig：Root/Hips/Torso/Head/双臂/双腿 + 一把剑，12 帧走路循环。
## 只做"源 rig"（组=骨骼、模型=刚性部件），动画在 transform_tracks 上；
## 烘焙器把它采样成 ANIM 体素帧。坐标：y 上，角色面朝 +z，脚底在 y=0。

const FRAMES := 12
const FPS := 12
const RAD := PI / 180.0


static func build_world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	var skin := w.add_material(Color8(224, 177, 137))
	var shirt := w.add_material(Color8(58, 110, 165))
	var shirt_dk := w.add_material(Color8(40, 78, 122))
	var pants := w.add_material(Color8(45, 60, 90))
	var shoes := w.add_material(Color8(70, 45, 30))
	var hair := w.add_material(Color8(45, 32, 24))
	var eye := w.add_material(Color8(20, 20, 24))
	var belt := w.add_material(Color8(90, 65, 35))
	var blade := w.add_material(Color8(180, 190, 200))
	var handle := w.add_material(Color8(90, 55, 30))

	var root := w.create_group("Root")
	var hips := w.create_group("Hips", root)
	hips.local_transform.origin = Vector3(0, 16, 0)
	var torso := w.create_group("Torso", hips)
	var head := w.create_group("Head", torso)
	head.local_transform.origin = Vector3(0, 10, 0)

	# 躯干：9×10×7，枢轴在髋部（底中心）。
	_part(w, torso, "TorsoMesh", [
		[Vector3i(3, 0, 4), Vector3i(11, 9, 10), shirt],
		[Vector3i(3, 0, 4), Vector3i(11, 0, 10), belt],
		[Vector3i(6, 2, 10), Vector3i(8, 8, 10), shirt_dk],
	], Transform3D(Basis.IDENTITY, Vector3(-7, 0, -7)))

	# 头：9×8×7，枢轴在脖子（底中心）；顶/后头发，正面两只眼。
	var head_mesh := _part(w, head, "HeadMesh", [
		[Vector3i(3, 0, 3), Vector3i(11, 7, 9), skin],
		[Vector3i(3, 6, 3), Vector3i(11, 7, 9), hair],
		[Vector3i(3, 3, 3), Vector3i(11, 7, 3), hair],
	], Transform3D(Basis.IDENTITY, Vector3(-7, 0, -6)))
	head_mesh.set_voxel(4, 4, 9, eye)
	head_mesh.set_voxel(10, 4, 9, eye)

	var arm_l := _limb(w, torso, "Shoulder.L", "UpperArm.L", Vector3(-4, 9, 0), shirt)
	var forearm_l := _limb(w, arm_l, "Elbow.L", "Forearm.L", Vector3(0, -6, 0), skin)
	_limb(w, forearm_l, "Wrist.L", "Hand.L", Vector3(0, -6, 0), skin)

	var arm_r := _limb(w, torso, "Shoulder.R", "UpperArm.R", Vector3(4, 9, 0), shirt)
	var forearm_r := _limb(w, arm_r, "Elbow.R", "Forearm.R", Vector3(0, -6, 0), skin)
	var hand_r := _limb(w, forearm_r, "Wrist.R", "Hand.R", Vector3(0, -6, 0), skin)
	# 剑：握在手骨末端，向上伸；也给烘焙器一个非身体部件。
	_part(w, hand_r, "Sword", [
		[Vector3i(7, 0, 7), Vector3i(8, 3, 8), handle],
		[Vector3i(5, 4, 7), Vector3i(10, 4, 8), handle],
		[Vector3i(7, 5, 7), Vector3i(8, 14, 8), blade],
	], Transform3D(Basis.IDENTITY, Vector3(-7, -2, -7)))

	var leg_l := _leg(w, hips, "Hip.L", "UpperLeg.L", Vector3(-2, 0, 0), pants)
	_leg(w, leg_l, "Knee.L", "LowerLeg.L", Vector3(0, -8, 0), pants, shoes)
	var leg_r := _leg(w, hips, "Hip.R", "UpperLeg.R", Vector3(2, 0, 0), pants)
	_leg(w, leg_r, "Knee.R", "LowerLeg.R", Vector3(0, -8, 0), pants, shoes)

	_animate(hips, torso, head, arm_l, arm_r, forearm_l, forearm_r, leg_l, leg_r)
	return w


## 生成一段简单的走路循环：髋部上下、躯干/头轻摆、四肢前后摆、膝盖弯。
static func _animate(hips: QVoxelNode, torso: QVoxelNode, head: QVoxelNode,
		arm_l: QVoxelNode, arm_r: QVoxelNode, forearm_l: QVoxelNode,
		forearm_r: QVoxelNode, leg_l: QVoxelNode, leg_r: QVoxelNode) -> void:
	var hips_track: Array[Transform3D] = []
	var torso_track: Array[Transform3D] = []
	var head_track: Array[Transform3D] = []
	var arm_l_track: Array[Transform3D] = []
	var arm_r_track: Array[Transform3D] = []
	var forearm_l_track: Array[Transform3D] = []
	var forearm_r_track: Array[Transform3D] = []
	var leg_l_track: Array[Transform3D] = []
	var leg_r_track: Array[Transform3D] = []
	for i in FRAMES:
		var phase := TAU * float(i) / float(FRAMES)
		var swing := sin(phase)
		var bob := 0.5 * sin(phase * 2.0)
		hips_track.append(_pose(hips.local_transform,
				Basis(Vector3.UP, 3.0 * RAD * swing), Vector3(0, bob, 0)))
		torso_track.append(_pose(torso.local_transform,
				Basis(Vector3.UP, -3.0 * RAD * swing), Vector3.ZERO))
		head_track.append(_pose(head.local_transform,
				Basis(Vector3.UP, 2.0 * RAD * swing), Vector3.ZERO))
		arm_l_track.append(_pose(arm_l.local_transform,
				Basis(Vector3.RIGHT, 25.0 * RAD * swing), Vector3.ZERO))
		arm_r_track.append(_pose(arm_r.local_transform,
				Basis(Vector3.RIGHT, -25.0 * RAD * swing), Vector3.ZERO))
		forearm_l_track.append(_pose(forearm_l.local_transform,
				Basis(Vector3.RIGHT, (10.0 + 10.0 * cos(phase)) * RAD), Vector3.ZERO))
		forearm_r_track.append(_pose(forearm_r.local_transform,
				Basis(Vector3.RIGHT, (10.0 - 10.0 * cos(phase)) * RAD), Vector3.ZERO))
		leg_l_track.append(_pose(leg_l.local_transform,
				Basis(Vector3.RIGHT, -28.0 * RAD * swing), Vector3.ZERO))
		leg_r_track.append(_pose(leg_r.local_transform,
				Basis(Vector3.RIGHT, 28.0 * RAD * swing), Vector3.ZERO))
	hips.transform_tracks = hips_track
	torso.transform_tracks = torso_track
	head.transform_tracks = head_track
	arm_l.transform_tracks = arm_l_track
	arm_r.transform_tracks = arm_r_track
	forearm_l.transform_tracks = forearm_l_track
	forearm_r.transform_tracks = forearm_r_track
	leg_l.transform_tracks = leg_l_track
	leg_r.transform_tracks = leg_r_track


static func _pose(rest: Transform3D, rot: Basis, shift: Vector3) -> Transform3D:
	return Transform3D(rest.basis * rot, rest.origin + shift)


## 手臂段：4×6×4，枢轴在顶中心。
static func _limb(w: QVoxelWorld, parent: QVoxelGroup, group_name: String,
		mesh_name: String, origin: Vector3, mat: int) -> QVoxelGroup:
	var g := w.create_group(group_name, parent)
	g.local_transform.origin = origin
	_part(w, g, mesh_name, [
		[Vector3i(1, 0, 1), Vector3i(4, 5, 4), mat],
	], Transform3D(Basis.IDENTITY, Vector3(-2, -6, -2)))
	return g


## 腿段：4×8×4，枢轴在顶中心；lower=true 时脚底加鞋。
static func _leg(w: QVoxelWorld, parent: QVoxelGroup, group_name: String,
		mesh_name: String, origin: Vector3, mat: int, shoe := -1) -> QVoxelGroup:
	var g := w.create_group(group_name, parent)
	g.local_transform.origin = origin
	var boxes: Array = [[Vector3i(1, 1, 1), Vector3i(4, 7, 4), mat]]
	if shoe >= 0:
		boxes.append([Vector3i(1, 0, 1), Vector3i(4, 0, 5), shoe])
	_part(w, g, mesh_name, boxes, Transform3D(Basis.IDENTITY, Vector3(-2, -8, -2)))
	return g


static func _part(w: QVoxelWorld, parent: QVoxelGroup, name: String,
		boxes: Array, xf: Transform3D) -> QVoxelModel:
	var m := w.create_model(name, Vector3i(16, 16, 16), parent)
	m.local_transform = xf
	for e in boxes:
		var a: Vector3i = e[0]
		var b: Vector3i = e[1]
		m.fill_box(a, b, int(e[2]))
	return m
