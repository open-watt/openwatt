"""Index timestamped relay JSONL alongside app actions, retaining unknown traffic.

This is a private capture report: module replies can contain WLAN credentials.
Temporal screen associations and outstanding-request reply candidates are not semantic proof.
"""

import argparse
import bisect
import collections
import hashlib
import json
from pathlib import Path

from goodwe_capture import classify


def report(wire_path, actions_path=None):
    wire_path = Path(wire_path)
    rows = [json.loads(line) for line in wire_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    actions = [] if not actions_path else [json.loads(line) for line in Path(actions_path).read_text(encoding="utf-8").splitlines() if line.strip()]
    actions.sort(key=lambda row: row["time_ns"])
    times = [row["time_ns"] for row in actions]
    groups = {}
    pending = collections.defaultdict(list)
    unmatched = []
    for index, row in enumerate(rows):
        data = bytes.fromhex(row["data"])
        row["classification"] = classify(data)
        if row["direction"] == "app":
            action_index = bisect.bisect_right(times, row["time_ns"]) - 1
            group = groups.setdefault(data.hex(), dict(request=data.hex(), classification=classify(data), occurrences=0, action_labels=[], response_candidates={}, withheld=0))
            group["occurrences"] += 1
            group.setdefault("first_seen_ns", row["time_ns"])
            group["last_seen_ns"] = row["time_ns"]
            if action_index >= 0 and actions[action_index]["label"] not in group["action_labels"]:
                group["action_labels"].append(actions[action_index]["label"])
        elif row["direction"] == "withheld":
            groups[data.hex()]["withheld"] += 1
        elif row["direction"] == "upstream-tx":
            pending[tuple(row["peer"])].append((index, row))
        elif row["direction"] == "upstream-rx":
            queue = pending[tuple(row["peer"])]
            if len(queue) != 1:
                unmatched.append(dict(row_index=index, reason="No unique outstanding request for this endpoint", pending_count=len(queue)))
                queue.clear()
                continue
            _, request = queue.pop()
            candidate = groups[request["data"]]["response_candidates"].setdefault(data.hex(), dict(occurrences=0, classification=classify(data)))
            candidate["occurrences"] += 1
            candidate["last_round_trip_ns"] = row["time_ns"] - request["time_ns"]
    unresolved = sum(len(queue) for queue in pending.values())
    return dict(schema_version=1, input=str(wire_path), sha256=hashlib.sha256(wire_path.read_bytes()).hexdigest(),
                limits="Private report; may contain credentials. Screen labels are temporal associations only. Replies are candidates only when one request is outstanding; ambiguous replies are retained in events. Missing replies do not prove unsupported operations.",
                event_count=len(rows), app_request_count=sum(group["occurrences"] for group in groups.values()),
                unique_requests=len(groups), pending_requests_at_end=unresolved, unmatched_responses=unmatched,
                interactions=list(groups.values()), actions=actions, events=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wire_jsonl")
    parser.add_argument("--actions")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = report(args.wire_jsonl, args.actions)
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"{result['app_request_count']} app requests, {result['unique_requests']} distinct requests; {len(result['unmatched_responses'])} ambiguous/unmatched replies; private report saved")
