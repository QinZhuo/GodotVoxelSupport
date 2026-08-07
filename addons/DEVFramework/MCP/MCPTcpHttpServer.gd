@tool
## MCP 内置 HTTP 服务器 — 基于 TCPServer 的最小 HTTP/1.1 实现
## 仅服务于本机 MCP 调试(MCP Streamable HTTP 传输), 每次请求处理后关闭连接
class_name MCPTcpHttpServer extends RefCounted

## 完成一个完整 HTTP 请求时触发
## [param method] 请求方法(GET/POST/...)
## [param path] 请求路径(不含 query)
## [param headers] 请求头(小写 key)
## [param body] 请求体字节
## [param stream] 对应连接的 StreamPeerTCP, 用 send_response(stream,...) 回写
## 处理器需调用 send_response() 发送结果; 若未调用则无响应(超时由客户端兜底)
signal request_received(method: String, path: String, headers: Dictionary, body: PackedByteArray, stream: StreamPeerTCP)

var _server: TCPServer
var _conns: Array = []          # 进行中的连接(字典数组)
const MAX_BODY_SIZE := 16 * 1024 * 1024   # 16MB 上限


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
	while _server.is_connection_available():
		var stream: StreamPeerTCP = _server.take_connection()
		_conns.append({"stream": stream, "buffer": PackedByteArray(), "headers_done": false, "content_length": -1})

	var finished := []
	for i in _conns.size():
		var c = _conns[i]
		var stream: StreamPeerTCP = c.stream
		stream.poll()
		var status := stream.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED or status == StreamPeerTCP.STATUS_CONNECTING:
			_read_available(c)
			_process_buffer(c, finished, i)
		elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE or c.get("_overload", false):
			# 已断开(响应完成后 disconnect 会进入 STATUS_NONE)或超限的连接一律回收,
			# 避免 _conns 无限增长造成内存泄漏
			finished.append(i)
	finished.sort()
	finished.reverse()
	for i in finished:
		var c = _conns[i]
		var stream: StreamPeerTCP = c.get("stream")
		if stream:
			stream.disconnect_from_host()
		_conns.remove_at(i)


func _read_available(c: Dictionary) -> void:
	var stream: StreamPeerTCP = c.stream
	var available := stream.get_available_bytes()
	while available > 0:
		var chunk := stream.get_data(available)
		if chunk[0] != OK:
			break
		var data: PackedByteArray = chunk[1]
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
		c.headers = parsed.headers
		var cl: int = parsed.headers.get("content-length", "-1").to_int()
		# 无 body 的请求(GET/OPTIONS/HEAD/DELETE)通常不带 Content-Length, 按 0 处理
		if cl < 0 and (c.method == "OPTIONS" or c.method == "GET" or c.method == "HEAD" or c.method == "DELETE"):
			cl = 0
		c.content_length = cl
		c.headers_done = true
		c._body_start = body_start
		if c.content_length < 0 or c.content_length > MAX_BODY_SIZE:
			_send_simple(c.stream, 411, {}, "Length Required")
			c._drop = true
			finished.append(conn_index)
			return
	# headers 已解析, 收集 body
	var body_start: int = c.get("_body_start", 0)
	var needed: int = c.content_length
	if buf.size() - body_start >= needed:
		var body := buf.slice(body_start, body_start + needed)
		c.buffer = buf.slice(body_start + needed)
		c.headers_done = false
		c.content_length = -1
		c._body_start = 0
		var headers: Dictionary = c.headers.duplicate()
		var stream: StreamPeerTCP = c.stream
		request_received.emit(c.method, c.path, headers, body, stream)
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
	var path := raw_path.split("?")[0]
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
	return {"method": method, "path": path, "headers": headers}


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


func _send_simple(stream: StreamPeerTCP, status: int, headers: Dictionary, msg: String) -> void:
	send_response(stream, status, headers, msg)


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
