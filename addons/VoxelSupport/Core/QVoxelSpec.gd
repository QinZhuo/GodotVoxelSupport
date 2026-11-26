@tool
class_name QVoxelSpec
extends RefCounted

## QVX 体素文件格式 —— 规范的唯一权威源（常量与基础原语）。

# 版本

const VERSION := 4

## 文件扩展名（不带点，与 `String.get_extension()` 的返回形态一致）。
const FILE_EXT := "qvx"

# 签名（8 字节）

# 注意：GDScript 的 const 不接受 PackedByteArray([...]) 这类"构造函数调用"

const SIGNATURE_ARRAY := [0x89, 0x51, 0x56, 0x4F, 0x58, 0x0D, 0x0A, 0x1A]
const SIGNATURE_SIZE := 8

## 签名的字节形式（PackedByteArray）。
static func signature_bytes() -> PackedByteArray:
	return PackedByteArray(SIGNATURE_ARRAY)

# 块头（12 字节，全部位于 payload 之前）

const BLOCK_HEADER_SIZE := 12
const BLOCK_ALIGN := 4

# 块类型（当前版本共七种）

const BLOCK_HEAD := "HEAD"
const BLOCK_MATE := "MATE"
const BLOCK_VXEL := "VXEL"
const BLOCK_ANIM := "ANIM"
const BLOCK_NODE := "NODE"
const BLOCK_CAMR := "CAMR"
const BLOCK_CACH := "CACH"

## 当前版本全部块类型（用于校验 / 调试）。
const KNOWN_BLOCK_TYPES := [BLOCK_HEAD, BLOCK_MATE, BLOCK_VXEL, BLOCK_ANIM, BLOCK_NODE, BLOCK_CAMR, BLOCK_CACH]

# CACH 负载的定长前置（8 字节）

const CACH_PREFIX_SIZE := 8

# 块级编解码（VXEL 内每个块一个 codec 字节）

const CODEC_EMPTY := 0    ## 保留值，永不写入文件（空块 = 块坐标缺失）
const CODEC_SOLID := 1    ## 所有通道各一个值
const CODEC_RUN := 2      ## uint32 count + count×(varint 游程长度, 每通道一个值)
const CODEC_DENSE := 3    ## 每通道 N×bpp/8 字节，ZXY 顺序，通道连续成段
const CODEC_INDEXED := 4  ## uint8 n + n 个材质索引 + N×⌈log₂n⌉ 位（只索引 channels[0]）

# 几何 / 通道约定

const DEFAULT_BLOCK_SIZE := 32
const DEFAULT_UP_AXIS := "y"

## up_axis 白名单（§3.1）。
const ALLOWED_UP_AXES := ["x", "y", "z"]

## 【位宽契约】本版**只支持 CHANNEL_BPP（= 16 位）**，见下方同名常量。

## 通道名（决定空块判定与可见性）。
const DOMINANT_CHANNEL := "material"

## HEAD 的单通道键名（v4）。
const HEAD_CHANNEL_KEY := "channel"
const HEAD_BPP_KEY := "bpp"

## HEAD 的其余两个键名：block_size 与 bounds。
const HEAD_BLOCK_SIZE_KEY := "block_size"
const HEAD_BOUNDS_KEY := "bounds"
## 向上轴键名。
const HEAD_UP_AXIS_KEY := "up_axis"

## 支配通道每体素位宽与字节数（bpp=16 → 2 字节）。
const CHANNEL_BPP := 16
const CHANNEL_BYTES := CHANNEL_BPP / 8

# 块坐标 ↔ 体素坐标（布局的唯一实现）

## 体素坐标 → 所属块坐标。
static func block_of(voxel: Vector3i, block_size: int) -> Vector3i:
	return Vector3i(
			floori(float(voxel.x) / block_size),
			floori(float(voxel.y) / block_size),
			floori(float(voxel.z) / block_size))

## 块坐标 → 该块的体素原点（= 块坐标 × 块边长）。
static func block_origin(block_key: Vector3i, block_size: int) -> Vector3i:
	return block_key * block_size

## 块内局部坐标（0..block_size-1）→ 块内线性下标（ZXY：X 最快）。
static func local_index(x: int, y: int, z: int, block_size: int) -> int:
	return x + y * block_size + z * block_size * block_size

## 块内元素总数 N = B³。
static func block_volume(block_size: int) -> int:
	return block_size * block_size * block_size

## 体素坐标 → 块内线性下标（等价于 block_of + local_index，供单点存取少一次取模）。
static func index_in_block(voxel: Vector3i, block_size: int) -> int:
	var b := block_of(voxel, block_size)
	var o := block_origin(b, block_size)
	return local_index(voxel.x - o.x, voxel.y - o.y, voxel.z - o.z, block_size)

# MATE 材质条目（12 字节定长 → index × 12 随机访问）

const MATE_ENTRY_SIZE := 12

# 材质表容量（索引即材质 ID，0 恒为空气）。
const MATERIAL_COUNT := 256

# VXEL 模型头（10 字节，刻意不 4 对齐）

const VXEL_MODEL_HEADER_SIZE := 10

# VXEL 块内块头（17 字节，刻意不 4 对齐）

const VOX_BLOCK_HEADER_SIZE := 17

# ANIM 帧动画（设计见 docs/QVX_FORMAT.md §12）。
const ANIM_MODEL_HEADER_SIZE := 8
const ANIM_FRAME_HEADER_SIZE := 6

## 动画时序的两个缺省值 —— **全仓唯一真值**。
const ANIM_FPS_DEFAULT := 4
const ANIM_LOOP_DEFAULT := true

## ANIM 每帧条目里逐帧时长的键名（帧 = {"duration_ms": int, "blocks": Dictionary}）。
const ANIM_FRAME_DURATION_KEY := "duration_ms"

# NODE 块的图层与相机（§7）

## 工程数据的两个数组键名。
const NODE_NODES_KEY := "nodes"
const NODE_CAMERAS_KEY := "cameras"

## 节点条的 `kind` 白名单（§7）。
const NODE_KIND_GROUP := "group"
const NODE_KIND_MODEL := "model"

## `cameras` 每项的键与缺省值。
const CAMERA_FIELD_DEFAULTS := {
	"name": "camera",
	"projection": "persp",
	"transform": {},
}

## `projection` 白名单。
const ALLOWED_CAMERA_PROJECTIONS := ["persp", "ortho"]

# 对齐辅助

## 向上取整到 4 字节边界（写入方用：算 length 与填充量）。
static func align4(n: int) -> int:
	return (n + BLOCK_ALIGN - 1) & ~(BLOCK_ALIGN - 1)

## 给定实际负载字节数，返回该块的 length（含填充）。
static func padded_length(payload_bytes: int) -> int:
	return align4(payload_bytes)

# 整数编解码（小端）—— QVoxelSpec 只做"约定"，实际读写在 QVoxelFile

## 有符号 int32 → 无符号位模式（GDScript 的 int 是 64 位，写 32 位需掩码）。
static func to_u32(v: int) -> int:
	return v & 0xFFFFFFFF

## 无符号位模式 → 有符号 int32（块坐标可为负）。
static func from_u32(v: int) -> int:
	v &= 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v

# 校验

## 读者在 HEAD.require 校验里"能处理"的块类型（§10）。
static func can_handle_block_type(t: String) -> bool:
	return t in KNOWN_BLOCK_TYPES

## 该 bpp 是否为当前版本支持的位宽（唯一真值：CHANNEL_BPP）。
static func is_allowed_bpp(bpp: int) -> bool:
	return bpp == CHANNEL_BPP

## HEAD 的"能力门"判据：本读者能否正确处理这份文件。
static func capability_error(head: Dictionary) -> String:
	# require 里出现本读者处理不了的块类型 → 必须拒绝整个文件（而非静默跳过，§10）。
	var req: Variant = head.get("require")
	if req is Array:
		for t in (req as Array):
			var ts := str(t)
			if ts != "" and not can_handle_block_type(ts):
				return "HEAD.require 含本读者无法处理的块类型 '%s'（§10：拒绝整个文件）" % ts
	var channel := str(head.get(HEAD_CHANNEL_KEY, ""))
	if channel != DOMINANT_CHANNEL:
		return "HEAD.%s='%s' 不受支持（本版仅 '%s'）" % [HEAD_CHANNEL_KEY, channel, DOMINANT_CHANNEL]
	var bpp := int(head.get(HEAD_BPP_KEY, 0))
	if not is_allowed_bpp(bpp):
		return "HEAD.%s=%d 不受支持（本版仅 %d 位）" % [HEAD_BPP_KEY, bpp, CHANNEL_BPP]
	return ""
