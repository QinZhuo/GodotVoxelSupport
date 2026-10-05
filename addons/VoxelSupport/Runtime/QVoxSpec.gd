@tool
class_name QVoxSpec
extends RefCounted

## QVox 体素文件格式 —— 规范的唯一权威源（常量与基础原语）。
##
## 设计与理由见 docs/QVOX_FORMAT.md。本类只放"格式事实"，不含任何 I/O 或状态：
## 签名、块头布局、块类型、块级编解码枚举、对齐规则、CRC。
##
## 核心结构（一句话）：文件 = 8 字节签名 + 块流；块 = 长度、类型、CRC、负载。
##
## 五条设计原则（P1–P5）：
##   P1 整个文件就是一条带类型的块流，别无其他
##   P2 每条事实只存一次（不存可由他字段推导的值）
##   P3 元数据用 JSON，负载用列式二进制
##   P4 块头自足：读到块头即知"多长、是什么、校验值"
##   P5 缓存是派生的，且可证明可删除

# ----------------------------------------------------------------------------
# 版本
# ----------------------------------------------------------------------------
# HEAD 的 qvox 键必须等于此值。读者遇到更高版本应拒绝（宁可不解，不可误读）。
#
# v2（当前）：VOX0 模型头 6 → 10 字节，新增 uint32 payload_length，
#             使"模型负载的精确边界"成为头内事实（P4 贯彻到 VOX0 内部）。
#             v1 与本版不兼容，且**不提供兼容读取路径**——格式尚在设计阶段，
#             从未有实际落盘的 v1 文件，无需背负历史包袱。

const VERSION := 2

# ----------------------------------------------------------------------------
# 签名（8 字节）
# ----------------------------------------------------------------------------
# 89 51 56 4F 58 0D 0A 1A = 0x89 'Q' 'V' 'O' 'X' CR LF 0x1A
# 首尾的 0x89/0x1A 保证 7 位传输与文本模式转换都会破坏它并当场校验失败。

# 注意：GDScript 的 const 不接受 PackedByteArray([...]) 这类"构造函数调用"
# （报 "isn't a constant expression"），但接受普通 Array 字面量。
# 因此签名用 Array 存，需要字节时经 signature_bytes() 转换。

const SIGNATURE_ARRAY := [0x89, 0x51, 0x56, 0x4F, 0x58, 0x0D, 0x0A, 0x1A]
const SIGNATURE_SIZE := 8


## 签名的字节形式（PackedByteArray）。每次调用构造，开销可忽略（仅读写文件时用）。
static func signature_bytes() -> PackedByteArray:
	return PackedByteArray(SIGNATURE_ARRAY)

# ----------------------------------------------------------------------------
# 块头（12 字节，全部位于 payload 之前）
# ----------------------------------------------------------------------------
# uint32 length      本块的字节数（含尾部填充），恒为 4 的倍数
# char[4] type       4 个 ASCII 字符
# uint32 crc32       CRC32(length 字段的 4 字节 ‖ type ‖ payload 实际内容)
# byte[] payload     实际负载
# byte[] padding     0–3 字节的零，使 length 为 4 的倍数
#
# 【关键】填充计入 length。因此跳过任意块 = seek(length)，永远落在下一块头，
# 读者永远不需要知道填充有几个。

const BLOCK_HEADER_SIZE := 12
const BLOCK_ALIGN := 4

# ----------------------------------------------------------------------------
# 块类型（当前版本共五种）
# ----------------------------------------------------------------------------
# HEAD  恰好 1 个，必须第一，必需。JSON 声明文件。
# MATE  ≤ 1，材质调色板（12 字节定长条目）。
# VOX0  ≥ 0，体素数据（每个 model_id 一个）。
# NODE  ≤ 1，场景图 / 变换 / 动画（JSON）。
# CACH  任意，任何可重算的数据（可删）。

const BLOCK_HEAD := "HEAD"
const BLOCK_MATE := "MATE"
const BLOCK_VOX0 := "VOX0"
const BLOCK_NODE := "NODE"
const BLOCK_CACH := "CACH"

## 当前版本全部块类型（用于校验 / 调试）。
const KNOWN_BLOCK_TYPES := [BLOCK_HEAD, BLOCK_MATE, BLOCK_VOX0, BLOCK_NODE, BLOCK_CACH]

# ----------------------------------------------------------------------------
# 块级编解码（VOX0 内每个块一个 codec 字节）
# ----------------------------------------------------------------------------
# 值 0 被【保留】给 EMPTY：读者若在文件中读到 codec=0，应视为数据损坏。
# 保留而非剔除，是为了让"内存中的块状态"与"文件中的编解码"共用一套枚举——
# 内存里每个块都有 EMPTY 态，文件里则用"块坐标的缺失"表示它，读写两端逻辑一致。

const CODEC_EMPTY := 0    ## 保留值，永不写入文件（空块 = 块坐标缺失）
const CODEC_SOLID := 1    ## 所有通道各一个值
const CODEC_RUN := 2      ## uint32 count + count×(varint 游程长度, 每通道一个值)
const CODEC_DENSE := 3    ## 每通道 N×bpp/8 字节，ZXY 顺序，通道连续成段
const CODEC_INDEXED := 4  ## uint8 n + n 个材质索引 + N×⌈log₂n⌉ 位（只索引 channels[0]）

# ----------------------------------------------------------------------------
# 几何 / 通道约定
# ----------------------------------------------------------------------------
##
## 块尺寸 B = HEAD 的 block_size（必须是 2 的幂），块内体素数 N = B³。
## 所有编解码都沿与 DENSE 相同的顺序遍历块内体素：
##     idx = x + y·B + z·B²      （即 ZXY 外层、X 最快）
##
## 块坐标是【块索引】而非体素坐标：
##     块 (bx,by,bz) 覆盖体素区间 [bx·B, bx·B + B) × ...
##     体素 (vx,vy,vz) 所属块    (vx >> log₂B, vy >> log₂B, vz >> log₂B)
##
## 空块定义：channels[0]（即 material）在该块内全为 0。其余通道不影响判定。

const DEFAULT_BLOCK_SIZE := 32
const DEFAULT_UP_AXIS := "y"

## up_axis 白名单（§3.1）。缺省 y；出现其他值按缺省处理并告警。
const ALLOWED_UP_AXES := ["x", "y", "z"]

## 每通道支持的位宽（当前仅定长数值通道）。
const ALLOWED_BPP := [8, 16, 32]

## 支配通道名（channels[0] 必须为此，决定空块判定与可见性）。
const DOMINANT_CHANNEL := "material"

## 当前版本支持的通道数：**恰好 1 个**（dominant = material）。
##
## 【为什么收敛为单通道】规范原设计允许 `channels` 列多个定长通道（如附加 sdf），
## 但编解码层只按单通道 material 实现 —— 于是"多通道文件"会被**接受却读错**
## （RUN 逐游程交错 (len, material, sdf)，只读 material 会从第二段起错位）。
## 同域参照 MagicaVoxel .vox 也只有单一体素通道，附加数据一律走独立块类型
## （P1：新功能 = 新块类型）。故本版把契约收敛为"恰好 1 个通道"：读方遇到 >1
## 直接拒绝（FATAL，fail-fast），不再静默误读。将来确需多通道时，作为新的
## qvox 版本引入"逐通道布局描述"（类似 KTX2 的 DFD），而不是现在就背这个成本。
const SUPPORTED_CHANNEL_COUNT := 1

## 支配通道每体素位宽与字节数（bpp=16 → 2 字节）。
## 编解码层里所有"每通道一个值"的宽度都引用此常量，消除散落的魔法数 2。
const CHANNEL_BPP := 16
const CHANNEL_BYTES := CHANNEL_BPP / 8

# ----------------------------------------------------------------------------
# MATE 材质条目（12 字节定长 → index × 12 随机访问）
# ----------------------------------------------------------------------------
# uint32 rgba          R<<24 | G<<16 | B<<8 | A
# uint8  metal         0–255
# uint8  rough         0–255
# uint8  hardness      0–255   物理：抗破坏性 / 连接强度
# uint8  mass          0–255   物理：密度 / 崩塌质量
# uint8  e_r           0–255   自发光 R
# uint8  e_g           0–255   自发光 G
# uint8  e_b           0–255   自发光 B
# uint8  reserved      必须为 0
#
# 条目 0 保留且全零（空气）。因此 体素值 == 材质索引 无条件成立。

const MATE_ENTRY_SIZE := 12

# ----------------------------------------------------------------------------
# VOX0 模型头（10 字节，刻意不 4 对齐）
# ----------------------------------------------------------------------------
# uint16  model_id          模型编号，供 NODE 的 kind="model" 节点引用
# uint32  block_count       本模型包含的块数（只计非空块）
# uint32  payload_length    block[] 的实际字节数（不含任何填充）
# byte[]  payload           payload_length 个字节的块数组
#
# 【为什么必须有 payload_length】（P4「长度前置」贯彻到 VOX0 内部）
# 顶层块用 length 让读者无需理解内容即可跳过；VOX0 内部同理——block_count 只说明
# "有几块"，但每块的长度虽有、**模型总长却没有**。缺了它，读取端切出的 payload 必然
# 含顶层块的 0–3 字节尾部填充，于是"解析到哪里才算正好用完"变成模糊判断：
# 只能退化为"剩余 < 4 字节就算合法"，留下 1–3 字节的篡改灰区（曾是一处语义漏洞）。
# 显式存 payload_length 后，判定退化成一次等式比较：pos == 10 + payload_length。
# 代价恒定 4 字节/模型（一个文件通常 1–3 个模型，总计 < 12 字节），换来零灰区。

const VOX_MODEL_HEADER_SIZE := 10

# ----------------------------------------------------------------------------
# VOX0 块内块头（17 字节，刻意不 4 对齐）
# ----------------------------------------------------------------------------
# int32   bx, by, bz        块坐标（块索引，非体素坐标）
# uint8   codec             块级编解码
# uint32  payload_length    负载字节数（不含尾部填充）
# byte[]  payload
#
# 块内不做对齐填充：只有顶层块才有 4 字节对齐与填充。17 字节不是疏漏——
# codec 只有 1 字节，为凑对齐补 3 字节等于每块白付 3 字节，违背 P2。

const VOX_BLOCK_HEADER_SIZE := 17

# ----------------------------------------------------------------------------
# 对齐辅助
# ----------------------------------------------------------------------------

## 向上取整到 4 字节边界（写入方用：算 length 与填充量）。
static func align4(n: int) -> int:
	return (n + BLOCK_ALIGN - 1) & ~(BLOCK_ALIGN - 1)


## 给定实际负载字节数，返回该块的 length（含填充）。
static func padded_length(payload_bytes: int) -> int:
	return align4(payload_bytes)


# ----------------------------------------------------------------------------
# 长度派生（纯算术，无状态）—— 格式的"算术"集中在此，可单测、可复查
# ----------------------------------------------------------------------------
# 【设计意图】P2 说"不存可推导的事实"，但**推导关系本身应当显式化**。
# 把"某段字节该多长""总长该是多少"这类计算集中为纯函数，好处有三：
#   1. 读写两端调用同一个函数 → 不可能不一致（§1.2 CRC 那个历史 bug 的同族问题）；
#   2. 可脱离文件独立单测（给定输入断言输出）；
#   3. 校验逻辑从"内联四则运算"变成"调用一个具名函数"，读代码即知意图。


## 一个顶层块占用的总字节数（块头 12 + length）。
static func block_total_bytes(length: int) -> int:
	return BLOCK_HEADER_SIZE + length


## VOX0 模型负载的精确字节数：block[] 数组本身。
## 仅用于文档说明；实际以存储在模型头里的 payload_length 为准。
static func vox0_payload_end(model_payload_bytes: int) -> int:
	return VOX_MODEL_HEADER_SIZE + model_payload_bytes


## 一个 VOX0 块内子块的字节数（17 字节头 + 负载）。
static func vox_block_total_bytes(block_payload_bytes: int) -> int:
	return VOX_BLOCK_HEADER_SIZE + block_payload_bytes


## MATE 负载字节数（2 字节 entry_count + entry_count × 12）。
static func mate_payload_bytes(entry_count: int) -> int:
	return 2 + entry_count * MATE_ENTRY_SIZE


## 顶层块负载的实际内容长度（去掉尾部零填充）。
## 写入端补的填充恒为 0–3 个零字节；本函数把它剥掉，得到"内容"长度。
## 注意：仅适用于"内容不含合法尾部零"的负载（HEAD/NODE 的 JSON、MATE 的定长条目）。
## VOX0 的尾随可能含合法零，故它**不**用本函数——这正是 payload_length 存在的原因。
static func content_length(payload: PackedByteArray) -> int:
	var end := payload.size()
	while end > 0 and payload[end - 1] == 0:
		end -= 1
	return end


# ----------------------------------------------------------------------------
# 整数编解码（小端）—— QVoxSpec 只做"约定"，实际读写在 QVoxFile
# ----------------------------------------------------------------------------

## 有符号 int32 → 无符号位模式（GDScript 的 int 是 64 位，写 32 位需掩码）。
static func to_u32(v: int) -> int:
	return v & 0xFFFFFFFF


## 无符号位模式 → 有符号 int32（块坐标可为负）。
static func from_u32(v: int) -> int:
	v &= 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v


# ----------------------------------------------------------------------------
# 校验
# ----------------------------------------------------------------------------

## 该块类型是否为当前版本已知类型。
static func is_known_block_type(t: String) -> bool:
	return t in KNOWN_BLOCK_TYPES


## 读者在 HEAD.require 校验里"能处理"的块类型（§10）。
##
## 语义 = "能产出正确结果"，而非"名字见过"：五种内建类型都算能处理，
## 其中 CACH 本就允许被忽略（忽略它即为正确处理，P5），故同样算"能处理"。
## require 里出现此外的任何类型 → 必须拒绝整个文件（而非静默跳过）。
static func can_handle_block_type(t: String) -> bool:
	return t in KNOWN_BLOCK_TYPES


## 该 bpp 是否为当前版本允许的位宽。
static func is_allowed_bpp(bpp: int) -> bool:
	return bpp in ALLOWED_BPP
