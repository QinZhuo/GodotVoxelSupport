extends TestCase

## 程序化源最小契约：只写 generate 也能出数（VX-01/02/03 的通用回归）。

const PROBE := preload("res://Scripts/Test/fixtures/procedural_source_probe.gd")

func test_only_generate_is_enough() -> void:
	var s: QVoxelSource = PROBE.new()
	assert_true(s.is_streaming(), "程序化源应声明流式（渲染器 gate 依赖它）")
	assert_true(s.can_generate_chunk(Vector3i(0, 0, 0)), "应按 key 可造")
	assert_true(s.is_in_node_bounds(Vector3i(0, 0, 0)), "程序化源无节点边界")

func test_async_is_configured_at_construction() -> void:
	var s: QVoxelSource = PROBE.new()
	# 构造期就应把编排器指向自己；只在 node/stream setter 里 configure 的话
	assert_true(s._async._source_ref.get_ref() == s, "new() 后 _async 应已 configure(self)")
	# 不真正派发 worker：这个用例只锁构造契约，worker 生命周期另有并发测试。
