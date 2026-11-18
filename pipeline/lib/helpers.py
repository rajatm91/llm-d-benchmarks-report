"""Small string helpers for deploy.sh that are awkward in bash. Usage: python3 helpers.py <command> [args]"""
import json
import os
import re
import shlex
import sys


def relpath(path, start):
    """kustomize refuses absolute resource paths."""
    return os.path.relpath(path, start)


def re_escape(text):
    """Literal text inside a yq regex."""
    return re.escape(text)


def reference_model(label):
    """The overlay's model: <org>/<label> inside the vLLM commands on stdin (one JSON string per line)."""
    pattern = r"[A-Za-z0-9_.-]+/" + re.escape(label) + r"(?![A-Za-z0-9_.-])"
    found = {m for line in sys.stdin for m in re.findall(pattern, json.loads(line))}
    return "\n".join(sorted(found))


def speculative_config(config_json, draft_model):
    """--speculative-config value: the profile's speculativeConfig plus the draft model, compact JSON."""
    config = json.loads(config_json)
    if draft_model:
        config["model"] = draft_model
    return json.dumps(config, separators=(",", ":"))


def shell_args(args_json):
    """A JSON list of flags as shell words, with $ doubled for Kubernetes' $(VAR) expansion."""
    return " ".join(shlex.quote(a) for a in json.loads(args_json)).replace("$", "$$")


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    print(globals()[command.replace("-", "_")](*args))
