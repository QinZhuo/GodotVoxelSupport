# Test 用例运行与断言

框架只提供断言基建与运行器，用例写在项目 `Scripts/Test/` 下（`test_*.gd`，`extends TestCase`，`test_` 开头的方法自动发现）。
三种入口：编辑器进程、游戏进程、`run_headless.gd` 命令行（走退出码，可进 CI）。

| 类 | 职责 |
|---|---|
| `TestCase` | 断言 + 钩子：`needs_game_process` / `cleanup` / `max_duration_ms` |
| `TestRunner` | `run_all(script, mode, logger)`、`set_freshness_mode`、`merge_summaries`、`render_text` |
| `run_headless.gd` | `extends SceneTree` 的命令行入口，解析 `--script` / `--game` / `--freshness=` / `--allow-errors` |

| 断言 | 说明 |
|---|---|
| `assert_true(cond, msg := "")` / `assert_false` | 布尔判定 |
| `assert_eq(got, want, msg := "")` / `assert_ne` | 失败信息带 `got=` / `want=` |
| `assert_approx(got, want, msg := "")` | float/int 走 `is_equal_approx`，其它类型走 `got.is_equal_approx(want)` |
| `assert_under_ms(limit_ms, action: Callable, msg := "")` | 超限即失败 |
| `assert_fps_at_least(min_fps, frames := 120, warmup := 30, key := "")` | 采样帧率；失败信息含 1% low / p95 / 卡顿 / draw_calls |
| `measure_ms(key, action) -> float` | 只写 `PerfTool` 基线，不判失败 |

```gdscript
extends TestCase

func needs_game_process() -> bool:
	return true            # 只有 process=game 或 headless --game 才执行

func max_duration_ms() -> int:
	return 500             # 超了只记 SLOW，不算失败

func cleanup() -> void:
	pass                   # 每个 test_ 方法之后无条件调用，必须幂等

func test_framerate() -> void:
	var report := await assert_fps_at_least(60.0, 120, 30, "scene_load")
```

```bash
godot --headless --path . -s res://addons/DEVFramework/Test/run_headless.gd -- --script all
```

退出码：`0` 全通过、`1` 有失败、`2` 执行了 0 个用例。MCP `run_tests` 是这套运行器的包装：`wait_sec` 默认 5 秒，超时返回 `{job_id, running:true}`，用 `job_wait` 继续等（不会重跑）。

## 坑

1. `needs_game_process` 是"分进程"而不是"标记跳过"：`mode=editor` 不执行它，只记进 `skipped`；只有 game 模式或 headless `--game` 才真跑。
2. 硬超时只能拦住会 await 的用例（上限 `JobTool.MAX_JOB_MS`）：纯死循环会把进程冻住；单进程也不允许并发跑。
3. **引擎报错也计入失败**：区间内新出现的 error 会被去重、带 `file:line` 记进 `failures`（最多 3 条）。别顺手触发错误看行为；headless 可用 `--allow-errors` 关掉。
4. 每个 `test_` 方法之后运行器都会 `ResetTool.all()` 复位会话静态态并调 `cleanup()`：cleanup 必须幂等，用例之间不要依赖残留状态。
5. 判定从严：0 个可执行用例、用例脚本解析失败都算失败；文件名/类名错了会直接红。
6. 编辑器进程默认开新鲜度闸门（`dev_framework/test/freshness`，默认 `strict`）：磁盘脚本比编辑器缓存新时拒绝跑，`warn` 只警告，`off` 不检查；游戏进程与 headless 没有这层。用例目录写死 `res://Scripts/Test/`（递归扫 `test_*.gd`，跳过 `.` 开头目录）。
