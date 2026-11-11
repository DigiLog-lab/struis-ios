#!/usr/bin/env python3
"""Claude の Messages API を真似る検証用サーバー(Simulator の配線確認用、実モデルではない)。

アプリの `ClaudeResponsesProxy` が送る要求を、現行の Claude が拒む形(役割の順序、tool_use と
tool_result の対応、thinking の署名、structured outputs の schema 制約など)で検査し、違反は
400 で返す。通った要求には、tool を 1 回使ってから答える・schema どおりの JSON を返す、の
決まった応答を SSE で返す。要求と応答は `--log-dir` に残す。

    python3 scripts/e2e/fake_anthropic.py --port 8787 --log-dir /tmp/fake-anthropic

アプリは `STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787` で起動する。

Codex 版と Claude 直結版の比較(`RunnerComparisonLiveTests`)のために、次を `POST /__control` で切り替える。

    {"scenario": "codex/grading-1", "mode": "script", "faults": [{"kind": "http", "status": 500}]}

- `scenario`: 要求の記録の置き場所(`<log-dir>/scenarios/<scenario>/NNNN.json`)。到着と返し終わりの時刻も残す。
- `mode`: `script`(決まった応答)、`record`(本物の API へ転送して応答を時刻付きで `<tape-dir>/<tape>/NNNN.json` に録る)、
  `replay`(録った応答を同じ間隔で順に返す)。録画と再生は要求の中身ではなく順番で対応させる(比べる 2 つの本文は同じとは限らない)。
- `match`: 録画と再生の対応のさせ方。`order`(既定。届いた順)か `kind`(要求の種類ごとの順)。`kind` は、出力の形(JSON Schema)が
  同じ要求を同じ種類とみなし、`<tape-dir>/<tape>/<種類>/NNNN.json` に分けて録る。タイムラインは次のカードの束・見直し・知識グラフを
  裏で同時に送るので、届いた順は回ごとに入れ替わる。種類ごとの順なら、同じ操作をすれば同じ返事が同じ要求に戻る(宣伝の撮影用)。
- `faults`: 要求ごとに 1 つ消費する故障の列(`http`・`drop`・`stall`・`sse_error`・`first_byte_delay`・`trickle`)。
  `trickle` は最初の本文の前に、本文の差分を `interval` 秒(既定 1)ごとに 1 つ、最大 `seconds` 秒(既定 900)流し続ける
  (止める操作の確認用。接続は切らないのでアプリは送り直さない)。送った差分の数と最後の時刻を記録の `trickle` に残す。

会話の返事は、学習者の今の発言(最後の `The learner's current message:` の後)で変わる。「調べて」があれば資料を探してから
`struis__struis_delegate` に任せ、「続けて」があれば最初のラウンドで `disposition: continue` を返して続きのラウンドを起こす
(続きのラウンドは `not_learning` で終える)。
「計算して」があれば `struis__exec_command` で `python3 -c` の SymPy の計算を 1 回呼び、出力の `SYMPY …` の行を返事に載せる
(Workspace の Python が動くことの確認用)。

`usage`(例 `{"cache_read_input_tokens": 250000}`)を渡すと、アプリへ返す応答の usage をその値で上書きする(`record` でも。
録画には本物の値を残す)。長い会話を新しいスレッドへ移す確認用。
要求の記録は、番号を取った時に `pending: true` で書き、返し終わり・接続の切断・転送の失敗(`exception`)のどれでも書き直す。

`record` の転送先のキーは `--upstream-key-file` のファイルから読み、記録には残さない。
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import itertools
import json
import re
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MODELS = {"claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"}
TOOL_NAME = re.compile(r"^[a-zA-Z0-9_-]{1,128}$")
TOOL_ID = re.compile(r"^[a-zA-Z0-9_-]+$")
UNSUPPORTED_SCHEMA = {"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength"}
SIGNATURE_PREFIX = "fake-sig-"
counter = itertools.count(1)
lock = threading.Lock()


class Control:
    """`POST /__control` で決める、いまの比較の場面。"""
    scenario: str | None = None
    mode = "script"
    tape: str | None = None
    tape_index = 0
    match = "order"
    kind_index: dict[str, int] = {}
    faults: collections.deque = collections.deque()
    request_index = 0
    tape_dir = Path("/tmp/fake-anthropic-tapes")
    upstream = "https://api.anthropic.com"
    upstream_key_file: str | None = None
    usage: dict | None = None

    @classmethod
    def set(cls, payload: dict) -> None:
        with lock:
            cls.scenario = payload.get("scenario")
            cls.mode = payload.get("mode", "script")
            cls.tape = payload.get("tape")
            cls.tape_index = 0
            cls.match = payload.get("match", "order")
            cls.kind_index = {}
            cls.faults = collections.deque(payload.get("faults") or [])
            cls.request_index = 0
            cls.usage = payload.get("usage")

    @classmethod
    def next_request(cls) -> tuple[int, dict | None]:
        with lock:
            cls.request_index += 1
            return cls.request_index, (cls.faults.popleft() if cls.faults else None)

    @classmethod
    def next_tape_path(cls, kind: str = "free") -> Path:
        with lock:
            root = cls.tape_dir / (cls.tape or "default")
            if cls.match == "kind":
                cls.kind_index[kind] = cls.kind_index.get(kind, 0) + 1
                return root / kind / f"{cls.kind_index[kind]:04d}.json"
            cls.tape_index += 1
            return root / f"{cls.tape_index:04d}.json"


SCHEMA_MARKER = "It must validate against this JSON Schema:\n"


def request_kind(body: dict) -> str:
    """要求の種類の名前(`match: kind` の録画と再生の対応に使う)。出力の形(JSON Schema)で見分ける。

    形は `output_config.format.schema` か、指示文に書いた JSON Schema(アプリの `ClaudeTranslation.schemaInstruction`)。
    名前は必須の項目の先頭 3 つと、形のハッシュの先頭 8 桁。
    形が無い要求(会話の返事・進み具合の保存など)は、使える道具の名前と最初の指示文(先頭 1500 字)で見分け、
    `free-<ハッシュ 8 桁>` にする。全部を `free` 1つにまとめると、届く順が入れ替わった時に、進み具合の保存に会話の返事を
    返してしまう(2026-11-11、単元づくりの再生で起きた)。
    """
    schema = ((body.get("output_config") or {}).get("format") or {}).get("schema")
    if schema is None:
        system = body.get("system")
        texts = [system] if isinstance(system, str) else [b.get("text", "") for b in system or [] if isinstance(b, dict)]
        for text in texts:
            if SCHEMA_MARKER in text:
                raw = text.split(SCHEMA_MARKER, 1)[1].strip()
                try:
                    schema = json.loads(raw)
                except json.JSONDecodeError:
                    schema = raw
                break
    if schema is None:
        system = body.get("system")
        first = system if isinstance(system, str) else next((b.get("text", "") for b in system or [] if isinstance(b, dict)), "")
        tools = sorted(t.get("name", "") for t in body.get("tools") or [])
        return "free-" + hashlib.sha1((json.dumps(tools) + first[:1500]).encode()).hexdigest()[:8]
    canonical = json.dumps(schema, ensure_ascii=False, sort_keys=True)
    required = schema.get("required", []) if isinstance(schema, dict) else []
    head = "-".join(re.sub(r"[^a-z0-9_]", "", str(name).lower()) for name in required[:3]) or "schema"
    return f"{head}-{hashlib.sha1(canonical.encode()).hexdigest()[:8]}"


class ConnectionDropped(Exception):
    """故障の再現で、応答の途中で接続を切る。"""


def validate(body: dict, recorded_signatures: bool = False) -> list[str]:
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
                    if not recorded_signatures and not str(block.get("signature", "")).startswith(SIGNATURE_PREFIX):
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


def last_tool_use(body: dict):
    for message in reversed(body["messages"]):
        if message["role"] == "assistant" and isinstance(message["content"], list):
            uses = [b for b in message["content"] if b.get("type") == "tool_use"]
            if uses:
                return uses[-1]
            return None
    return None


def last_tool_result_text(body: dict) -> str:
    content = body["messages"][-1]["content"]
    texts = []
    for block in content if isinstance(content, list) else []:
        if block.get("type") == "tool_result":
            inner = block.get("content")
            texts.append(inner if isinstance(inner, str) else json.dumps(inner, ensure_ascii=False))
    return "\n".join(texts)


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
    # 委任は学習者の今の発言で決める(前の回の発言や Codex の足す文の数で、送る範囲が変わらないように)。
    latest = latest_learner_message(body) or "\n".join(user_texts(body)[-2:])
    if "struis__struis_delegate" in tools and "調べて" in latest:
        previous = last_tool_use(body)
        if not last_user_has_tool_result(body):
            # 委任の前に、指定できる資料を探す。
            blocks.append({"type": "tool_use", "id": f"toolu_fake{n:04d}", "name": "struis__exec_command",
                           "input": {"cmd": "find tutor_desk struis_context -type f | head -5"}})
            return blocks, "tool_use"
        if previous and previous.get("name") == "struis__exec_command" and "find tutor_desk" in json.dumps(previous.get("input")):
            found = re.findall(r"((?:tutor_desk|struis_context)/[^\\\s\"]+)", last_tool_result_text(body))
            blocks.append({"type": "tool_use", "id": f"toolu_fake{n:04d}", "name": "struis__struis_delegate", "input": {
                "task_type": "material_search", "purpose": "例題に近い問題を探す", "sources": found[:1] or ["struis_context/recent_thread_history.md"],
                "search_scope": "指定したファイル全体", "conditions": "一次方程式", "count": 1, "return_information": "問題文"}})
            return blocks, "tool_use"
    if "struis__exec_command" in tools and "計算して" in latest:
        # Workspace の Python を確かめる: SymPy の計算を 1 回呼び、その出力を返事に載せる。
        if not last_user_has_tool_result(body):
            blocks.append({"type": "text", "text": "SymPy で計算します。"})
            blocks.append({"type": "tool_use", "id": f"toolu_fake{n:04d}", "name": "struis__exec_command", "input": {"cmd": SYMPY_COMMAND}})
            return blocks, "tool_use"
        blocks.append({"type": "text", "text": chat_reply(body, computed=sympy_output(last_tool_result_text(body)))})
        return blocks, "end_turn"
    if "struis__exec_command" in tools and not last_user_has_tool_result(body):
        blocks.append({"type": "text", "text": "作業フォルダを確認します。"})
        blocks.append({"type": "tool_use", "id": f"toolu_fake{n:04d}", "name": "struis__exec_command",
                       "input": {"cmd": "ls -1 | head -20"}})
        return blocks, "tool_use"
    blocks.append({"type": "text", "text": chat_reply(body)})
    return blocks, "end_turn"


SYMPY_COMMAND = ("python3 -c 'import sympy as s; x=s.symbols(\"x\"); "
                 "print(\"SYMPY\", s.factor(x**2-5*x+6), s.integrate(x**2,(x,0,3)), s.solve(x**2-2,x))'")


def sympy_output(result: str) -> str:
    """道具の結果から `SYMPY ...` の行を取り出す。無ければ結果の先頭を返す(失敗も画面で見えるように)。"""
    try:
        decoded = json.loads(result)
        result = decoded.get("output", result) if isinstance(decoded, dict) else result
    except (ValueError, TypeError):
        pass
    for line in str(result).splitlines():
        if line.startswith("SYMPY "):
            return line
    return "(SYMPY の行が無い) " + str(result)[:200]


def user_texts(body: dict) -> list[str]:
    texts = []
    for message in body["messages"]:
        if message["role"] != "user":
            continue
        content = message["content"]
        for block in [{"type": "text", "text": content}] if isinstance(content, str) else content:
            if block.get("type") == "text":
                texts.append(block["text"])
    return texts


LEARNER_MARK = "The learner's current message:\n"
CONTINUATION = "Continue the remaining model-owned work"


def latest_turn_text(body: dict) -> str:
    """いまのラウンドの依頼文(学習者の発言を載せた文か、続きの依頼)。無ければ空。"""
    for text in reversed(user_texts(body)):
        if LEARNER_MARK in text or CONTINUATION in text:
            return text
    return ""


def latest_learner_message(body: dict) -> str:
    """最後の `The learner's current message:` の後の、学習者の発言だけ(後ろに付く進行の文脈や記憶は除く)。"""
    for text in reversed(user_texts(body)):
        if LEARNER_MARK in text:
            message = text.rsplit(LEARNER_MARK, 1)[1]
            for end in ("\n\n", "\nStruis progress context"):
                message = message.split(end, 1)[0]
            return message
    return ""


def continue_goal() -> dict:
    """`disposition: continue` に要る、いま進めている一番小さい目標(モデルの目標、繰り返しなし)。"""
    return {
        "id": "fake-continue", "parent_id": None, "title": "平方完成の手順を確かめる", "outcome": "平方完成の手順を説明できる",
        "learner_action": "説明を読む", "model_action": "手順を続けて説明する", "completion_condition": "手順を最後まで説明した",
        "kind": "model", "status": "active", "next_action": "続きの手順を説明する", "child_order": [], "evidence": [],
        "loop": {"enabled": False, "unit": "説明", "repeat_when": "なし", "exit_when": "説明を終えた", "after_exit": "質問を待つ",
                 "stagnation_attempts": 2, "max_attempts": 1},
    }


def revision_of(text: str) -> int:
    revision = 0
    for match in re.finditer(r'"revision"\s*:\s*(\d+)', text):
        revision = int(match.group(1))
    return revision


def chat_reply(body: dict, computed: str | None = None) -> str:
    """Struis のチャットの約束事(返事 + 非公開ブロック)に沿った最小の返事。`computed` は道具の計算結果。"""
    texts = user_texts(body)
    latest = "\n".join(texts[-3:])
    reply = "Claude(検証用サーバー)からの返事です。一次方程式の文章題の単元を作りましょう。"
    if computed is not None:
        reply = "Claude(検証用サーバー)からの返事です。Python の計算結果: " + computed
    if "<struis_current_turn_source>" not in "\n".join(texts) and "progress" not in latest:
        return reply if computed is not None else "Claude(検証用サーバー)からの返事です。作業フォルダを確認しました。"
    revision = 0
    for match in re.finditer(r'"revision"\s*:\s*(\d+)', latest):
        revision = int(match.group(1))
    if "Your private blocks failed validation" in latest:
        # 修正の回: 書いた返事はそのまま、非公開ブロックだけを返す。
        update = {"schema_version": 1, "base_revision": revision_of(latest), "goals": [], "problems": [], "attempts": [],
                  "current_goal_id": None, "disposition": "not_learning", "next_action": "", "reply_quotes": [reply]}
        return "<struis_progress_update>" + json.dumps(update, ensure_ascii=False) + "</struis_progress_update>\n<struis_memory_update>NO_UPDATE</struis_memory_update>"
    update = {"schema_version": 1, "base_revision": revision, "goals": [], "problems": [], "attempts": [],
              "current_goal_id": None, "disposition": "not_learning", "next_action": "", "reply_quotes": [reply]}
    # 学習者が「続けて」と書いた最初のラウンドは、続きのラウンド(`disposition: continue`)を頼む。続きのラウンドは終える。
    continuing = CONTINUATION in latest_turn_text(body) and LEARNER_MARK not in latest_turn_text(body)
    if "続けて" in latest_learner_message(body) and not continuing:
        reply = "Claude(検証用サーバー)からの返事です。続きの説明に進みます。"
        update.update(goals=[continue_goal()], current_goal_id="fake-continue", disposition="continue",
                      next_action="続きの手順を説明する", reply_quotes=[reply])
    elif continuing:
        reply = "Claude(検証用サーバー)からの返事です。続きの説明はここまでです。"
        update["reply_quotes"] = [reply]
    blocks = [reply,
              "<struis_progress_update>" + json.dumps(update, ensure_ascii=False) + "</struis_progress_update>",
              "<struis_memory_update>NO_UPDATE</struis_memory_update>"]
    if any(word in latest for word in ("苦手", "練習問題", "単元")):
        blocks.append('<struis_workbook_proposal>{"request": "一次方程式の文章題(中学1年)"}</struis_workbook_proposal>')
    if "わかりました" in latest:
        blocks.append("<struis_workbook_example_ready/>")
    if "struis_workbook_example" in latest:
        blocks.append('<struis_workbook_example>{"prompt": "ある数の3倍に5を足すと20になる。ある数を求めよ。"}</struis_workbook_example>')
    return "\n".join(blocks)


def sse(event: dict) -> bytes:
    return f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    log_dir: Path = Path("/tmp/fake-anthropic")
    delay = 0.02
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # noqa: D401
        pass

    def do_GET(self):
        if self.path == "/__health":
            self.reply(200, {"ok": True})
            return
        self.reply(404, {"type": "error", "error": {"type": "not_found_error", "message": self.path}})

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        arrived = time.time()
        stamp = f"{arrived:.3f}"
        if self.path == "/__control":
            Control.set(json.loads(raw or b"{}"))
            self.reply(200, {"ok": True})
            return
        if self.path != "/v1/messages":
            self.reply(404, {"type": "error", "error": {"type": "not_found_error", "message": self.path}})
            return
        if not self.headers.get("x-api-key") or self.headers.get("anthropic-version") != "2023-06-01":
            self.reply(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            return
        body = json.loads(raw)
        index, fault = Control.next_request()
        mode = Control.mode
        # 置き場所は着いた時の場面で決める(直結版は最後のイベントで返るので、書き終わる前に次の場面へ切り替わることがある)。
        self.scenario = Control.scenario
        errors = [] if mode == "record" else validate(body, recorded_signatures=mode == "replay")
        # 送り手(アプリの URLSession は CFNetwork、以前の端末内プロキシ経由は Codex の HTTP クライアント)を見分ける。
        record = {"path": self.path, "errors": errors, "request": scrub(body), "arrived_at": arrived, "bytes": len(raw), "fault": fault, "mode": mode,
                  "user_agent": self.headers.get("user-agent"), "peer": self.client_address[0]}
        self.fault = fault
        self.events_sent = 0
        self.fault_fired = False
        self.record = record
        self.request_index = index
        # 同じ接続で次の要求が来ても別の名前にする(HTTP/1.1 の keep-alive では同じ Handler が続けて受ける)。
        self.log_name = f"{index:04d}.json" if self.scenario else f"{stamp}-{index:04d}.json"
        self.usage = Control.usage
        if self.usage:
            record["usage_override"] = self.usage
        # 番号を取った要求は、返し終わる前でも記録に残す(返している途中で止まった・落ちた要求も欠番にしない)。
        record["pending"] = True
        self.write_log(stamp, record)
        try:
            self.answer(raw, body, record, errors, mode, stamp)
        except ConnectionDropped:
            record["dropped"] = True
            self.close_connection = True
        except (BrokenPipeError, ConnectionResetError):
            # 依頼主が要求をやめた(止める・時間切れ)。
            record["client_went_away"] = True
            self.close_connection = True
        except Exception as error:  # noqa: BLE001 — 転送の失敗なども記録に残してから接続を閉じる
            record["exception"] = f"{type(error).__name__}: {error}"
            self.close_connection = True
        finally:
            record.pop("pending", None)
            record["finished_at"] = time.time()
            self.write_log(stamp, record)

    def answer(self, raw: bytes, body: dict, record: dict, errors: list[str], mode: str, stamp: str):
        if errors:
            record["status"] = 400
            self.reply(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "; ".join(errors)}})
            return
        fault = self.fault
        if fault and fault.get("kind") == "http":
            status = int(fault.get("status", 500))
            record["status"] = status
            kind = fault.get("type") or {429: "rate_limit_error", 529: "overloaded_error", 401: "authentication_error", 400: "invalid_request_error"}.get(status, "api_error")
            headers = {"retry-after": str(fault["retry_after"])} if "retry_after" in fault else {}
            self.reply(status, {"type": "error", "error": {"type": kind, "message": fault.get("message", f"fake {status}")}}, headers)
            return
        if fault and fault.get("kind") == "first_byte_delay":
            time.sleep(float(fault.get("seconds", 1)))
        if mode in ("record", "replay"):
            kind = request_kind(body)
            record["kind"] = kind
            path = Control.next_tape_path(kind)
            if mode == "record":
                self.forward(raw, record, path)
            else:
                self.replay(record, path)
            return
        blocks, stop = plan_response(body)
        record["response"] = {"blocks": blocks, "stop_reason": stop}
        record["status"] = 200
        self.begin_stream()
        msg_id = f"msg_fake{next(counter):04d}"
        self.emit({"type": "message_start", "message": {"id": msg_id, "type": "message", "role": "assistant", "model": body["model"],
                                                        "content": [], "usage": {"input_tokens": 120, "cache_read_input_tokens": 800, "output_tokens": 1, **(self.usage or {})}}})
        self.emit({"type": "ping"})
        for index, block in enumerate(blocks):
            kind = block["type"]
            if kind == "thinking":
                self.emit({"type": "content_block_start", "index": index, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
                self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "thinking_delta", "thinking": block["thinking"]}})
                self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "signature_delta", "signature": block["signature"]}})
            elif kind == "text":
                self.emit({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
                self.trickle(index)
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

    # MARK: 録画と再生

    def forward(self, raw: bytes, record: dict, path: Path):
        """本物の API へ転送し、届いた順と間隔のまま返して録る。キーは記録に残さない。"""
        key = Path(Control.upstream_key_file).read_text().strip() if Control.upstream_key_file else ""
        request = urllib.request.Request(Control.upstream + "/v1/messages", data=raw, method="POST", headers={
            "content-type": "application/json", "anthropic-version": "2023-06-01", "accept": "text/event-stream", "x-api-key": key})
        record["tape"] = str(path)
        started = time.time()
        tape: dict = {"events": []}
        try:
            response = urllib.request.urlopen(request, timeout=600)
        except urllib.error.HTTPError as error:
            payload = error.read()
            tape.update(status=error.code, body=payload.decode("utf-8", "replace"), retry_after=error.headers.get("retry-after"))
            self.save_tape(path, tape)
            record["status"] = error.code
            self.send_response(error.code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            if error.headers.get("retry-after"):
                self.send_header("retry-after", error.headers["retry-after"])
            self.end_headers()
            self.wfile.write(payload)
            return
        record["status"] = response.status
        tape["status"] = response.status
        self.begin_stream()
        data_lines: list[str] = []
        texts = 0
        try:
            for line in response:
                text = line.decode("utf-8").rstrip("\r\n")
                if text.startswith("data:"):
                    data_lines.append(text[5:].strip())
                elif not text and data_lines:
                    event = json.loads("\n".join(data_lines))
                    data_lines = []
                    tape["events"].append([round(time.time() - started, 4), event])
                    self.emit(self.override_usage(event), pace=False)
                    if (event.get("delta") or {}).get("type") == "text_delta":
                        # 転送の途中の進み具合(本文が流れ始めた時刻と、アプリへ渡した本文の差分の数)を記録に書き出す。
                        texts += 1
                        record["text_deltas"] = texts
                        record["last_text_at"] = time.time()
                        if texts == 1:
                            record["first_text_at"] = record["last_text_at"]
                        if texts == 1 or texts % 10 == 0:
                            self.write_log("", record)
        finally:
            # アプリが要求をやめても、それまでに届いた分を録画に残す。
            tape["complete"] = any(e[1].get("type") == "message_stop" for e in tape["events"])
            self.save_tape(path, tape)
            response.close()

    def override_usage(self, event: dict) -> dict:
        """`usage` の差し替え(長い会話の切り替えの確認用)。録画には本物の値を残し、アプリへ返す値だけ変える。"""
        if not self.usage:
            return event
        if event.get("type") == "message_start":
            message = dict(event.get("message") or {})
            message["usage"] = {**(message.get("usage") or {}), **self.usage}
            self.record["usage_upstream"] = (event.get("message") or {}).get("usage")
            return {**event, "message": message}
        if event.get("type") == "message_delta" and isinstance(event.get("usage"), dict):
            usage = dict(event["usage"])
            for key, value in self.usage.items():
                if key in usage:
                    usage[key] = value
            return {**event, "usage": usage}
        return event

    def save_tape(self, path: Path, tape: dict):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(tape, ensure_ascii=False))

    def replay(self, record: dict, path: Path):
        if not path.exists() and path.parent.name.startswith("free-"):
            # 種類を分ける前の録音(`free` 1つ)は、届いた順のまま使う。
            path = Control.next_tape_path("free")
        if not path.exists():
            record["status"] = 409
            self.reply(409, {"type": "error", "error": {"type": "invalid_request_error", "message": f"tape ended: {path.name}"}})
            return
        tape = json.loads(path.read_text())
        record["status"] = tape.get("status", 200)
        record["tape"] = str(path)
        if tape.get("status", 200) != 200:
            headers = {"retry-after": tape["retry_after"]} if tape.get("retry_after") else {}
            self.reply(tape["status"], json.loads(tape.get("body") or "{}"), headers)
            return
        self.begin_stream()
        started = time.time()
        for offset, event in tape["events"]:
            wait = started + offset - time.time()
            if wait > 0:
                time.sleep(wait)
            self.emit(event, pace=False)

    # MARK: 送信

    def begin_stream(self):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

    def trickle(self, index: int):
        fault = self.fault
        if not fault or self.fault_fired or fault.get("kind") != "trickle":
            return
        self.fault_fired = True
        interval = float(fault.get("interval", 1))
        until = time.time() + float(fault.get("seconds", 900))
        state = {"sent": 0, "started_at": time.time(), "last_at": None}
        self.record["trickle"] = state
        while time.time() < until:
            state["sent"] += 1
            self.emit({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": f"流れ続ける本文の {state['sent']} 番目。"}}, pace=False)
            state["last_at"] = time.time()
            time.sleep(interval)
        state["finished"] = True

    def fault_due(self, event: dict) -> bool:
        fault = self.fault
        if not fault or self.fault_fired or fault.get("kind") not in ("drop", "stall", "sse_error"):
            return False
        if "after_events" in fault:
            return self.events_sent >= int(fault["after_events"])
        wanted = fault.get("after", "text_delta")
        return (event.get("delta") or {}).get("type") == wanted

    def emit(self, event: dict, pace: bool = True):
        self.wfile.write(sse(event))
        self.wfile.flush()
        self.events_sent += 1
        if self.fault_due(event):
            self.fault_fired = True
            kind = self.fault["kind"]
            if kind == "stall":
                time.sleep(float(self.fault.get("seconds", 30)))
                raise ConnectionDropped()
            if kind == "sse_error":
                self.wfile.write(sse({"type": "error", "error": {"type": self.fault.get("type", "overloaded_error"), "message": "fake stream error"}}))
                self.wfile.flush()
                raise ConnectionDropped()
            raise ConnectionDropped()
        if pace:
            time.sleep(self.delay)

    def reply(self, status: int, payload: dict, headers: dict | None = None):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def write_log(self, stamp: str, record: dict):
        with lock:
            scenario = getattr(self, "scenario", None)
            target = self.log_dir / "scenarios" / scenario if scenario else self.log_dir
            target.mkdir(parents=True, exist_ok=True)
            name = self.log_name
            (target / name).write_text(json.dumps(record, ensure_ascii=False, indent=1))


def scrub(value):
    if isinstance(value, list):
        return [scrub(v) for v in value]
    if isinstance(value, dict):
        if value.get("type") == "base64" and "data" in value:
            digest = hashlib.sha256(value["data"].encode()).hexdigest()[:16]
            return {**value, "data": f"…({len(value['data'])} chars sha256={digest})"}
        return {k: scrub(v) for k, v in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--log-dir", default="/tmp/fake-anthropic")
    parser.add_argument("--tape-dir", default=None, help="録画の置き場所(既定 <log-dir>/tapes)")
    parser.add_argument("--upstream", default="https://api.anthropic.com", help="mode=record の転送先")
    parser.add_argument("--upstream-key-file", default=None, help="mode=record で使う API キーのファイル")
    args = parser.parse_args()
    Handler.log_dir = Path(args.log_dir)
    Control.tape_dir = Path(args.tape_dir) if args.tape_dir else Path(args.log_dir) / "tapes"
    Control.upstream = args.upstream
    Control.upstream_key_file = args.upstream_key_file
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"fake anthropic on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
