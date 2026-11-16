class_name TimerComponent
extends ECSComponent

## ECS 原生计时器 —— 冷却 / DoT tick / 延迟触发 / 无敌帧。
##
## 设计: **一个计时器一个实体**(不是每对象一个 Array[GameTimer])。
##   · 一个宿主可以挂任意多个计时器(target 指回宿主);
##   · 推进是"所有计时器一起减 delta"的一次原生列操作, 不逐对象轮询;
##   · 到期只对**到期的那几个**做处理(发事件/重置/销毁), 与总数无关。
##
## 用法:
##   var t := TimerSystem.add(world, actor, 1.5, {"tag": MyTags.COOLDOWN})
##   TimerSystem.tick(world, delta)             # 每帧一次(或挂到调度器)
##   world.on_event(&"timer_expired", cb)       # 或 take_events 取走
##
## 实测(2000 个计时器, 每帧推进, 无到期): 旧逐对象 OOP 计时器约 0.4~0.66ms → 本实现 0.061ms。
## (那个逐对象实现已迁出框架、由需要严格发射顺序的项目自持; 框架只保留这一套。)

## 重复语义。**这是模块自己拥有的封闭集合**, 所以用 enum(而不是 repeat_count 的 -1 魔法值)。
## 枚举在 ECS 里就是 int 列(见 register_component 的反射), 没有额外开销。
enum RepeatMode {
	ONCE = 0,      ## 到期即销毁(冷却/延迟触发)
	REPEAT = 1,    ## 循环 repeat_count 次后销毁
	FOREVER = 2,   ## 永不销毁(DoT tick/脉冲)
}

## 剩余秒数(<= 0 视为到期; 到期处理在同帧内完成, 不会留下负值给下一帧)
@export var left: float = 0.0
## 总时长(进度条/UI 用; 循环时用它把 left 重新装满)
@export var duration: float = 1.0
## 重复语义(见 RepeatMode)
@export var repeat_mode: RepeatMode = RepeatMode.ONCE
## 仅在 REPEAT 下有效: 还能循环几次(每到期一次减 1, 减到 0 后销毁)
@export var repeat_count: int = 0
## **业务分组**, 由使用方自定义(冷却=0 / DoT=1 / 延迟=2 ...), 到期事件原样带出。
##
## 这里刻意用 int 而不是枚举: tag 是**开放集合**(每个项目有自己的分类), 若在框架里定 enum,
## 项目每加一种计时器就得改框架源码 —— 那是策略, 不是机制。
## 项目侧直接传自己的枚举即可(enum 在 Variant 层就是 int):
##   enum MyTimer { COOLDOWN, DOT }
##   TimerSystem.add(world, actor, 1.0, {"tag": MyTimer.DOT})
@export var tag: int = 0
## 宿主实体 id(0 = 无宿主/全局计时器); timers_of() 按它过滤
@export var target: int = 0
