@tool
class_name QVoxDomain
extends RefCounted

## 求值域 —— 一条链上只允许存在三种数据形态，且只能单向降级。
##
## 【为什么需要"域"这个概念】Blender 的修改器只有一个域（Mesh），因为网格拓扑可以随便变。
## 体素不行：体素被钉死在格点上，一旦光栅化就再也回不到连续距离场。若假装只有"一种数据"，
## 链上每个算子就得自己回答"我拿到的到底是距离场还是体素" —— 这正是当前插件把数据流硬编码
## 成三段（SDF 生成 → 细节层 → 网格化）却无法重排、无法插中间节点的根因。
##
## 把域显式化之后：
##   ① 每个算子只声明"我吃哪个域、吐哪个域"，引擎据此校验链的合法性；
##   ② 降级点（FIELD→VOXEL 的光栅化、VOXEL→MESH 的网格化）由引擎自动插入，用户看不见
##      —— 这就是"简单易用"的来源：用户只说"我要在这儿加个侵蚀"，引擎自己知道那意味着
##      "先把前面的 SDF 光栅化，再侵蚀"；
##   ③ 反向降级被明确禁止，于是"体素能不能做重拓扑"这类争论有了确定性答案：不能，
##      要重拓扑就把链降到 MESH 域用网格算子。
##
## 【与 Blender / Houdini 的差异（刻意的）】Blender 用单域换简单，Houdini 用全 DAG 换
## 表达力。本设计取第三条路：线性链 + 每个修改器可挂子图（见 DESIGN.md「线性链承载 DAG」）。
##
## 【域由修改器类型表达，不靠方法探测】链上唯一的条目类型是 QVoxModifier，它的子类直接
## 就是域（QVoxSdfModifier → FIELD，QVoxModelModifier / QVoxVolumeModifier → VOXEL）。于是
## "这个条目属于哪个域""它是不是源"都是类型问题；本类只保留"这样排合不合法"的规则。


## 三种数据形态。数值大小即"降级程度"，链上的域序号必须非递减。
enum Kind {
	FIELD, ## 连续距离场：p → Vector2(有符号距离, 材质ID)。分辨率无关。
	VOXEL, ## 离散体素体积：有界 grid 上的 PackedInt32Array（材质ID，0 = 空）。
	MESH,  ## 多边形网格：Mesh.ARRAY_* 组成的 arrays。
}

## 域的中文名（UI 徽标与报错文案用）。
const KIND_NAMES: PackedStringArray = ["连续", "体素", "网格"]

## 合成方式 —— 第 i 个修改器"如何并进已累积的结果"。
## 于是线性链天然表达了一棵左结合二叉树，用户不需要理解树。
##
## 【为什么它属于修改器而不是算子】"怎么并"是这一次使用的问题，不是算法本身的问题：
## 同一棵 Sdf 树既能被并进去，也能被减掉。这也让链上的布尔只有一种画法 —— 用户不必纠结
## "该拖 SdfUnion 还是该设 combine"。
enum Combine {
	REPLACE,      ## 替换（基础体；链首修改器的默认语义）
	UNION,        ## 并（A ∪ B）
	SUBTRACT,     ## 差（A \ B）
	INTERSECT,    ## 交（A ∩ B）
	SMOOTH_UNION, ## 平滑并（圆角过渡，宽度由 QVoxModifier.blend 给出）
}

const COMBINE_NAMES: PackedStringArray = ["替换", "并集", "差集", "交集", "平滑并集"]

## 体素域没有"平滑并"这种连续语义，遇到就报错而不是静默退化。
const COMBINE_FIELD_ONLY: Array[Combine] = [Combine.SMOOTH_UNION]


## 校验一条修改器链，返回人类可读的错误列表（空 = 合法）。
##
## 【为什么要在求值前校验】域序号回升是"设计错误"而非"运行时错误" —— 它一定有明确的人为
## 原因（修改器被拖错了位置）。编辑器据此在条目上实时打红标，把问题挡在求值之前。
static func validate_chain(modifiers: Array) -> PackedStringArray:
	var errs := PackedStringArray()
	var prev := -1
	for i in modifiers.size():
		var m: QVoxModifier = modifiers[i]
		if m == null or m.op() == null:
			continue
		var d := m.domain()
		if d < prev:
			errs.append("修改器 %d（%s）属于%s域，但它前面已经降到%s域 —— 域只能单向降级"
					% [i, m.display_name(), KIND_NAMES[d], KIND_NAMES[prev]])
			continue
		if d == Kind.VOXEL:
			if not m.is_source() and m.combine != Combine.REPLACE:
				errs.append("修改器 %d（%s）是就地改写型体素算子，合成方式只能是「替换」；"
						% [i, m.display_name()]
						+ "它已被调用即已拿到整块体积，布尔该由它自己决定（如 PcgWeather 保护顶面）")
			if m.combine in COMBINE_FIELD_ONLY:
				errs.append("修改器 %d（%s）在体素域，体素没有「%s」这种连续语义"
						% [i, m.display_name(), COMBINE_NAMES[m.combine]])
		if d == Kind.MESH and m.combine != Combine.REPLACE:
			errs.append("修改器 %d（%s）在网格域，网格算子只能「替换」结果"
					% [i, m.display_name()])
		prev = maxi(prev, d)
	return errs


## 链最终停在的域（空链 = VOXEL：只有手绘基础体素）。
static func final_domain(modifiers: Array) -> Kind:
	var last := Kind.VOXEL
	for item in modifiers:
		var m: QVoxModifier = item
		if m == null or not m.is_active():
			continue
		last = m.domain()
	return last
