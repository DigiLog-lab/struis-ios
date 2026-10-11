#!/usr/bin/env python3
"""Claude の Messages API を真似る検証用サーバー(Simulator の配線確認用、実モデルではない)。

アプリの `ClaudeResponsesProxy` が送る要求を、現行の Claude が拒む形(役割の順序、tool_use と
tool_result の対応、thinking の署名、structured outputs の schema 制約など)で検査し、違反は
400 で返す。通った要求には、tool を 1 回使ってから答える・schema どおりの JSON を返す、の
決まった応答を SSE で返す。要求と応答は `--log-dir` に残す。

    python3 scripts/e2e/fake_anthropic.py --port 8787 --log-dir /tmp/fake-anthropic

アプリは `STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787` で起動する。
"""
from __future__ import annotations

import argparse
import base64
import itertools
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MODELS = {"claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"}
TOOL_NAME = re.compile(r"^[a-zA-Z0-9_-]{1,128}$")
TOOL_ID = re.compile(r"^[a-zA-Z0-9_-]+$")
UNSUPPORTED_SCHEMA = {"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength"}
SIGNATURE_PREFIX = "fake-sig-"
counter = itertools.count(1)
lock = threading.Lock()


def validate(body: dict) -> list[str]:
    errors: list[str] = []
    if body.get("model") not in MODELS:
        errors.append(f"model: unknown {body.get('model')!r}")
    if not isinstance(body.get("max_tokens"), int):
        errors.append("max_tokens: required")
    for key in ("temperature", "top_p", "top_k"):
        if key in body:
            errors.append(f"{key}: not supported on this model")
    thinking = body.get("thinking")
    if thinking is not None and thinking.get("type") not in ("adaptive",):
        errors.append(f"thinking.type: {thinking.get('type')!r} is not supported on this model")
    if thinking and "budget_tokens" in thinking:
        errors.append("thinking.budget_tokens: removed")
    choice = body.get("tool_choice")
    if choice and choice.get("type") in ("any", "tool"):
        errors.append("tool_choice: type \"tool\" and \"any\" are not supported for this model.")
    tools = body.get("tools") or []
    names = set()
    for tool in tools:
        name = tool.get("name", "")
        if not TOOL_NAME.match(name):
            errors.append(f"tools.name: {name!r} does not match ^[a-zA-Z0-9_-]{{1,128}}$")
        if name in names:
            errors.append(f"tools.name: duplicate {name!r}")
        names.add(name)
        if "input_schema" not in tool:
            errors.append(f"tools.{name}.input_schema: required")
    output_config = body.get("output_config") or {}
    if output_config.get("effort") not in (None, "low", "medium", "high", "xhigh", "max"):
        errors.append(f"output_config.effort: {output_config.get('effort')!r}")
    fmt = output_config.get("format")
    if fmt:
        if fmt.get("type") != "json_schema":
            errors.append("output_config.format.type must be json_schema")
        errors += check_schema(fmt.get("schema"), "output_config.format.schema")
    messages = body.get("messages") or []
    if not messages:
        errors.append("messages: at least one message is required")
        return errors
    if messages[0].get("role") != "user":
        errors.append("messages.0.role: first message must use the user role")
    if messages[-1].get("role") != "user":
        errors.append("This model does not support assistant message prefill. The conversation must end with a user message.")
    previous_role = None
    open_tool_uses: list[str] = []
    for index, message in enumerate(messages):
        role = message.get("role")
        if role not in ("user", "assistant"):
            errors.append(f"messages.{index}.role: {role!r}")
        if role == previous_role:
            errors.append(f"messages.{index}: roles must alternate between user and assistant")
        previous_role = role
        content = message.get("content")
        blocks = [{"type": "text", "text": content}] if isinstance(content, str) else (content or [])
        if not blocks:
            errors.append(f"messages.{index}.content: must not be empty")
        if role == "user":
            results = [b for b in blocks if b.get("type") == "tool_result"]
            if open_tool_uses:
                ids = [b.get("tool_use_id") for b in results]
                missing = [i for i in open_tool_uses if i not in ids]
                if missing:
                    errors.append(f"messages.{index}: tool_use ids {missing} were found without tool_result blocks immediately after")
                first_other = next((k for k, b in enumerate(blocks) if b.get("type") != "tool_result"), len(blocks))
                if any(b.get("type") == "tool_result" for b in blocks[first_other:]):
                    errors.append(f"messages.{index}: tool_result blocks must come first in the user message")
            for result in results:
                if result.get("tool_use_id") not in open_tool_uses:
                    errors.append(f"messages.{index}: unexpected tool_use_id {result.get('tool_use_id')!r} in tool_result")
            open_tool_uses = []
            for k, block in enumerate(blocks):
                if block.get("type") == "image":
                    source = block.get("source") or {}
                    if source.get("type") == "base64":
                        if source.get("media_type") not in ("image/jpeg", "image/png", "image/gif", "image/webp"):
                            errors.append(f"messages.{index}.content.{k}: image media_type")
                        try:
                            base64.b64decode(source.get("data", ""), validate=True)
                        except Exception:
                            errors.append(f"messages.{index}.content.{k}: invalid base64 image")
                elif block.get("type") not in ("text", "tool_result", "image", "document"):
                    errors.append(f"messages.{index}.content.{k}: {block.get('type')!r} is not allowed in a user message")
                if block.get("type") == "text" and not block.get("text"):
                    errors.append(f"messages.{index}.content.{k}: text content blocks must be non-empty")
        else:
            for k, block in enumerate(blocks):
                kind = block.get("type")
                if kind == "tool_use":
                    if not TOOL_ID.match(block.get("id", "")):
                        errors.append(f"messages.{index}.content.{k}.id: invalid")
                    if block.get("name") not in names:
                        errors.append(f"messages.{index}.content.{k}: tool {block.get('name')!r} is not defined")
                    if not isinstance(block.get("input"), dict):
                        errors.append(f"messages.{index}.content.{k}.input: must be an object")
                    open_tool_uses.append(block.get("id"))
                elif kind == "thinking":
                    if not str(block.get("signature", "")).startswith(SIGNATURE_PREFIX):
                        errors.append(f"messages.{index}.content.{k}: Invalid `signature` in `thinking` block")
                elif kind not in ("text", "redacted_thinking"):
                    errors.append(f"messages.{index}.content.{k}: {kind!r} is not allowed in an assistant message")
    return errors


def check_schema(schema, path: str) -> list[str]:
    errors: list[str] = []
    if isinstance(schema, list):
        for i, item in enumerate(schema):
            errors += check_schema(item, f"{path}.{i}")
        return errors
    if not isinstance(schema, dict):
        return errors
    for key in UNSUPPORTED_SCHEMA & schema.keys():
        errors.append(f"{path}: '{key}' is not supported in structured outputs")
    if schema.get("type") == "object" or "properties" in schema:
        if schema.get("additionalProperties") is not False:
            errors.append(f"{path}: additionalProperties must be false for every object")
    for key, value in schema.items():
        if key in ("properties", "$defs", "definitions") and isinstance(value, dict):
            for name, inner in value.items():
                errors += check_schema(inner, f"{path}.{key}.{name}")
        elif key in ("items", "anyOf", "allOf", "oneOf", "not", "additionalProperties", "prefixItems"):
            errors += check_schema(value, f"{path}.{key}")
    return errors


def sample(schema: dict, defs: dict, name: str = "value"):
    """schema に合う決まった値を作る(検証用の答え)。"""
    if "$ref" in schema:
        return sample(defs.get(schema["$ref"].split("/")[-1], {}), defs, name)
    if "const" in schema:
        return schema["const"]
    if "enum" in schema:
        return schema["enum"][0]
    for key in ("anyOf", "oneOf"):
        if key in schema:
            options = [s for s in schema[key] if s.get("type") != "null"] or schema[key]
            return sample(options[0], defs, name)
    kind = schema.get("type")
    if isinstance(kind, list):
        kind = next((k for k in kind if k != "null"), "null")
    if kind == "object" or "properties" in schema:
        props = schema.get("properties", {})
        return {key: sample(value, defs, key) for key, value in props.items()}
    if kind == "array":
        return [sample(schema.get("items", {}), defs, name)]
    if kind == "integer":
        return 1
    if kind == "number":
        return 1.0
    if kind == "boolean":
        return True
    if kind == "null":
        return None
    return f"Claude検証:{name}"


def last_user_has_tool_result(body: dict) -> bool:
    last = body["messages"][-1]
    content = last.get("content")
    return isinstance(content, list) and any(b.get("type") == "tool_result" for b in content)


def plan_response(body: dict) -> tuple[list[dict], str]:
    """返すブロック(順番)と stop_reason。"""
    n = next(counter)
    signature = f"{SIGNATURE_PREFIX}{n}"
    blocks: list[dict] = [{"type": "thinking", "thinking": f"検証用の考えごと {n}", "signature": signature}]
    fmt = (body.get("output_config") or {}).get("format")
    tools = {t["name"] for t in body.get("tools") or []}
    if fmt:
        schema = fmt["schema"]
        blocks.append({"type": "text", "text": json.dumps(sample(schema, schema.get("$defs", {})), ensure_ascii=False)})
        return blocks, "end_turn"
    if "struis__exec_command" in tools and not last_user_has_tool_result(body):
        blocks.append({"type": "text", "text": "作業フォルダを確認します。"})
        blocks.append({"type": "tool_use", "id": f"toolu_fake{n:04d}", "name": "struis__exec_command",
                       "input": {"cmd": "ls -1 | head -20"}})
        return blocks, "tool_use"
    blocks.append({"type": "text", "text": "Claude(検証用サーバー)からの返事です。作業フォルダを確認しました。"})
    return blocks, "end_turn"


def sse(event: dict) -> bytes:
    return f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    log_dir: Path = Path("/tmp/fake-anthropic")
    delay = 0.02

    def log_message(self, *args):  # noqa: D401
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        stamp = f"{time.time():.3f}"
        if self.path != "/v1/messages":
            self.reply(404, {"type": "error", "error": {"type": "not_found_error", "message": self.path}})
            return
        if not self.headers.get("x-api-key") or self.headers.get("anthropic-version") != "2023-06-01":
            self.reply(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            return
        body = json.loads(raw)
        errors = validate(body)
        record = {"path": self.path, "errors": errors, "request": scrub(body)}
        if errors:
            self.write_log(stamp, record)
            self.reply(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "; ".join(errors)}})
            return
        blocks, stop = plan_response(body)
        record["response"] = {"blocks": blocks, "stop_reason": stop}
        self.write_log(stamp, record)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        msg_id = f"msg_fake{next(counter):04d}"
        self.emit({"type": "message_start", "message": {"id": msg_id, "type": "message", "role": "assistant", "model": body["model"],
                                                        "content": [], "usage": {"input_tokens": 120, "cache_read_input_tokens": 800, "output_tokens": 1}}})
        self.emit({"type": "ping"})
        for index, block in enumerate(blocks):
            kind = block["type"]
            if kind == "thinking":
                self.emit({"type": "content_block_start", "index": index, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
                self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "thinking_delta", "thinking": block["thinking"]}})
                self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "signature_delta", "signature": block["signature"]}})
            elif kind == "text":
                self.emit({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
                text = block["text"]
                for start in range(0, len(text), 12):
                    self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": text[start:start + 12]}})
            elif kind == "tool_use":
                self.emit({"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}})
                payload = json.dumps(block["input"], ensure_ascii=False)
                half = len(payload) // 2
                self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": payload[:half]}})
                self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": payload[half:]}})
            self.emit({"type": "content_block_stop", "index": index})
        self.emit({"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 64}})
        self.emit({"type": "message_stop"})

    def emit(self, event: dict):
        self.wfile.write(sse(event))
        self.wfile.flush()
        time.sleep(self.delay)

    def reply(self, status: int, payload: dict):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def write_log(self, stamp: str, record: dict):
        with lock:
            self.log_dir.mkdir(parents=True, exist_ok=True)
            (self.log_dir / f"{stamp}-{len(list(self.log_dir.iterdir())):04d}.json").write_text(
                json.dumps(record, ensure_ascii=False, indent=1))


def scrub(value):
    if isinstance(value, list):
        return [scrub(v) for v in value]
    if isinstance(value, dict):
        if value.get("type") == "base64" and "data" in value:
            return {**value, "data": f"…({len(value['data'])} chars)"}
        return {k: scrub(v) for k, v in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--log-dir", default="/tmp/fake-anthropic")
    args = parser.parse_args()
    Handler.log_dir = Path(args.log_dir)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"fake anthropic on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
