@tool
## 世代 —— 一段逻辑「第几轮运行」的身份，供跨 await 的检查点判定自己是否已被新一代顶掉。
## 等别人的协程（网络请求、`load_data`）回来时，唯一可行的作废方式是对比世代；
## 用途边界：只表达**进程内**的先后（单调递增），不能用来比较跨版本 / 跨设备的新旧 ——
class_name Generation extends RefCounted


## 换代时发射，携带新世代（旧世代的快照随之作废）
signal advanced(gen: int)

var _gen := 0


## 换代：作废此前取出的所有快照，返回新世代
func next() -> int:
	_gen += 1
	advanced.emit(_gen)
	return _gen


## 取当前世代快照，配合 [method is_current] / [method is_stale] 使用
func snapshot() -> int:
	return _gen


## 该快照是否仍属于当前这一代
func is_current(gen: int) -> bool:
	return gen == _gen


## 该快照是否已被新一代顶掉（检查点的常用写法）
func is_stale(gen: int) -> bool:
	return gen != _gen
