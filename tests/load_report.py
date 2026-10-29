"""Per-node and per-pod numbers for a load-test window, from VictoriaMetrics (Phase 8).

    python tests/load_report.py <start unix time> <end unix time>

Asks vmsingle through `kubectl exec` (KUBECONFIG must point at the homelab), so nothing is
port-forwarded or exposed. Temperatures are checked against 06_bc250_server's limits: 80 °C is
the target under sustained load, 85 °C is where the SMU throttles.
"""
import json
import subprocess
import sys
import urllib.parse

TEMPERATURE_TARGET_C = 80
THROTTLE_C = 85


def query(expr: str, at: int) -> list[dict]:
    """Instant query at `at`; returns the result vector."""
    url = "http://127.0.0.1:8428/api/v1/query?" + urllib.parse.urlencode({"query": expr, "time": at})
    raw = subprocess.run(
        ["kubectl", "-n", "monitoring", "exec", "vmsingle-0", "--", "wget", "-qO-", url],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(raw)["data"]["result"]


def by_node(expr: str, at: int) -> dict[str, float]:
    return {r["metric"].get("node", "?"): float(r["value"][1]) for r in query(expr, at)}


def chip_temperature(chip_name: str) -> str:
    return (f'max by (node) (node_hwmon_temp_celsius * on (instance, chip) group_left (chip_name) '
            f'node_hwmon_chip_names{{chip_name="{chip_name}"}})')


def main(start: int, end: int) -> None:
    window = f"{end - start}s"
    # Busy = every mode except idle and iowait. (1 - idle) can go negative here: the idle
    # counter sometimes advances faster than wall time on these kernels.
    cpu_busy = ('100 * sum by (node) (rate(node_cpu_seconds_total{mode!~"idle|iowait"}[1m])) '
                '/ count by (node) (node_cpu_seconds_total{mode="idle"})')
    memory_used_gib = "max by (node) (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 2^30"
    lan0_rate = 'max by (node) (rate(node_network_{}_bytes_total{{device="lan0"}}[1m])) * 8 / 1e6'

    def lan0_increase(metric: str) -> str:
        return f'max by (node) ({metric}{{device="lan0"}} - {metric}{{device="lan0"}} offset {window})'

    rows = {
        "CPU busy avg %": by_node(f"avg_over_time(({cpu_busy})[{window}])", end),
        "CPU busy max %": by_node(f"max_over_time(({cpu_busy})[{window}])", end),
        "RAM used max GiB": by_node(f"max_over_time(({memory_used_gib})[{window}])", end),
        "RAM total GiB": by_node("max by (node) (node_memory_MemTotal_bytes) / 2^30", end),
        "CPU Tctl max C": by_node(f"max_over_time(({chip_temperature('k10temp')})[{window}])", end),
        "GPU edge max C": by_node(f"max_over_time(({chip_temperature('amdgpu')})[{window}])", end),
        "NVMe max C": by_node(f"max_over_time(({chip_temperature('nvme')})[{window}])", end),
        "GPU busy avg %": by_node(f"avg_over_time((max by (node) (node_drm_gpu_busy_percent))[{window}])", end),
        "lan0 rx max Mbit/s": by_node(f"max_over_time(({lan0_rate.format('receive')})[{window}])", end),
        "lan0 tx max Mbit/s": by_node(f"max_over_time(({lan0_rate.format('transmit')})[{window}])", end),
        "lan0 rx+tx errors": by_node(f"{lan0_increase('node_network_receive_errs_total')} + "
                                     f"{lan0_increase('node_network_transmit_errs_total')}", end),
        # rx drops tick at ~1/s on every board even when idle: frames for protocols the kernel
        # doesn't handle. NIC ring overruns would show as errors (fifo/overrun) instead.
        "lan0 rx drops": by_node(lan0_increase("node_network_receive_drop_total"), end),
        "lan0 tx drops": by_node(lan0_increase("node_network_transmit_drop_total"), end),
        "lan0 carrier changes": by_node(lan0_increase("node_network_carrier_changes_total"), end),
    }
    nodes = sorted({node for values in rows.values() for node in values})
    print(f"Window {start} to {end} ({end - start} s)\n")
    print(f"{'':22}" + "".join(f"{node:>10}" for node in nodes))
    for label, values in rows.items():
        print(f"{label:22}" + "".join(f"{values.get(node, float('nan')):>10.1f}" for node in nodes))

    for label in ("CPU Tctl max C", "GPU edge max C"):
        for node, celsius in rows[label].items():
            if celsius >= TEMPERATURE_TARGET_C:
                limit = "THROTTLE" if celsius >= THROTTLE_C else "over the 80 C target"
                print(f"!! {node} {label} {celsius:.0f} C: {limit}")

    print("\nPeak memory per pod (working set, top 25)")
    # cAdvisor series name the node in `instance`.
    pods = query(f'topk(25, max_over_time((sum by (instance, namespace, pod) '
                 f'(container_memory_working_set_bytes{{container!=""}}))[{window}]))', end)
    for r in sorted(pods, key=lambda r: -float(r["value"][1])):
        m = r["metric"]
        print(f"  {m.get('instance', '?'):8} {m.get('namespace', '?'):12} {m.get('pod', '?'):48} "
              f"{float(r['value'][1]) / 2**20:8.0f} MiB")

    restarts = query(f"sum by (exported_namespace, pod) (kube_pod_container_status_restarts_total - "
                     f"kube_pod_container_status_restarts_total offset {window}) > 0", end)
    print("\nContainer restarts in the window:", ", ".join(
        f"{r['metric'].get('exported_namespace')}/{r['metric'].get('pod')} +{float(r['value'][1]):.0f}"
        for r in restarts) or "none")


if __name__ == "__main__":
    main(int(sys.argv[1]), int(sys.argv[2]))
