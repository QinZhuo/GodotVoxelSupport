@tool
class_name QVoxelDomain
extends RefCounted

## 求值域 —— 一条链上只允许存在两种数据形态，且只能单向降级。
## 【为什么需要"域"这个概念】Blender 的修改器只有一个域（Mesh），因为网格拓扑可以随便变。
## 体素不行：体素被钉死在格点上，一旦光栅化就再也回不到连续距离场。若假装只有"一种数据"，
## 链上每个算子就得自己回答"我拿到的到底是距离场还是体素" —— 这正是当前插件把数据流硬编码
## 成三段（SDF 生成 → 细节层 → 网格化）却无法重排、无法插中间节点的根因。
## 把域显式化之后：
##   ① 每个算子只声明"我吃哪个域、吐哪个域"，引擎据此校验链的合法性；
##   ② 降级点（FIELD→VOXEL 的光栅化）由引擎自动插入，用户看不见 —— 这就是"简单易用"的
##      来源：用户只说"我要在这儿加个侵蚀"，引擎自己知道那意味着"先把前面的 SDF 光栅化，
##      再侵蚀"；
##   ③ 反向降级被明确禁止，于是"体素能不能做重拓扑"这类争论有了确定性答案：不能。
##      体素格点本身就是这种表现形式的最小可改元素（同像素画的像素），倒角 / 减面 / 平滑
##      是对**网格拓扑**的改写，不属于体素的表达范围 —— 想让体素"看起来更精致"，办法是
##      把它画得更细，而不是回头改拓扑。
## 【与 Blender / Houdini 的差异（刻意的）】Blender 用单域换简单，Houdini 用全 DAG 换
## 表达力。本设计取第三条路：线性链 + 每个修改器可挂子图。
## 【域由修改器类型表达，不靠方法探测】链上唯一的条目类型是 QVoxelModifier，它的子类直接
## 就是域（QVoxelSdfModifier → FIELD，QVoxelModelModifier / QVoxelVolumeModifier → VOXEL）。于是
## "这个条目属于哪个域""它是不是源"都是类型问题；本类只保留"这样排合不合法"的规则。


## 两种数据形态。数值大小即"降级程度"，链上的域序号必须非递减。
enum Kind {
	FIELD, ## 连续距离场：p → Vector2(有符号距离, 材质ID)。分辨率无关。
	VOXEL, ## 离散体素体积：有界 grid 上的 PackedInt32Array（材质ID，0 = 空）。链的终点。
}

## 域的中文名（UI 徽标与报错文案用）。
const KIND_NAMES: PackedStringArray = ["连续", "体素"]

## 合成方式 —— 第 i 个修改器"如何并进已累积的结果"。
## 于是线性链天然表达了一棵左结合二叉树，用户不需要理解树。
## 【为什么它属于修改器而不是算子】"怎么并"是这一次使用的问题，不是算法本身的问题：
## 同一棵 Sdf 树既能被并进去，也能被减掉。这也让链上的布尔只有一种画法 —— 用户不必纠结
## "该拖 SdfUnion 还是该设 combine"。
enum Combine {
	REPLACE,      ## 替换（基础体；链首修改器的默认语义）
	UNION,        ## 并（A ∪ B）
	SUBTRACT,     ## 差（A \ B）
	INTERSECT,    ## 交（A ∩ B）
	SMOOTH_UNION, ## 平滑并（圆角过渡，宽度由 QVoxelModifier.blend 给出）
}

const COMBINE_NAMES: PackedStringArray = ["替换", "并集", "差集", "交集", "平滑并集"]

## 体素域没有"平滑并"这种连续语义，遇到就报错而不是静默退化。
const COMBINE_FIELD_ONLY: Array[Combine] = [Combine.SMOOTH_UNION]

## 算子能力探测的**唯一签名表**（全项目只此一份）。
## 【为什么用常量而不是散落的 has_method("...")】方法名是算子的对外契约，一旦写成字符串字面量
## 散布各处，改名时没有编译器帮忙找全；集中在这里则"引擎认识哪些能力"一眼可读。
## 【为什么是方法存在性而不是共用基类】算子文件零改动就能接入新能力（不给 Sdf / PcgDetail /
## PcgModel 加新基类）—— 共用基类会把两个本可独立演化的模块永久绑在一起。
## 【为什么"源"不用这里判】源与算子的区别（`QVoxelModifier.is_source`）是**类型级**的：
## 体素域分"自足产出"（PcgModel）与"就地改写 / 重排"（PcgDetail / PcgTransform），
## 而后者拿不到输入就做不了布尔 —— 这条区别必须在链校验里是硬约束，故由子类类型表达。
const CAP_SAMPLE := &"sample"          ## FIELD：逐点采样
const CAP_BUILD := &"build"            ## VOXEL 源：整体产出
const CAP_APPLY := &"apply"            ## VOXEL 就地改写（不得改盒尺寸）
const CAP_RESHAPE := &"reshape"        ## VOXEL 重排（**可改盒尺寸**）


## 校验一条修改器链，返回**结构化**错误列表（空 = 合法）。
## 每条 = {"index": int, "message": String}；index 指向链上的第几条，-1 表示链级问题。
## 【为什么要在求值前校验】域序号回升是"设计错误"而非"运行时错误" —— 它一定有明确的人为
## 原因（修改器被拖错了位置）。编辑器据此在条目上实时打红标，把问题挡在求值之前。
## 【为什么另给一个结构化入口】编辑器要在**出错的那一条**上打红标，而它不该去解析人类可读的
## 中文提示（提示里改一个字，红标就悄悄失效）。规则只写在这一处，validate_chain() 只是它的
## 字符串投影 —— 两个入口共用同一份规则，不会各写一遍。
static func chain_errors(modifiers: Array) -> Array:
	var errs: Array = []
	var prev := -1
	for i in modifiers.size():
		var m: QVoxelModifier = modifiers[i]
		if m == null or m.op() == null:
			continue
		var d := m.domain()
		if d < prev:
			errs.append({"index": i,
					"message": "修改器 %d（%s）属于%s域，但它前面已经降到%s域 —— 域只能单向降级"
					% [i, m.display_name(), KIND_NAMES[d], KIND_NAMES[prev]]})
			continue
		if d == Kind.VOXEL:
			if not m.is_source() and m.combine != Combine.REPLACE:
				errs.append({"index": i,
						"message": "修改器 %d（%s）是%s型体素算子，合成方式只能是「替换」；"
						% [i, m.display_name(), "重排 / 摆放" if m.is_reshape() else "就地改写"]
						+ ("整块结果的盒尺寸 / 摆放由它自己决定，谈不上「并进已累积结果」" if m.is_reshape()
						else "它已被调用即已拿到整块体积，布尔该由它自己决定（如 PcgWeather 保护顶面）")})
			if m.combine in COMBINE_FIELD_ONLY:
				errs.append({"index": i,
						"message": "修改器 %d（%s）在体素域，体素没有「%s」这种连续语义"
						% [i, m.display_name(), COMBINE_NAMES[m.combine]]})
		prev = maxi(prev, d)
	return errs


## 校验一条修改器链，返回人类可读的错误列表（空 = 合法）。chain_errors() 的字符串投影。
static func validate_chain(modifiers: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for e in chain_errors(modifiers):
		out.append(String(e["message"]))
	return out


## 链最终停在的域（空链 = VOXEL：只有手绘基础体素）。
static func final_domain(modifiers: Array) -> Kind:
	var last := Kind.VOXEL
	for item in modifiers:
		var m: QVoxelModifier = item
		if m == null or not m.is_active():
			continue
		last = m.domain()
	return last
