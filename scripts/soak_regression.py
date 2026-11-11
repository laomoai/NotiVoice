#!/usr/bin/env python3
"""NotiVoice V1.1.2 断网恢复 soak 回归（Mac mini M4，真实本地 Worker + 本地 D1）。

启动/停止本地 wrangler dev 制造真实服务中断；客户端侧用持久化 cursor + 待发队列 +
稳定 event_id 模拟 NotiVoice 客户端协议。断言：中断期间的消息不丢、恢复后补拉补发、
ACK 重试幂等、无 5xx、事件不重复。

用法：python3 scripts/soak_regression.py [总时长秒] [中断时长秒]
默认 300 秒总时长，在 25% / 65% 处各中断一次，每次 12 秒。
"""
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CF = ROOT / "cloudflare"
BASE = "http://localhost:8787"
API = os.environ.get("SOAK_API_TOKEN", "test_api_token_123")
ADM = os.environ.get("SOAK_ADMIN_TOKEN", "test_admin_token_456")
DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 300
OUTAGE = int(sys.argv[2]) if len(sys.argv) > 2 else 12
TICK = 2.0
OUTAGES_AT = (DURATION * 0.25, DURATION * 0.65)

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def req(method, path, token, body=None, timeout=6):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
    })
    def decode(raw, status):
        try:
            return status, json.loads(raw or b"{}")
        except Exception:
            return status, {"_raw": (raw or b"")[:120].decode("utf-8", "replace")}

    try:
        with opener.open(r, timeout=timeout) as resp:
            return decode(resp.read(), resp.status)
    except urllib.error.HTTPError as e:
        return decode(e.read(), e.code)
    except Exception as e:
        return 0, {"error": str(e)}


def start_worker(log):
    p = subprocess.Popen(["npx", "wrangler", "dev", "--port", "8787"], cwd=CF,
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        code, _ = req("GET", "/", API, timeout=3)
        if code == 200:
            return p, True
        time.sleep(0.5)
    return p, False


def stop_worker(p):
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        pass
    try:
        p.wait(timeout=10)
    except Exception:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception:
            pass


def drain(cursor, pending_posts, pending_acks, stats):
    """一次完整的 拉取 → 补发 POST → 回执 循环；网络失败时保留待办。"""
    # 1) 补发中断期间未确认的 POST（同 external_id，服务端幂等）
    for item in list(pending_posts):
        code, body = req("POST", "/api/notifications", API, item)
        if code in (200, 201) and body.get("ok"):
            pending_posts.remove(item)
            if not body.get("duplicate"):
                stats["created"].add(body["seq"])
        else:
            stats["post_retries_failed"] += 1

    # 2) 增量拉取
    code, body = req("GET", f"/api/notifications?after={cursor}&limit=50", API)
    if code != 200:
        stats["poll_failures"] += 1
        return cursor
    msgs = body.get("messages", [])
    for m in msgs:
        stats["fetched"].add(m["seq"])
        mid = m["id"]
        seq = m["seq"]
        for status, ev in (("received", f"soak-recv-{seq}"), ("played", f"soak-play-{seq}")):
            pending_acks.append({"device_id": "devSoak", "message_id": mid,
                                 "status": status, "event_id": ev})
        cursor = max(cursor, seq)

    # 3) 补发回执（稳定 event_id，超时重试幂等）
    for item in list(pending_acks):
        code, body = req("POST", "/api/notifications/ack", API, item)
        if code == 200 and body.get("ok"):
            pending_acks.remove(item)
            stats["event_ids"].add(item["event_id"])
            if body.get("duplicate"):
                stats["ack_duplicates"] += 1
        elif code >= 500:
            stats["server_5xx"] += 1
        else:
            stats["ack_retries_failed"] += 1
    return cursor


def main():
    log_path = ROOT / "cloudflare" / "tmp" / "soak-worker.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    stats = {"created": set(), "fetched": set(), "event_ids": set(),
             "poll_failures": 0, "post_retries_failed": 0, "ack_retries_failed": 0,
             "ack_duplicates": 0, "server_5xx": 0, "outages": 0, "recovery_seconds": []}
    cursor, pending_posts, pending_acks = 0, [], []
    start = time.monotonic()
    outage_done = set()
    worker = None
    with open(log_path, "w") as log:
        try:
            worker, ready = start_worker(log)
            if not ready:
                print(json.dumps({"error": "worker 未就绪", "log": str(log_path)}, ensure_ascii=False))
                return 2
            req("POST", "/api/admin/notifications/clear", ADM, {})

            seq_no = 0
            while time.monotonic() - start < DURATION:
                elapsed = time.monotonic() - start
                for idx, at in enumerate(OUTAGES_AT):
                    if idx not in outage_done and elapsed >= at:
                        outage_done.add(idx)
                        stats["outages"] += 1
                        print(f"[outage {idx + 1}] 停止 Worker，模拟断网 {OUTAGE}s", flush=True)
                        stop_worker(worker)
                        worker = None
                        t0 = time.monotonic()
                        # 断网期间客户端继续尝试：POST 入待发队列、拉取/回执失败保留
                        while time.monotonic() - t0 < OUTAGE:
                            seq_no += 1
                            pending_posts.append({"source": "soak",
                                                  "external_id": f"soak-{DURATION}-{seq_no}",
                                                  "title": "soak", "content": "断网期间消息",
                                                  "priority": "normal"})
                            drain(cursor, pending_posts, pending_acks, stats)
                            time.sleep(TICK)
                        worker, ready = start_worker(log)
                        if not ready:
                            print(json.dumps({"error": "恢复后 Worker 未就绪"}, ensure_ascii=False))
                            return 2
                        stats["recovery_seconds"].append(round(time.monotonic() - t0, 1))
                        print(f"[outage {idx + 1}] Worker 已恢复，开始补拉补发", flush=True)

                seq_no += 1
                item = {"source": "soak", "external_id": f"soak-{DURATION}-{seq_no}",
                        "title": "soak", "content": "soak", "priority": "normal"}
                code, body = req("POST", "/api/notifications", API, item)
                if code in (200, 201) and body.get("ok"):
                    stats["created"].add(body["seq"])
                else:
                    pending_posts.append(item)
                cursor = drain(cursor, pending_posts, pending_acks, stats)
                time.sleep(TICK)

            # 结束前给一次完整排水窗口
            t_drain = time.monotonic()
            while time.monotonic() - t_drain < 15 and (pending_posts or pending_acks):
                cursor = drain(cursor, pending_posts, pending_acks, stats)
                time.sleep(1)
            cursor = drain(cursor, pending_posts, pending_acks, stats)
        finally:
            if worker is not None:
                stop_worker(worker)

    elapsed = round(time.monotonic() - start, 1)
    created, fetched = stats["created"], stats["fetched"]
    missing = sorted(created - fetched)
    result = {
        "duration_sec": elapsed,
        "outages": stats["outages"],
        "recovery_seconds": stats["recovery_seconds"],
        "created": len(created),
        "fetched": len(fetched),
        "missing_after_recovery": missing,
        "distinct_event_ids": len(stats["event_ids"]),
        "pending_posts_left": len(pending_posts),
        "pending_acks_left": len(pending_acks),
        "poll_failures": stats["poll_failures"],
        "ack_retries_failed": stats["ack_retries_failed"],
        "post_retries_failed": stats["post_retries_failed"],
        "ack_duplicates": stats["ack_duplicates"],
        "server_5xx": stats["server_5xx"],
    }
    ok = (not missing and not pending_posts and not pending_acks
          and stats["server_5xx"] == 0 and len(created) == len(fetched)
          and len(stats["event_ids"]) == len(fetched) * 2)
    result["result"] = "ALL PASS" if ok else "HAS FAILURES"
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
