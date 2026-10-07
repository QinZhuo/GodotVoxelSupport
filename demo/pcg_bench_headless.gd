extends SceneTree

## 无头基准运行器：直接跑 PCG 造/存流水线基准并退出，不依赖编辑器 / 游戏窗口。
## 用法：
##   godot --headless --path <项目> --script res://demo/pcg_bench_headless.gd
##
## 基准本体在 demo/pcg_bench.gd（class_name PcgModelBench）。这里只负责在无头
## SceneTree 里触发它 —— 实现只有一份，避免两处各自抄一遍后慢慢漂移。
##
## 用 preload 而不是全局类名：全局类表由编辑器维护（`.godot/global_script_class_cache.cfg`），
## 新建的 class_name 在编辑器重扫前拿不到；preload 按路径解析，无头进程里必然可用。
##
## 【退出码非 0 是已知现象，不影响结果】本脚本跑完会以 access violation（退出码
## -1073741819 / 0xC0000005）结束。原因不在基准本身，而是引擎退出顺序问题：
## VoxelAsyncLoader 用「发射后不管」的 WorkerThreadPool.add_task 派发任务、从不
## wait_for_task_completion 回收，于是引擎停机时线程池里仍留着引用 GDScript 对象的
## Callable，而这些 Callable 在线程池析构时才被销毁 —— 此时 GDScript 虚拟机已关闭。
## 对照实验（去掉基准、只留派发方式）：
##   add_task(内置方法 bind)          → exit 0
##   add_task(GDScript lambda) 未回收  → 崩溃
##   add_task(GDScript lambda) 已回收  → exit 0
## 该现象与体素 / PCG 逻辑无关，普通游戏退出（非本脚本）同样会触发。
## 所有 [BENCH] 行都在崩溃前输出完毕，结果可信。

const Bench := preload("res://demo/pcg_bench.gd")


func _initialize() -> void:
	Bench.run()
	quit()