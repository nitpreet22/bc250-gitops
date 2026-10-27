#!/usr/bin/env python3
"""pod-requests: applies dev pods' safe requests for changes to their own pod (README "Pod requests").

A dev pod asks by committing `.homelab/pod.yaml` to its project repo's default branch:

    packages: [postgresql-server]   # Fedora 44 packages, built into the pod's image
    cpu: "6"                        # CPU limit of the agent container (at most 8)
    memory: 6Gi                     # memory limit of the agent container (at most 8 GiB)
    env:                            # plain environment variables; never secrets
      LOG_LEVEL: debug

A request is applied automatically only when every field stays inside the pod's sandbox (no new
network access, Secrets, RBAC, devices or host access are expressible here at all) and within the
ceilings and the namespace quota. Anything else is left for the owner, who is told on Discord.

Runs on bc250-2 from a systemd timer (bootstrap/06-pod-requests.sh), as the board's normal user,
with its own clone of homelab. For each dev pod, every run:
  1. reads the request (none: removes an earlier pod-request component, back to the defaults);
  2. decides "apply" or "review" (evaluate_request, which has no side effects);
  3. apply: builds the project image when packages are listed, writes the kustomize Component
     apps/<ns>/<project>/pod-request/ and lists it in the overlay, checks the result with
     kustomize and a server-side dry run, and, once herdr-core shows the agent isn't working, commits
     and pushes homelab main and asks Flux to reconcile. If the new pod doesn't become ready, the
     commit is reverted;
  4. writes the outcome to pod-request.yaml on the project repo's `homelab-status` branch, which
     the agent reads with `git fetch origin homelab-status && git show FETCH_HEAD:pod-request.yaml`.

Credentials: a Forgejo token in ~/.config/pod-requests/token (repository read/write; never
printed) and the board's cluster-admin kubeconfig. `--dry-run` reports decisions and changes
nothing.
"""

import argparse
import base64
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

import yaml

# ---- Configuration -------------------------------------------------------------------------------

CEILING_CPU_MILLI = 8000                  # 8 CPU
CEILING_MEMORY_BYTES = 8 * 2**30          # 8 GiB
MAX_PACKAGES = 30
MAX_ENV_VARS = 30
MAX_ENV_VALUE_LENGTH = 500

REQUEST_PATH = ".homelab/pod.yaml"
STATUS_BRANCH = "homelab-status"
STATUS_PATH = "pod-request.yaml"
COMPONENT_DIR = "pod-request"             # inside the project's overlay folder

FORGEJO = "http://127.0.0.1:30300"        # Forgejo's HTTP NodePort on this board
FORGEJO_PUBLIC = "http://192.168.1.106:30300"   # the same, as links for the owner
HOMELAB_REPO = "nitpreet22/homelab"
REGISTRY_PUSH = "192.168.1.106:30500"     # where podman pushes (infrastructure/registry)
REGISTRY_PULL = "registry.homelab.lan"    # how manifests name the same registry
AGENT_TEMPLATE = "templates/agent/deployment.yaml"

STATE_DIR = Path.home() / ".local/state/pod-requests"
CLONE_DIR = Path.home() / ".local/share/pod-requests/homelab"
TOKEN_FILE = Path.home() / ".config/pod-requests/token"

KUBECTL = ["kubectl", "--context", "homelab"]
ROLLOUT_TIMEOUT_SECONDS = 600

ENV_NAME = re.compile(r"^[A-Z_][A-Z0-9_]{0,63}$")
# Names that look like credentials: those belong in a SOPS Secret, which needs the owner.
SECRET_LIKE_NAME = re.compile(r"KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE")
# Names the platform sets or the shell depends on, besides every name the pod already defines.
RESERVED_ENV_NAMES = {"PATH", "HOME", "USER", "SHELL", "HOSTNAME", "KUBECONFIG"}
RESERVED_ENV_PREFIXES = ("CLAUDE_", "HL_", "KUBERNETES_")
PACKAGE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$")
KNOWN_FIELDS = {"packages", "cpu", "memory", "env"}


# ---- Kubernetes quantities -----------------------------------------------------------------------

_QUANTITY_SUFFIXES = {
    "": 1, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
    "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40,
}


def parse_quantity(value) -> float:
    """Kubernetes quantity ("6", "500m", "6Gi", 3221225472) as a number of base units.
    Raises ValueError for anything else."""
    match = re.fullmatch(r"(\d+(?:\.\d+)?)(m|k|M|G|T|Ki|Mi|Gi|Ti)?", str(value).strip())
    if not match:
        raise ValueError(f"not a Kubernetes quantity: {value!r}")
    return float(match.group(1)) * _QUANTITY_SUFFIXES[match.group(2) or ""]


def cpu_milli(value) -> int:
    return round(parse_quantity(value) * 1000)


def memory_bytes(value) -> int:
    return round(parse_quantity(value))


# ---- Deciding ------------------------------------------------------------------------------------

@dataclass
class PodFacts:
    """What evaluate_request needs to know about the pod, gathered from the cluster."""
    project: str
    existing_env_names: set
    uses_agent_image: bool        # packages can only be added to the Fedora agent image
    running: bool
    current_cpu_milli: int        # the agent container's current limits
    current_memory_bytes: int
    quota_hard_cpu_milli: int | None = None    # the namespace quota (None: no quota)
    quota_used_cpu_milli: int = 0
    quota_hard_memory_bytes: int | None = None
    quota_used_memory_bytes: int = 0


@dataclass
class Decision:
    apply: bool
    reasons: list = field(default_factory=list)   # why it needs the owner (empty when applying)
    notes: list = field(default_factory=list)     # facts worth reporting either way
    packages: list = field(default_factory=list)
    cpu: str | None = None
    memory: str | None = None
    env: dict = field(default_factory=dict)


def evaluate_request(request, facts: PodFacts) -> Decision:
    """Decides whether a parsed request is applied automatically. No side effects."""
    reasons, notes = [], []
    if not isinstance(request, dict):
        return Decision(apply=False, reasons=[f"{REQUEST_PATH} must be a mapping of fields"])

    for name in sorted(set(request) - KNOWN_FIELDS):
        reasons.append(f"unknown field '{name}' (allowed: {', '.join(sorted(KNOWN_FIELDS))})")

    packages = _check_packages(request.get("packages", []), facts, reasons)
    cpu = _check_limit(request.get("cpu"), "cpu", cpu_milli, CEILING_CPU_MILLI, "8", reasons)
    memory = _check_limit(request.get("memory"), "memory", memory_bytes, CEILING_MEMORY_BYTES,
                          "8Gi", reasons)
    env = _check_env(request.get("env", {}), facts, reasons)
    if cpu is not None or memory is not None:
        _check_quota(cpu, memory, facts, reasons, notes)

    return Decision(apply=not reasons, reasons=reasons, notes=notes,
                    packages=packages, cpu=cpu, memory=memory, env=env)


def _check_packages(packages, facts, reasons) -> list:
    if not isinstance(packages, list) or not all(isinstance(p, str) for p in packages):
        reasons.append("packages must be a list of Fedora package names")
        return []
    if len(packages) > MAX_PACKAGES:
        reasons.append(f"at most {MAX_PACKAGES} packages per pod")
    for package in packages:
        if not PACKAGE_NAME.match(package):
            reasons.append(f"'{package}' is not a package name")
    if packages and not facts.uses_agent_image:
        reasons.append("packages can only be added to pods on the agent image; this pod has its "
                       "own image (images/<name>), so add them there")
    return sorted(set(packages))


def _check_limit(value, name, to_units, ceiling, ceiling_text, reasons) -> str | None:
    if value is None:
        return None
    try:
        units = to_units(value)
    except ValueError:
        reasons.append(f"{name}: {value!r} is not a Kubernetes quantity (e.g. {ceiling_text})")
        return None
    if units <= 0:
        reasons.append(f"{name} must be more than 0")
    if units > ceiling:
        reasons.append(f"{name} {value} is above the ceiling of {ceiling_text}")
    return str(value)


def _check_env(env, facts, reasons) -> dict:
    if not isinstance(env, dict):
        reasons.append("env must be a mapping of NAME: value")
        return {}
    if len(env) > MAX_ENV_VARS:
        reasons.append(f"at most {MAX_ENV_VARS} env variables")
    checked = {}
    for name, value in env.items():
        name = str(name)
        if not ENV_NAME.match(name):
            reasons.append(f"env {name}: names are UPPER_CASE letters, digits and _")
        elif SECRET_LIKE_NAME.search(name):
            reasons.append(f"env {name} looks like a secret; secrets go in a SOPS Secret, which the "
                           "owner adds")
        elif (name in RESERVED_ENV_NAMES or name.startswith(RESERVED_ENV_PREFIXES)
              or name in facts.existing_env_names):
            reasons.append(f"env {name} is set by the platform or the pod's overlay")
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            reasons.append(f"env {name}: the value must be a string or a number")
            continue
        text = str(value)
        if "\n" in text or len(text) > MAX_ENV_VALUE_LENGTH:
            reasons.append(f"env {name}: one line, at most {MAX_ENV_VALUE_LENGTH} characters")
        checked[name] = text
    return checked


def _check_quota(cpu, memory, facts, reasons, notes):
    """The namespace quota counts limits. A running pod is replaced (strategy Recreate), so its
    current limits come off before the new ones count. A stopped pod is applied either way; the
    note says whether it would fit right now."""
    for label, new, current, hard, used, show in (
        ("cpu", cpu and cpu_milli(cpu), facts.current_cpu_milli,
         facts.quota_hard_cpu_milli, facts.quota_used_cpu_milli, lambda m: f"{m / 1000:g} CPU"),
        ("memory", memory and memory_bytes(memory), facts.current_memory_bytes,
         facts.quota_hard_memory_bytes, facts.quota_used_memory_bytes,
         lambda b: f"{b / 2**30:.2f} GiB"),
    ):
        if not new or hard is None:
            continue
        total = used - (current if facts.running else 0) + new
        if total <= hard:
            continue
        message = (f"{label}: the namespace quota allows {show(hard)} of limits; with this request "
                   f"its pods would need {show(total)}")
        if facts.running:
            reasons.append(message)
        else:
            notes.append(message + " (the pod is stopped; it won't start until there is room)")


# ---- Rendering the component ---------------------------------------------------------------------

def request_fingerprint(decision: Decision, base_image_tag: str) -> str:
    """Short hash of what the request changes, so the pod restarts only when that changes."""
    content = json.dumps({"packages": decision.packages, "cpu": decision.cpu,
                          "memory": decision.memory, "env": decision.env,
                          "base": base_image_tag if decision.packages else None}, sort_keys=True)
    return hashlib.sha256(content.encode()).hexdigest()[:12]


def project_image(project: str, packages: list, base_image_tag: str) -> tuple[str, str]:
    """(image name, tag) of a project's agent image with extra packages. The tag changes with the
    base image and the package list, so a rebuilt agent image rebuilds the project's too."""
    digest = hashlib.sha256(" ".join(packages).encode()).hexdigest()[:8]
    return f"pod-{project}", f"{base_image_tag}-{digest}"


def render_containerfile(base_image_tag: str, packages: list, source: str) -> str:
    return (f"# Written by scripts/pod-requests.py for {source}.\n"
            f"FROM {REGISTRY_PUSH}/agent:{base_image_tag}\n"
            "USER root\n"
            "RUN dnf -y install --setopt=install_weak_deps=False \\\n"
            f"      {' '.join(packages)} \\\n"
            "    && dnf clean all\n"
            "USER 10000\n")


def render_component(decision: Decision, fingerprint: str, image: str | None, source: str) -> str:
    container = {"name": "agent"}
    if image:
        container["image"] = image
    limits = {key: value for key, value in (("cpu", decision.cpu), ("memory", decision.memory))
              if value is not None}
    if limits:
        container["resources"] = {"limits": limits}
    merge_patch = {
        "apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "agent"},
        "spec": {"template": {
            "metadata": {"annotations": {"homelab.lan/pod-request": fingerprint}},
            "spec": {"containers": [container]},
        }},
    }
    target = {"kind": "Deployment", "name": "agent"}
    patches = [{"target": target, "patch": yaml.safe_dump(merge_patch, sort_keys=False)}]
    if decision.env:
        # Env entries are appended with JSON patch ops: a strategic merge would put new entries
        # first, and the overlays patch REPO_URL and REPO_DIR by position (env/1, env/2).
        appends = [{"op": "add", "path": "/spec/template/spec/containers/0/env/-",
                    "value": {"name": name, "value": value}}
                   for name, value in sorted(decision.env.items())]
        patches.append({"target": target, "patch": yaml.safe_dump(appends, sort_keys=False)})
    component = {"apiVersion": "kustomize.config.k8s.io/v1alpha1", "kind": "Component",
                 "patches": patches}
    header = (f"# Written by scripts/pod-requests.py from {source}.\n"
              "# Don't edit: the next run rewrites it. Change the request instead, or delete it to\n"
              "# go back to the template's defaults.\n")
    return header + yaml.safe_dump(component, sort_keys=False)


def add_component_to_overlay(text: str) -> str:
    """Lists the pod-request component last in an overlay's kustomization.yaml (last, so it wins
    over the overlay's other components). Plain text edit, so the file's comments survive."""
    entry = f"  - {COMPONENT_DIR}"
    lines = text.splitlines()
    if entry in lines:
        return text
    if "components:" not in lines:
        return text.rstrip("\n") + f"\ncomponents:\n{entry}\n"
    end = lines.index("components:") + 1
    while end < len(lines) and (lines[end].startswith("  - ") or lines[end].startswith("  #")):
        end += 1
    lines.insert(end, entry)
    return "\n".join(lines) + "\n"


def remove_component_from_overlay(text: str) -> str:
    lines = [line for line in text.splitlines() if line != f"  - {COMPONENT_DIR}"]
    # An empty components: list left behind is invalid kustomize; drop the key too.
    cleaned = []
    for index, line in enumerate(lines):
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if line == "components:" and not following.startswith("  "):
            continue
        cleaned.append(line)
    return "\n".join(cleaned) + "\n"


# ---- Side effects: commands, Forgejo, the cluster ------------------------------------------------

def run(args, **kwargs) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def kubectl_json(*args):
    return json.loads(run([*KUBECTL, *args, "-o", "json"]))


class Forgejo:
    def __init__(self, token: str):
        self.headers = {"Authorization": f"token {token}", "Content-Type": "application/json"}

    def call(self, method, path, body=None):
        request = urllib.request.Request(f"{FORGEJO}/api/v1{path}", method=method,
                                         headers=self.headers,
                                         data=json.dumps(body).encode() if body else None)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise

    def read_file(self, repo, path, ref=None):
        """(text, blob sha) of a file, or (None, None) when it doesn't exist."""
        query = f"?ref={ref}" if ref else ""
        found = self.call("GET", f"/repos/{repo}/contents/{path}{query}")
        if not found or found.get("type") != "file":
            return None, None
        return base64.b64decode(found["content"]).decode(), found["sha"]

    def write_status(self, repo, text):
        """Writes STATUS_PATH on STATUS_BRANCH (created from the default branch if needed)."""
        if self.call("GET", f"/repos/{repo}/branches/{STATUS_BRANCH}") is None:
            default = self.call("GET", f"/repos/{repo}")["default_branch"]
            self.call("POST", f"/repos/{repo}/branches",
                      {"new_branch_name": STATUS_BRANCH, "old_branch_name": default})
        old_text, sha = self.read_file(repo, STATUS_PATH, STATUS_BRANCH)
        if old_text == text:
            return
        body = {"branch": STATUS_BRANCH, "message": "pod-requests: status",
                "content": base64.b64encode(text.encode()).decode()}
        if sha:
            self.call("PUT", f"/repos/{repo}/contents/{STATUS_PATH}", {**body, "sha": sha})
        else:
            self.call("POST", f"/repos/{repo}/contents/{STATUS_PATH}", body)


class HomelabClone:
    """This program's own clone of homelab. Every run starts from origin/main; nothing else
    works in it."""

    def __init__(self, token):
        auth = f"Authorization: token {token}"
        # The token goes through git's environment config, never the command line.
        self.env = {**os.environ, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader",
                    "GIT_CONFIG_VALUE_0": auth, "GIT_TERMINAL_PROMPT": "0"}

    def git(self, *args) -> str:
        return run(["git", "-C", str(CLONE_DIR), *args], env=self.env)

    def sync(self):
        if not (CLONE_DIR / ".git").exists():
            CLONE_DIR.parent.mkdir(parents=True, exist_ok=True)
            run(["git", "clone", "-q", f"{FORGEJO}/{HOMELAB_REPO}.git", str(CLONE_DIR)],
                env=self.env)
            self.git("config", "user.name", "pod-requests")
            self.git("config", "user.email", "pod-requests@bc250-2.homelab.lan")
        self.git("fetch", "-q", "origin")
        self.git("reset", "-q", "--hard", "origin/main")
        self.git("clean", "-qfd")

    def commit_and_push(self, paths, message) -> str:
        self.git("add", "-A", "--", *paths)
        self.git("commit", "-q", "-m", message)
        self.push_main()
        return self.git("rev-parse", "--short", "HEAD").strip()

    def push_main(self):
        for _ in range(3):
            try:
                self.git("push", "-q", "origin", "HEAD:main")
                return
            except subprocess.CalledProcessError:
                # main moved (the PC pushed): replay this commit on top and try again.
                self.git("pull", "-q", "--rebase", "origin", "main")
        raise RuntimeError("couldn't push to homelab main after 3 tries")


def find_overlays(clone: Path) -> dict:
    """project -> overlay folder, for every overlay built on templates/agent (dev pods)."""
    overlays = {}
    for path in sorted((clone / "apps").rglob("kustomization.yaml")):
        try:
            data = yaml.safe_load(path.read_text()) or {}
        except yaml.YAMLError:
            continue
        if not any(str(r).endswith("templates/agent") for r in data.get("resources") or []):
            continue
        for label in data.get("labels") or []:
            project = (label.get("pairs") or {}).get("homelab.lan/project")
            if project:
                overlays[project] = path.parent
    return overlays


def agent_image_tag(clone: Path) -> str:
    match = re.search(rf"{re.escape(REGISTRY_PULL)}/agent:(\S+)",
                      (clone / AGENT_TEMPLATE).read_text())
    return match.group(1)


def live_dev_pods() -> dict:
    """project -> facts about its live Deployment."""
    pods = {}
    deployments = kubectl_json("get", "deploy", "-A", "-l", "homelab.lan/component=dev-pod")
    for item in deployments["items"]:
        project = item["metadata"]["labels"]["homelab.lan/project"]
        containers = item["spec"]["template"]["spec"]["containers"]
        agent = next(c for c in containers if c["name"] == "agent")
        env = {e["name"]: e.get("value") for e in agent.get("env", [])}
        pods[project] = {
            "namespace": item["metadata"]["namespace"],
            "name": item["metadata"]["name"],
            "replicas": item["spec"].get("replicas", 1),
            "image": agent["image"],
            "env": env,
            "limits": agent.get("resources", {}).get("limits", {}),
            "annotation": (item["spec"]["template"]["metadata"].get("annotations") or {})
            .get("homelab.lan/pod-request"),
        }
    return pods


def gather_facts(project, pod, env_names_from_requests) -> PodFacts:
    # Names an earlier request added are the request's own, not the platform's.
    existing = set(pod["env"]) - set(env_names_from_requests)
    facts = PodFacts(
        project=project, existing_env_names=existing,
        uses_agent_image=pod["image"].startswith((f"{REGISTRY_PULL}/agent:",
                                                  f"{REGISTRY_PULL}/pod-{project}:")),
        running=pod["replicas"] > 0,
        current_cpu_milli=cpu_milli(pod["limits"].get("cpu", "0")),
        current_memory_bytes=memory_bytes(pod["limits"].get("memory", "0")),
    )
    for quota in kubectl_json("-n", pod["namespace"], "get", "resourcequota")["items"]:
        hard, used = quota["status"].get("hard", {}), quota["status"].get("used", {})
        if "limits.cpu" in hard:
            facts.quota_hard_cpu_milli = cpu_milli(hard["limits.cpu"])
            facts.quota_used_cpu_milli = cpu_milli(used.get("limits.cpu", "0"))
        if "limits.memory" in hard:
            facts.quota_hard_memory_bytes = memory_bytes(hard["limits.memory"])
            facts.quota_used_memory_bytes = memory_bytes(used.get("limits.memory", "0"))
    return facts


BUSY_STATES = ("working", "blocked")


def agent_is_busy(project) -> bool:
    """True while herdr-core shows the project's agent working or waiting on the owner. A restart
    then would cut it off mid-task; the next run tries again. hl runs each project in a herdr-core
    terminal labelled hl.tab=<project>, where Claude Code reports its own status (OSC 7501)."""
    try:
        listed = json.loads(run(["hc", "ls", "--json", "--label", f"hl.tab={project}"]))["terminals"]
        terminals = [json.loads(run(["hc", "get", "--json", t["address"]])) for t in listed]
    except (OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError):
        return False      # no herdr-core: nothing to wait for
    return any_terminal_busy(terminals)


def any_terminal_busy(terminals) -> bool:
    """True when any of these `hc get` records reports working or blocked. A terminal without a
    status (a plain program, or Claude Code before it first reports) counts as not busy."""
    return any((terminal.get("status") or {}).get("state") in BUSY_STATES for terminal in terminals)


def image_exists(name, tag) -> bool:
    try:
        with urllib.request.urlopen(urllib.request.Request(
                f"http://{REGISTRY_PUSH}/v2/{name}/manifests/{tag}", method="HEAD",
                headers={"Accept": "application/vnd.oci.image.manifest.v1+json, "
                                   "application/vnd.docker.distribution.manifest.v2+json"}),
                timeout=15):
            return True
    except urllib.error.HTTPError:
        return False


def build_image(context_dir: Path, name, tag):
    # bootstrap/podman-build.sh is how every homelab image is built and pushed (as root).
    run(["sudo", "-n", "bash", str(CLONE_DIR / "bootstrap/podman-build.sh"), str(context_dir),
         name, tag])


def check_overlay(overlay: Path, fingerprint):
    """Builds the overlay and dry-runs its Deployment on the API server, which runs the admission
    policies. Raises with the reason on failure."""
    rendered = list(yaml.safe_load_all(run(["kubectl", "kustomize", str(overlay)])))
    deployment = next(d for d in rendered if d and d.get("kind") == "Deployment")
    annotation = (deployment["spec"]["template"]["metadata"].get("annotations") or {}) \
        .get("homelab.lan/pod-request")
    if annotation != fingerprint:
        raise RuntimeError("the overlay overrides the request (its own patch sets the same fields)")
    run([*KUBECTL, "apply", "--server-side", "--dry-run=server", "--force-conflicts",
         "--field-manager=pod-requests", "-f", "-"], input=yaml.safe_dump(deployment))


def reconcile_flux():
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for kind, name in (("gitrepository", "flux-system"), ("kustomization", "apps")):
        run([*KUBECTL, "-n", "flux-system", "annotate", "--overwrite", kind, name,
             f"reconcile.fluxcd.io/requestedAt={now}"])


def wait_for_rollout(pod, fingerprint) -> str | None:
    """Waits until Flux applied the change and, if the pod runs, until the new pod is ready.
    Returns None on success, or what went wrong."""
    deadline = time.time() + ROLLOUT_TIMEOUT_SECONDS
    while time.time() < deadline:
        live = kubectl_json("-n", pod["namespace"], "get", "deploy", pod["name"])
        annotations = live["spec"]["template"]["metadata"].get("annotations") or {}
        if annotations.get("homelab.lan/pod-request") == (fingerprint or None):
            break
        time.sleep(10)
    else:
        return "Flux didn't apply the change within 10 minutes"
    if pod["replicas"] == 0:
        return None
    try:
        run([*KUBECTL, "-n", pod["namespace"], "rollout", "status", "deploy", pod["name"],
             f"--timeout={ROLLOUT_TIMEOUT_SECONDS}s"])
        return None
    except subprocess.CalledProcessError as error:
        return f"the new pod didn't become ready: {(error.stdout or error.stderr).strip()[-300:]}"


def notify_owner(text):
    """Posts to the Discord webhook in personal/discord-webhook, if there is one."""
    try:
        secret = kubectl_json("-n", "personal", "get", "secret", "discord-webhook")
        url = base64.b64decode(secret["data"]["url"]).decode().strip()
        urllib.request.urlopen(urllib.request.Request(
            url, data=json.dumps({"content": text[:1900]}).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "pod-requests"}),
            timeout=15)
    except Exception as error:   # a missed notification must never stop the run
        print(f"  (Discord notification failed: {error})")


# ---- One project ---------------------------------------------------------------------------------

def status_text(outcome, request_sha, reasons=(), notes=(), commit=None) -> str:
    status = {"request": request_sha, "outcome": outcome}
    if reasons:
        status["needs_owner_because"] = list(reasons)
    if notes:
        status["notes"] = list(notes)
    if commit:
        status["homelab_commit"] = commit
    return ("# Written by homelab's pod-requests (bc250-2) about .homelab/pod.yaml on the default\n"
            "# branch. outcome: applied | unchanged | review | waiting | failed | reverted |\n"
            "# defaults (no request: the pod is back on the template's defaults).\n"
            + yaml.safe_dump(status, sort_keys=False))


def component_env_names(component: Path) -> set:
    """Env names an earlier request added (they are the request's, not the platform's)."""
    path = component / "kustomization.yaml"
    if not path.exists():
        return set()
    names = set()
    for entry in yaml.safe_load(path.read_text())["patches"]:
        patch = yaml.safe_load(entry["patch"])
        if isinstance(patch, list):   # the env appends (JSON patch ops)
            names.update(op["value"]["name"] for op in patch if op.get("op") == "add")
    return names


def is_empty(decision: Decision) -> bool:
    return not (decision.packages or decision.cpu or decision.memory or decision.env)


class Runner:
    def __init__(self, dry_run):
        self.dry_run = dry_run
        token = TOKEN_FILE.read_text().strip()
        self.forgejo = Forgejo(token)
        self.clone = HomelabClone(token)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.notified_file = STATE_DIR / "notified.json"
        self.notified = (json.loads(self.notified_file.read_text())
                         if self.notified_file.exists() else {})

    def report(self, repo, project, request_sha, outcome, reasons=(), notes=(), commit=None,
               notify=None):
        """Records the outcome on the project's status branch and, for `notify`, tells the owner
        once per request."""
        print(f"  {outcome}" + "".join(f"\n    - {line}" for line in [*reasons, *notes]))
        if self.dry_run:
            return
        self.forgejo.write_status(repo, status_text(outcome, request_sha, reasons, notes, commit))
        if notify and self.notified.get(project) != request_sha:
            notify_owner(f"Pod request from **{project}** {notify}:\n- " + "\n- ".join(reasons)
                         + f"\n{FORGEJO_PUBLIC}/{repo}/src/branch/{STATUS_BRANCH}/{STATUS_PATH}")
            self.notified[project] = request_sha
            self.notified_file.write_text(json.dumps(self.notified))

    def handle(self, project, overlay: Path, pod, base_tag):
        match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", pod["env"].get("REPO_URL") or "")
        if not match:
            print(f"{project}: no REPO_URL, skipped")
            return
        repo = match.group(1)
        component = overlay / COMPONENT_DIR
        request_text, request_sha = self.forgejo.read_file(repo, REQUEST_PATH)
        print(f"{project} ({repo}): "
              + (f"request {request_sha[:8]}" if request_sha else "no request"))

        try:
            request = yaml.safe_load(request_text) if request_text is not None else {}
        except yaml.YAMLError as error:
            self.report(repo, project, request_sha, "review",
                        [f"{REQUEST_PATH} isn't valid YAML: {error}"], notify="needs you")
            return
        facts = gather_facts(project, pod, component_env_names(component))
        decision = evaluate_request(request or {}, facts)
        if not decision.apply:
            self.report(repo, project, request_sha, "review", decision.reasons, decision.notes,
                        notify="needs you")
            return

        # No request (or an empty one) means the template's defaults.
        if is_empty(decision):
            if component.exists() and not self.wait_for_idle(repo, project, request_sha, []):
                self.apply(repo, project, overlay, pod, request_sha, None, None,
                           f"{project}: back to the template's defaults (request removed)")
            return

        fingerprint = request_fingerprint(decision, base_tag)
        if pod["annotation"] == fingerprint:
            self.report(repo, project, request_sha, "unchanged", notes=decision.notes)
            return
        if self.wait_for_idle(repo, project, request_sha, decision.notes):
            return
        source = f"{repo}@{request_sha[:8]}:{REQUEST_PATH}"
        self.apply(repo, project, overlay, pod, request_sha, decision, fingerprint,
                   f"{project}: pod request {request_sha[:8]} ({describe(decision)})",
                   base_tag=base_tag, source=source)

    def wait_for_idle(self, repo, project, request_sha, notes) -> bool:
        """True (and reports "waiting") while the agent is busy; the next run tries again."""
        if not agent_is_busy(project):
            return False
        self.report(repo, project, request_sha, "waiting",
                    notes=[*notes, "applies when the agent is idle in herdr-core (the pod restarts)"])
        return True

    def apply(self, repo, project, overlay, pod, request_sha, decision, fingerprint, message,
              base_tag=None, source=None):
        component = overlay / COMPONENT_DIR
        kustomization = overlay / "kustomization.yaml"
        notes = decision.notes if decision else []
        try:
            if decision is None:
                for path in component.iterdir():
                    path.unlink()
                component.rmdir()
                kustomization.write_text(remove_component_from_overlay(kustomization.read_text()))
                run(["kubectl", "kustomize", str(overlay)])
            else:
                component.mkdir(parents=True, exist_ok=True)
                for path in component.iterdir():
                    path.unlink()
                image = None
                if decision.packages:
                    name, tag = project_image(project, decision.packages, base_tag)
                    (component / "Containerfile").write_text(
                        render_containerfile(base_tag, decision.packages, source))
                    if not self.dry_run and not image_exists(name, tag):
                        print(f"  building {name}:{tag}")
                        build_image(component, name, tag)
                    image = f"{REGISTRY_PULL}/{name}:{tag}"
                (component / "kustomization.yaml").write_text(
                    render_component(decision, fingerprint, image, source))
                kustomization.write_text(add_component_to_overlay(kustomization.read_text()))
                check_overlay(overlay, fingerprint)
            if self.dry_run:
                self.report(repo, project, request_sha, "would apply", notes=notes)
                return
            paths = [str(component.relative_to(CLONE_DIR)),
                     str(kustomization.relative_to(CLONE_DIR))]
            commit = self.clone.commit_and_push(paths, f"pod-requests: {message}")
            print(f"  pushed {commit}")
            reconcile_flux()
            problem = wait_for_rollout(pod, fingerprint)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            detail = (getattr(error, "stderr", None) or str(error)).strip()[-500:]
            if request_sha:
                self.report(repo, project, request_sha, "failed", [f"couldn't apply: {detail}"],
                            notes, notify="failed")
            else:
                print(f"  failed: {detail}")
            return
        if problem is None:
            # No request: the pod is back on the template's defaults; say so, so an older
            # outcome on the status branch isn't left looking current.
            self.report(repo, project, request_sha, "applied" if request_sha else "defaults",
                        notes=notes, commit=commit)
            return
        self.clone.git("revert", "--no-edit", "HEAD")
        self.clone.push_main()
        reconcile_flux()
        if request_sha:
            self.report(repo, project, request_sha, "reverted", [problem], notes, commit=commit,
                        notify="was applied and reverted")
        else:
            print(f"  reverted: {problem}")

    def run_all(self, only=None):
        self.clone.sync()
        base_tag = agent_image_tag(CLONE_DIR)
        overlays = find_overlays(CLONE_DIR)
        pods = live_dev_pods()
        for project in sorted(set(overlays) & set(pods)):
            if only and project != only:
                continue
            try:
                self.handle(project, overlays[project], pods[project], base_tag)
            except Exception as error:   # one project's problem must not stop the others
                print(f"  error: {error!r}")
            finally:
                self.clone.sync()        # the next project starts from origin/main


def describe(decision: Decision) -> str:
    parts = []
    if decision.packages:
        parts.append("packages " + " ".join(decision.packages))
    if decision.cpu:
        parts.append(f"cpu {decision.cpu}")
    if decision.memory:
        parts.append(f"memory {decision.memory}")
    if decision.env:
        parts.append("env " + " ".join(sorted(decision.env)))
    return ", ".join(parts) or "no changes"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="decide and report; change nothing")
    parser.add_argument("--project", help="only this project")
    args = parser.parse_args()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_DIR / "lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("another run is in progress")
            return
        Runner(args.dry_run).run_all(args.project)


if __name__ == "__main__":
    sys.exit(main())
