#!/usr/bin/env python3
"""
最小可用的 MCP server（HTTP POST，JSON-RPC 2.0），用于验证苏兴的 MCP 客户端。

零依赖，只用标准库。提供三个工具：
  echo     回显输入
  server_time  返回服务器时间
  add      两数相加（演示多参数）

用法：
  python3 tools/mcp_test_server.py
  # 默认监听 0.0.0.0:8765
  # 手机和电脑在同一个 WiFi 下，然后在手机上复制这个 URL：
  #   http://<电脑局域网IP>:8765/mcp
  # 打开苏兴 → 🤖 操控 → 「从剪贴板连接 MCP server」

注意：只在局域网内用，没有鉴权，不要暴露到公网。
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "0.0.0.0"
PORT = 8765

TOOLS = [
    {
        "name": "echo",
        "description": "回显传入的文本",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "server_time",
        "description": "返回服务器当前时间",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "add",
        "description": "两个数相加",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
        },
    },
]


def call_tool(name, args):
    if name == "echo":
        return "echo: " + str(args.get("text", ""))
    if name == "server_time":
        return time.strftime("%Y-%m-%d %H:%M:%S")
    if name == "add":
        try:
            return str(float(args.get("a", 0)) + float(args.get("b", 0)))
        except Exception:
            return "参数不是数字"
    return "unknown tool: " + name


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self._send({"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error"}})
            return

        method = req.get("method", "")
        rid = req.get("id")
        print("[mcp] <-", method, flush=True)

        # 通知没有 id，按规范不回应
        if rid is None:
            self.send_response(202)
            self.end_headers()
            return

        if method == "initialize":
            self._send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "suxing-test-server", "version": "1.0.0"},
            }})
        elif method == "tools/list":
            self._send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = req.get("params", {})
            text = call_tool(params.get("name", ""), params.get("arguments", {}))
            self._send({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": text}]
            }})
        else:
            self._send({"jsonrpc": "2.0", "id": rid,
                        "error": {"code": -32601, "message": "method not found"}})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"MCP test server on http://0.0.0.0:{PORT}/mcp", flush=True)
    HTTPServer((HOST, PORT), Handler).serve_forever()
