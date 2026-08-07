@tool
@abstract
##信号
class_name SignalDef extends Def

@abstract
func connect_signal(data, callable: Callable)

@abstract
func disconnect_signal(data, callable: Callable)

func get_csv_path() -> String:
	return "res://Assets/Translation/signal.csv"
