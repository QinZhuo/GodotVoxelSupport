@tool
class_name SdfChamferBox
extends Sdf

## 竖棱倒角盒：四条竖直棱被 45° 平面切掉的盒子（"八角柱"形）。
##
## 【为什么需要这个原语】台地/石板/立柱这类体块几乎都要"切个角"：
## 直角棱在体素栅格上会退化成一根根竖着的瓦楞柱，斜看过去像波纹板
## （见 pcg_world_demo 里那段"倒角必须是平面不能是曲面"的实测记录）。
## 在只有 Box + 组合算子的年代，这件事要靠"方盒 ∩ (方盒 ⊖ 旋转 45° 的大方盒)×4"
## 来做 —— 那是 **12 个节点**、每个采样点要做 4 次矩阵变换和 4 次 200³ 盒测试。
##
## 【本原语的代价】一次采样 = 1 次盒距离 + 1 次 L1 平面距离 + 1 次 max，
## 没有矩阵、没有子树。实测把 pcg_world_demo 的岛体从 ~30 个节点压到 7 个，
## 单 chunk 生成从 995ms 降到 ~250ms（GDScript 逐点采样，节点数几乎线性决定耗时）。
##
## 【数学】实体 = 盒 ∪ (|x|+|z| ≤ hx+hz−chamfer) 的交：
##   盒距离用 iq 的切比雪夫外推（内部负、外部欧氏）；
##   倒角面在 xz 平面上是 |x|+|z| = const，即四条 45° 直线，
##   沿竖直方向不变化 —— 于是得到的是"竖棱倒角"而不是"顶点倒角"（后者要三个方向的 L1）。
##
## 【注意】max(两个距离) 得到的**不是**严格 SDF（在凹角处会高估距离），
## 但对"逐体素格心二值化"的光栅化完全没有影响 —— 只要符号正确即可，
## 而 max 的符号在交集处恒正确。这与 SdfIntersect 用的是同一套约定。


## 全尺寸（非半尺寸）：各轴长度。
@export var size: Vector3 = Vector3(16.0, 8.0, 16.0)
## 盒中心。
@export var center: Vector3 = Vector3.ZERO
## 倒角量：在 |x|+|z| 度量下四条竖棱各切掉多少（>0）。
## 45° 斜切时，它等于"沿对角方向切进去的距离 × √2"。
## 例：想沿对角切进 8 个体素 → chamfer = 8×√2 ≈ 11.3。
@export var chamfer: float = 4.0
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	var half := size * 0.5
	var q := (p - center).abs() - half
	var box_d := q.max(Vector3.ZERO).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
	# 四条竖棱的 45° 切面。chamfer ≤ 0 时平面落到盒外，本原语自动等价于普通盒。
	var plane_d := absf(p.x - center.x) + absf(p.z - center.z) - (half.x + half.z - chamfer)
	return Vector2(maxf(box_d, plane_d), float(material_id))


func bounds() -> AABB:
	return AABB(center - size * 0.5, size)
