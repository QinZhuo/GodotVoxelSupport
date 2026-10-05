@tool
## MCP 内置 HTTP 服务器 — 基于 TCPServer 的最小 HTTP/1.1 实现
## 仅服务于本机 MCP 调试(MCP Streamable HTTP 传输): 一般请求响应完即关闭连接。
## 唯一例外是 GET 打开的 SSE 流 —— 它**必须**保持长连接, 客户端重连后靠它判定通道存活。
class_name MCPTcpHttpServer extends RefCounted

## 完成一个完整 HTTP 请求时触发
## [param method] 请求方法(GET/POST/...)
## [param path] 请求路径(不含 query)
## [param query] 请求路径上的 query 串(不含前导 "?", 无则空串)。旧式 HTTP+SSE 传输把
##               sessionId 放在 query 上, 故必须原样交给处理器, 否则认不出 POST 属于哪条 SSE 流
## [param headers] 请求头(小写 key)
## [param body] 请求体字节
## [param stream] 对应连接的 StreamPeerTCP, 用 send_response(stream,...) 回写
## 处理器需调用 send_response() 发送结果; 若未调用则无响应(超时由客户端兜底)
signal request_received(method: String, path: String, query: String, headers: Dictionary, body: PackedByteArray, stream: StreamPeerTCP)

var _server: TCPServer
var _conns: Array = []          # 进行中的连接(字典数组)
## 旧式 HTTP+SSE 传输的 sessionId → 该会话的 SSE 连接 socket。
## 规范(Transports §Backwards Compatibility)要求同时提供新旧两个端点, 旧式客户端在
## GET 拿到 endpoint 事件后会改用 POST 投递请求, 而**响应必须回写到它开的那条 SSE 流上**
## (POST 本身只回 202)。缺了这张表, 旧式客户端会一直等在"连接中"。
var _sse_sessions := {}
## 每条 SSE 流是否已经有请求落到它上面(sid -> bool)。
## 旧式传输里客户端 GET 拿到 endpoint 事件后**必须**立刻用该 sessionId POST initialize
## —— 那正是这条流的唯一用途。所以"开了流却迟迟没有任何请求落到它上面"就等于废弃流:
## 实测有客户端只把 SSE 当保活长连接, 把全部请求都发在别的连接上(sessionId 恒为空)。
## 不回收的话, 客户端每次重连都白占一条 socket, 很快撞满 MAX_SSE_CONNS, 之后新连接
## 开不出 SSE 流, 客户端就彻底连不上了(这比"多占几个 socket"严重得多)。
var _sse_used := {}
var _sse_seq := 0                ## 旧式 SSE 会话 id 的自增计数(仅用于让 id 互不相同)
const MAX_BODY_SIZE := 16 * 1024 * 1024   # 16MB 上限
const SSE_KEEPALIVE_MS := 15000            # SSE 注释帧保活间隔
const SSE_MAX_LIFETIME_MS := 1800000       # SSE 流最长存活(30 分钟)后主动关闭, 作为连接泄漏的兜底
const SSE_HANDSHAKE_MS := 10000            ## 开了 SSE 流却一直没请求落上来时的回收时限
## 诊断开关: 把客户端发来的原始字节写进 MCP 日志。
## 做成 static var 而非 const, 是为了能在不重启编辑器、不惊动客户端连接的前提下
## 通过 set_wire_trace() 现场开关 —— 排查"字节里混进了什么"这类问题时, 改 const 得
## 连带重启 MCP 服务器, 而那会顺带把客户端的 SSE 连接踢掉, 客户端重连的噪声反而淹没现象。
##
## 当前为 false: 上一轮排查已用它定位到根因(是本文件之外的 json_safe 里 String.chr(0) 造的
## 纯噪音, 客户端字节一直是干净的), 故关闭。
## 开关保留: 下次怀疑"客户端发了坏字节"时, 现场 set_wire_trace(true) 即可, 不必改代码
## 重启服务器(那会顺带踢掉客户端 SSE 连接, 重连噪声反而淹没现象)。
static var TRACE_WIRE := false
const MAX_SSE_CONNS := 4                   ## SSE 流并发上限: 客户端重连时旧流不会立刻消失, 不设上限会无界堆积
##
## 普通(非 SSE)连接的两个护栏。它们防的不是攻击 —— 服务只监听 127.0.0.1, 威胁模型是
## "客户端异常而非恶意": 探针扫端口、客户端崩在握手中、发了 Expect: 100-continue 的头
## 就消失。缺了护栏这类连接会**永久**留在 _conns 里 —— 既没读完 body 也没有新数据, 于是
## poll 里每一个既有回收条件(状态异常 / _overload)都不成立, 而 _conns 只在断开时才缩短。
## 即"发一个头部就消失"就能让连接数组单调增长, 每条还各带一个 16MB 上限的缓冲额度。
const MAX_IDLE_CONNS := 64                ## 普通连接并发上限(正常客户端一次只占一条短连接)
const IDLE_TIMEOUT_MS := 30000            ## 普通连接空闲多久后回收(远大于任何一次正常往返)


## 打开/关闭原始字节追踪。诊断完记得关掉, 它会把每个字节都写进日志。
func set_wire_trace(enabled: bool) -> void:
	TRACE_WIRE = enabled
	LogTool.log("MCP", "原始字节追踪: %s" % ("开启" if enabled else "关闭"))


func listen(port: int, bind_address: String = "127.0.0.1") -> Error:
	_server = TCPServer.new()
	var err := _server.listen(port, bind_address)
	if err != OK:
		_server = null
		return err
	return OK


func stop() -> void:
	if _server:
		_server.stop()
		_server = null
	for c in _conns:
		var stream: StreamPeerTCP = c.stream
		if stream:
			stream.disconnect_from_host()
	_conns.clear()


func is_listening() -> bool:
	return _server != null and _server.is_listening()


func get_port() -> int:
	return _server.get_local_port() if _server else 0


## 主循环轮询(每帧调用)
func poll() -> void:
	if _server == null:
		return
	var now := Time.get_ticks_msec()
	while _server.is_connection_available():
		var stream: StreamPeerTCP = _server.take_connection()
		_conns.append({"stream": stream, "buffer": PackedByteArray(), "headers_done": false, "content_length": -1, "_sse": false, "_sse_tick": 0, "_sse_sent": 0, "_sse_session": "", "_touched": now})
		# 顶到上限直接拒接。正常客户端一次只占一条短连接, 能堆到 64 说明几乎全是
		# 没读完的残连接。不发响应 —— 对端多半已经不在了, 发了只会在日志里堆垃圾。
		if _conns.size() > MAX_IDLE_CONNS:
			LogTool.log("MCP", "连接数超上限 %d, 拒绝新连接(残留未收完的请求?)" % MAX_IDLE_CONNS)
			stream.disconnect_from_host()
			_conns.pop_back()
			continue
		if TRACE_WIRE:
			LogTool.log("MCP", "[wire] 新连接接入, 连接数=%d" % _conns.size())

	# 脚本热重载不跑初始化代码, 实例成员变量会被重置成默认值, 这两个表就成了 null,
	# 之后任何一次 SSE 请求都会在它们身上崩掉。在入口兜一次, 代价可以忽略。
	if _sse_sessions == null:
		_sse_sessions = {}
	if _sse_used == null:
		_sse_used = {}
	var finished := []
	for i in _conns.size():
		var c = _conns[i]
		var stream: StreamPeerTCP = c.stream
		stream.poll()
		var status := stream.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED or status == StreamPeerTCP.STATUS_CONNECTING:
			if c.get("_sse", false):
				# SSE 流只维持存活, 不再解析请求: 客户端不会在一条已开流的连接上再发请求,
				# 若继续解析, 第二个响应会被写进 SSE 流里变成垃圾数据。
				if _poll_sse(c, now):
					finished.append(i)
			else:
				_read_available(c)
				_process_buffer(c, finished, i)
		elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE or c.get("_overload", false) or _is_idle_expired(c, now):
			# 已断开(响应完成后 disconnect 会进入 STATUS_NONE)、超限、或空闲超时的连接
			# 一律回收, 避免 _conns 无限增长造成内存泄漏。
			# SSE 走不到这条分支 —— 上面已被 if c.get("_sse") 拦走, 故无须在此排除:
			# SSE 静默期是正常的(靠 _poll_sse 保活), 用空闲超时收它等于几秒就断流。
			finished.append(i)
	finished.sort()
	finished.reverse()
	for i in finished:
		var c = _conns[i]
		var stream: StreamPeerTCP = c.get("stream")
		# 连接一断, 它承载的 SSE 会话就不再有效: 必须立刻注销, 否则后续带着这个
		# sessionId 的 POST 会被投递给一条死流, 静默丢失响应(客户端表现为连上但工具全超时)
		var sid: String = c.get("_sse_session", "")
		if not sid.is_empty() and _sse_sessions.get(sid, null) == stream:
			_sse_sessions.erase(sid)
			_sse_used.erase(sid)
		if stream:
			stream.disconnect_from_host()
		_conns.remove_at(i)


## 普通连接是否已空闲超时。
##
## 判据是"距上一次真正收到字节过了多久", 而非"连接存在了多久" —— 一个正在连续收发
## 请求的长连接不该因为建得早就被收走。_touched 由 _read_available 在真收到数据时刷新,
## 所以"只发头部就消失"的残连接会在 IDLE_TIMEOUT_MS 后被回收, 而正常 keep-alive 连接
## 只要还在说话就永远不会被误杀。
##
## SSE 永不判定超时: 它本就允许长时间静默, 保活是 _poll_sse 的职责。
func _is_idle_expired(c: Dictionary, now: int) -> bool:
	if c.get("_sse", false):
		return false
	return now - int(c.get("_touched", now)) > IDLE_TIMEOUT_MS


## 把原始字节转成可安全写日志的文本: 控制字符与全部非 ASCII 一律转义。
## 诊断用 —— 目的是让"字节里混进了 NUL / 二进制"这类问题在日志里一眼可见,
## 而不是等到 get_string_from_utf8() 报 "Unexpected NUL character" 才发现。
static func _trace_bytes(data: PackedByteArray, limit: int = 320) -> String:
	var out := "len=%d [" % data.size()
	for i in mini(data.size(), limit):
		var b := data[i]
		if b == 13:
			out += "\\r"
		elif b == 10:
			out += "\\n"
		elif b == 9:
			out += "\\t"
		elif b >= 32 and b < 127:
			out += char(b)
		else:
			out += "<%02X>" % b
	if data.size() > limit:
		out += "..."
	return out + "]"


func _read_available(c: Dictionary) -> void:
	var stream: StreamPeerTCP = c.stream
	var available := stream.get_available_bytes()
	while available > 0:
		var chunk := stream.get_data(available)
		if chunk[0] != OK:
			break
		var data: PackedByteArray = chunk[1]
		# 只有真收到字节才算活跃。**不能**在 poll 里无条件刷新时间戳 —— 那样一个
		# "发了头部就消失"的客户端(探针扫端口、或 Expect: 100-continue 半途放弃)
		# 永远等不到超时, 反而把最该被回收的那类连接永久留下。
		c["_touched"] = Time.get_ticks_msec()
		if TRACE_WIRE and not c.get("_traced", false):
			c["_traced"] = true
			LogTool.log("MCP", "[wire] 收到 %d 字节: %s" % [available, _trace_bytes(data)])
		c.buffer = c.buffer + data
		if c.buffer.size() > MAX_BODY_SIZE:
			_send_simple(c.stream, 413, {}, "Body Too Large")
			c._overload = true
			break
		available = stream.get_available_bytes()


func _process_buffer(c: Dictionary, finished: Array, conn_index: int) -> void:
	if c.get("_overload", false) or c.get("_drop", false):
		return
	var buf: PackedByteArray = c.buffer
	if not c.headers_done:
		var header_end := _find_bytes(buf, "\r\n\r\n")
		if header_end == -1:
			return
		if TRACE_WIRE and not c.get("_traced_head", false):
			c["_traced_head"] = true
			# 赶在 get_string_from_utf8() 之前记录原始字节: 那一步一旦遇到 NUL 只会报
			# "Unexpected NUL character", 不看原始字节无从判断混进来的是什么。
			LogTool.log("MCP", "[wire] 请求头原始字节: %s" % _trace_bytes(buf.slice(0, header_end)))
		var head_bytes := buf.slice(0, header_end).get_string_from_utf8()
		var body_start := header_end + 4
		var parsed := _parse_head(head_bytes)
		if parsed.is_empty():
			_send_simple(c.stream, 400, {}, "Bad Request")
			finished.append(conn_index)
			c._drop = true
			return
		c.method = parsed.method
		c.path = parsed.path
		c.query = parsed.query
		c.headers = parsed.headers
		var cl: int = parsed.headers.get("content-length", "-1").to_int()
		# 无 body 的请求(GET/OPTIONS/HEAD/DELETE)通常不带 Content-Length, 按 0 处理
		if cl < 0 and (c.method == "OPTIONS" or c.method == "GET" or c.method == "HEAD" or c.method == "DELETE"):
			cl = 0
		c.content_length = cl
		c.headers_done = true
		c._body_start = body_start
		# 每条新请求都要能再发一次 100 Continue, 故在这里清标志(连接是 keep-alive 的,
		# 同一条连接会承载多个请求)。见下面发 100 的分支。
		c["_sent_continue"] = false
		if c.content_length < 0 or c.content_length > MAX_BODY_SIZE:
			_send_simple(c.stream, 411, {}, "Length Required")
			c._drop = true
			finished.append(conn_index)
			return
	# headers 已解析, 收集 body
	var body_start: int = c.get("_body_start", 0)
	var needed: int = c.content_length
	# Expect: 100-continue(RFC 9110 §10.1.1): 客户端发完头部后会**主动停下**等 100
	# Continue, 收到后才发 body。我们不回, 它就空等到超时才把 body 发过来 ——
	# wire 追踪实测(CodeBuddy 4.12): 761339 收到 203 字节头部, 761745 才继续, 白等 406ms。
	# 这正是日志里那个 +706ms 的一部分, 且每个 POST 都白等一次。
	# 注意只在 body 确实没到齐时回, 且每条请求只回一次: 重复 100 会被严格客户端判为非法。
	if buf.size() - body_start < needed and not c.get("_sent_continue", false):
		if str(c.headers.get("expect", "")).to_lower() == "100-continue":
			c["_sent_continue"] = true
			c.stream.put_data("HTTP/1.1 100 Continue\r\n\r\n".to_utf8_buffer())
	if buf.size() - body_start >= needed:
		var body := buf.slice(body_start, body_start + needed)
		c.buffer = buf.slice(body_start + needed)
		c.headers_done = false
		c.content_length = -1
		c._body_start = 0
		var headers: Dictionary = c.headers.duplicate()
		var stream: StreamPeerTCP = c.stream
		request_received.emit(c.method, c.path, c.query, headers, body, stream)
		# 未处理的请求由 send_response 挂起; 无响应则交给主控


func _find_bytes(buf: PackedByteArray, token: String) -> int:
	var needle := token.to_utf8_buffer()
	if buf.size() < needle.size():
		return -1
	for i in range(buf.size() - needle.size() + 1):
		var found := true
		for j in needle.size():
			if buf[i + j] != needle[j]:
				found = false
				break
		if found:
			return i
	return -1


func _parse_head(head: String) -> Dictionary:
	var lines := head.split("\r\n")
	if lines.is_empty():
		return {}
	var parts := lines[0].split(" ")
	if parts.size() < 3:
		return {}
	var method := parts[0].to_upper()
	var raw_path := parts[1]
	# query 必须单独拆出来: 旧式 SSE 传输把 sessionId 放在 "?sessionId=..." 上
	var seg := raw_path.split("?", true, 1)
	var path := seg[0]
	var query: String = seg[1] if seg.size() > 1 else ""
	var headers := {}
	for i in range(1, lines.size()):
		var line := lines[i]
		if line.is_empty():
			continue
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		var val := line.substr(colon + 1).strip_edges()
		headers[key] = val
	return {"method": method, "path": path, "query": query, "headers": headers}


## 向指定连接发送 HTTP 响应(需传入 request_received 时保存的 stream)
func send_response(stream: StreamPeerTCP, status: int, headers: Dictionary, body: String, body_bytes: PackedByteArray = PackedByteArray()) -> void:
	if stream == null or stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var reason := _status_reason(status)
	var out := "HTTP/1.1 %d %s\r\n" % [status, reason]
	for key in headers:
		out += "%s: %s\r\n" % [key, headers[key]]
	if body_bytes.is_empty():
		body_bytes = body.to_utf8_buffer()
	out += "Content-Length: %d\r\n" % body_bytes.size()
	out += "Connection: close\r\n\r\n"
	stream.put_data(out.to_utf8_buffer() + body_bytes)
	stream.disconnect_from_host()


## 开启一条 SSE 流: 只写响应头且**不**关闭连接, 之后由 _poll_sse 发帧维持。
##
## 与 send_response 的区别正是"流式 vs 一次性", 故单列接口。流长未知所以不能给
## Content-Length, 但**必须**改用 Transfer-Encoding: chunked: 两者都不给的话,
## 严格 HTTP 客户端无法界定消息边界, 会把这整个响应判为非法 —— 实测客户端直接报
## "Invalid content type, expected \"text/event-stream\"", 流上的事件它一个也读不到。
## 返回 false 表示该连接已不可用(不可用或流已满), 调用方应放弃开流。
## [param session_id] 非空时把这条流登记为该旧式 SSE 会话的响应通道, 供 send_sse_message 回写。
## [param recycle_if_unused] 是否启用"开了流却没请求落上来"的 10s 回收(见 _poll_sse)。
##   仅旧式传输该开: 那条流的唯一用途就是接 initialize 响应, 不用就是废弃流。
##   已走 Streamable HTTP 的客户端开的 GET 流是**通知通道**, 请求全走 POST 直回,
##   它天然永不"被用过" —— 若也套 10s 回收, 客户端会被反复断流并立刻重开, 界面永远
##   停在"连接中"(实测 Copilot 就是这么被回收了 9 次)。这种流由 SSE_MAX_LIFETIME_MS 兜底。
func begin_sse(stream: StreamPeerTCP, headers: Dictionary, session_id: String = "", recycle_if_unused := true) -> bool:
	# 先数已有流: 客户端重连时旧流不会立刻消失, 不设上限连接会无界堆积(实测 13 条)。
	var live := 0
	for k in _conns:
		if k.get("_sse", false):
			live += 1
	if live >= MAX_SSE_CONNS:
		return false
	for c in _conns:
		if c.get("stream", null) != stream:
			continue
		if stream == null or stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return false
		var out := "HTTP/1.1 200 OK\r\n"
		for key in headers:
			out += "%s: %s\r\n" % [key, headers[key]]
		out += "Transfer-Encoding: chunked\r\n"
		out += "Connection: keep-alive\r\n\r\n"
		if stream.put_data(out.to_utf8_buffer()) != OK:
			return false
		# 开流即发一个注释帧, 让客户端解析器立刻见到第一个字节, 不用干等首个保活周期。
		# 这里刻意**不发任何 event 帧**: 本服务器从不主动推送消息, 更不能凭空造一个
		# server→client 的"请求"(如带 id 的 ping) —— MCP 的 JSON-RPC 方向是单向的,
		# 只允许 client→server 发请求, 反向发会被客户端当成非法消息。
		if not _sse_write(stream, ": open\n\n"):
			return false
		c["_sse"] = true
		c["_sse_tick"] = Time.get_ticks_msec()
		c["_sse_open"] = c["_sse_tick"]
		c["_sse_sent"] = 0
		c["_sse_session"] = session_id
		c["_sse_recycle"] = recycle_if_unused
		if not session_id.is_empty():
			_sse_sessions[session_id] = stream
			_sse_used[session_id] = false
		return true
	return false


## 维持一条已开启的 SSE 连接: 按间隔发注释帧(SSE 里以 ":" 开头的行是注释, 客户端会忽略,
## 但足以证明链路存活)防止中间层按空闲超时断链; 超龄则主动关闭, 由客户端自行重连。
## 返回 true 表示该连接应当被回收。
func _poll_sse(c: Dictionary, now: int) -> bool:
	var stream: StreamPeerTCP = c.stream
	# SSE 流不承载请求, 但仍要把客户端可能发来的字节读走: 堆在接收缓冲里不读会让
	# TCP 反压, 严重时反而把我们的保活帧堵住。
	var avail := stream.get_available_bytes()
	if avail > 0:
		var chunk := stream.get_data(avail)
		if TRACE_WIRE and chunk[0] == OK:
			LogTool.log("MCP", "[wire] !! SSE 流上又收到 %d 字节: %s" % [avail, _trace_bytes(chunk[1])])
	# 废弃流回收: 开了流却没有任何请求落到它上面(理由见 _sse_used 的注释)。
	# 判定只看"有没有被用过", 不用过就不再等 —— 它的用途只有"接 initialize 响应"这一种,
	# 客户端真要用早就用了, 再挂着也只是白占 socket 并逼近 MAX_SSE_CONNS。
	# 但这条理由只对旧式传输成立, 故受 _sse_recycle 约束: 已握手客户端的 GET 流是通知
	# 通道, 请求根本不走它, "永不曾被用过"是它的常态, 按废弃流回收即误杀(见 begin_sse)。
	var sid0: String = c.get("_sse_session", "")
	if not sid0.is_empty() and _sse_used.get(sid0, true) == false and c.get("_sse_recycle", true):
		var opened: int = int(c.get("_sse_open", now))
		if now - opened >= SSE_HANDSHAKE_MS:
			LogTool.log("MCP", "旧式 SSE 会话 %s 开启后 %.1fs 仍无请求落到该流, 回收闲置连接" % [sid0, (now - opened) / 1000.0])
			_sse_sessions.erase(sid0)
			_sse_used.erase(sid0)
			_sse_end(stream)
			return true
	var elapsed := now - int(c.get("_sse_tick", now))
	if elapsed >= SSE_MAX_LIFETIME_MS:
		_sse_write(stream, ": bye\n\n")
		_sse_end(stream)
		return true
	if elapsed - int(c.get("_sse_sent", 0)) >= SSE_KEEPALIVE_MS:
		if not _sse_write(stream, ": keepalive\n\n"):
			return true
		c["_sse_sent"] = elapsed
	return false


## 往 SSE 流写一段数据, 按 chunked 传输编码加帧: "<十六进制长度>\r\n<数据>\r\n"。
func _sse_write(stream: StreamPeerTCP, text: String) -> bool:
	var body := text.to_utf8_buffer()
	stream.put_data(("%x\r\n" % body.size()).to_utf8_buffer() + body + "\r\n".to_utf8_buffer())
	return stream.get_status() == StreamPeerTCP.STATUS_CONNECTED


## 结束 chunked 响应体: 补一个长度为 0 的终止块, 客户端才认为这条流是正常收尾,
## 而不是被中途掐断(掐断会被判为传输错误)。
func _sse_end(stream: StreamPeerTCP) -> void:
	stream.put_data("0\r\n\r\n".to_utf8_buffer())


func _send_simple(stream: StreamPeerTCP, status: int, headers: Dictionary, msg: String) -> void:
	send_response(stream, status, headers, msg)


## ======= 旧式 HTTP+SSE 传输(protocol 2024-11-05) =======
##
## 规范 Transports §Backwards Compatibility 的要求: 想兼容旧客户端就**同时**保留新旧端点。
## 旧式客户端的握手是两步, 且两步的分工与 Streamable HTTP 正好相反:
##   1. GET  → 200 text/event-stream, 服务端**必须**先发一条 `event: endpoint` 事件,
##              data 是客户端后续投递请求的 POST 地址(带 sessionId)。没有这条事件,
##              客户端无从得知该往哪 POST —— 它会一直停在"连接中", 连一次 POST 都不发。
##   2. POST → 客户端把 JSON-RPC 消息发到上面那个地址; 服务端**只能回 202 Accepted**,
##              真正的 JSON-RPC 响应要作为 `event: message` 帧**写回那条 SSE 流**。
## 第 2 步的响应路由正是与 Streamable HTTP 的分水岭: 同一个 POST, 走 Streamable HTTP 时
## 响应在 POST 连接上同步返回, 走旧式 SSE 时响应在 SSE 流上。若把两者混同(给旧式客户端
## 在 POST 上直接回 JSON), 客户端读不到任何响应, 表现为"已连接但工具全部超时"。

## 开启一条旧式 SSE 会话: 建流 + 发 endpoint 握手事件, 返回 sessionId。
## 返回空串表示开流失败(连接不可用或并发已满), 调用方应回 405 兜底。
## [param endpoint_path] 通告给客户端的 POST 地址, 建议传**绝对** URL:
##                     部分旧客户端不会拿它去和 SSE 的 URL 做相对解析, 只按原样使用。
func open_legacy_sse(stream: StreamPeerTCP, headers: Dictionary, endpoint_path: String, recycle_if_unused := true) -> String:
	var sid := _gen_session_id()
	headers = headers.duplicate()
	headers["Content-Type"] = "text/event-stream"
	headers["Cache-Control"] = "no-cache"
	if not begin_sse(stream, headers, sid, recycle_if_unused):
		return ""
	# endpoint 事件必须在任何业务消息之前发, 且 data 必须是客户端**原样使用**的 POST 地址
	if not _sse_write(stream, "event: endpoint\ndata: %s?sessionId=%s\n\n" % [endpoint_path, sid]):
		_sse_sessions.erase(sid)
		return ""
	return sid


## 会话是否还有效(对应 SSE 流仍在)。POST 处理器据此决定响应走 SSE 流还是走 POST 连接。
func has_sse_session(session_id: String) -> bool:
	if session_id.is_empty() or not _sse_sessions.has(session_id):
		return false
	# 标记这条流已被使用: 它随后就不会被 _poll_sse 当成废弃流回收了
	_sse_used[session_id] = true
	return true


## 把一条 JSON-RPC 消息作为 `event: message` 帧投递给指定会话的 SSE 流。
## 返回 false 表示会话已失效, 此时响应无处可去, 调用方只能降级回 POST 直回。
func send_sse_message(session_id: String, message: String) -> bool:
	var stream: StreamPeerTCP = _sse_sessions.get(session_id, null)
	if stream == null or stream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	return _sse_write(stream, "event: message\ndata: %s\n\n" % message)


func _gen_session_id() -> String:
	# 旧式握手只要求"不透明且唯一", 无需密码学强度; 用时间戳+计数器+随机数足够,
	# 目的是让并发的两个客户端(比如两个 IDE 窗口)不会互相把对方的 POST 认领走
	_sse_seq += 1
	return "%x-%x-%04x" % [Time.get_ticks_msec(), randi(), _sse_seq & 0xFFFF]


func _status_reason(code: int) -> String:
	match code:
		200: return "OK"
		202: return "Accepted"
		204: return "No Content"
		400: return "Bad Request"
		404: return "Not Found"
		405: return "Method Not Allowed"
		411: return "Length Required"
		413: return "Payload Too Large"
		500: return "Internal Server Error"
	return "Unknown"
