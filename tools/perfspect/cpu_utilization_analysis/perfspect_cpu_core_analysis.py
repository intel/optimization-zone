#!/usr/bin/env python3
"""
Parse Intel PerfSpect CPU telemetry from either:

1. Processed PerfSpect JSON:
      contains "CPU Utilization Telemetry"

2. Raw PerfSpect JSON:
      contains ScriptOutputs["mpstat telemetry"]["Stdout"]

The tool generates logical-CPU and physical-core utilization summaries/charts.

Physical core dedup rule:
  Count one physical core per unique:
      (SOCK, NODE, CORE)

Example:
  CPU 0   -> SOCK=0, NODE=0, CORE=0
  CPU 128 -> SOCK=0, NODE=0, CORE=0

These two CPU IDs count as one physical CPU core.
"""

import argparse
import csv
import json
import math
import re
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


CPU_TELEMETRY_SECTION = "CPU Utilization Telemetry"
RAW_MPSTAT_KEY = "mpstat telemetry"


def to_float(value):
    if value is None:
        return float("nan")
    return float(str(value).replace(",", ""))


def avg(values):
    return sum(values) / len(values) if values else float("nan")


def parse_lscpu_summary(stdout):
    mapping = {}
    for line in stdout.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        mapping[key.strip()] = value.strip()

    return {
        "CPU Model": mapping.get("Model name"),
        "CPUs": mapping.get("CPU(s)"),
        "Cores per Socket": mapping.get("Core(s) per socket"),
        "Sockets": mapping.get("Socket(s)"),
        "NUMA Nodes": mapping.get("NUMA node(s)"),
        "Hyperthreading": (
            "Enabled"
            if mapping.get("Thread(s) per core") and mapping.get("Thread(s) per core") != "1"
            else "Disabled"
        ),
    }


def parse_mpstat_stdout(stdout):
    """
    Parse raw PerfSpect mpstat telemetry.

    Expected command in raw file:
      mpstat -u -T -I SCPU -P ALL <interval> <count>

    Expected columns:
      Time CPU CORE SOCK NODE %usr %nice %sys %iowait %irq %soft %steal %guest %gnice %idle

    The parser intentionally skips "Average:" rows to avoid double-counting
    interval samples.
    """
    rows = []
    header = None

    for line in stdout.splitlines():
        line = line.strip()

        if not line or line.startswith("Linux "):
            continue

        parts = line.split()

        if len(parts) >= 2 and parts[1] == "CPU" and "CORE" in parts and "%idle" in parts:
            header = ["Time"] + parts[1:]
            continue

        if header is None:
            continue

        if parts[0] == "Average:":
            continue

        if not re.match(r"^\d{2}:\d{2}:\d{2}$", parts[0]):
            continue

        if len(parts) > 1 and parts[1] == "all":
            continue

        if len(parts) < len(header):
            continue

        try:
            int(parts[1])
            int(parts[2])
            int(parts[3])
            int(parts[4])
        except ValueError:
            continue

        parsed = dict(zip(header, parts[: len(header)]))

        rows.append(
            {
                "Time": parsed["Time"],
                "CPU": parsed["CPU"],
                "CORE": parsed["CORE"],
                "SOCK": parsed["SOCK"],
                "NODE": parsed["NODE"],
                "%usr": parsed.get("%usr", "0"),
                "%nice": parsed.get("%nice", "0"),
                "%sys": parsed.get("%sys", "0"),
                "%iowait": parsed.get("%iowait", "0"),
                "%irq": parsed.get("%irq", "0"),
                "%soft": parsed.get("%soft", "0"),
                "%steal": parsed.get("%steal", "0"),
                "%guest": parsed.get("%guest", "0"),
                "%gnice": parsed.get("%gnice", "0"),
                "%idle": parsed.get("%idle", "0"),
            }
        )

    if not rows:
        raise ValueError(
            "Could not parse CPU rows from raw mpstat telemetry. "
            "Expected mpstat output with CPU CORE SOCK NODE and %idle columns."
        )

    return rows


def load_perfspect_cpu_report(input_path):
    """
    Return a normalized report dict with:
      - Brief System Summary
      - CPU Utilization Telemetry
      - _Input_Format
    """
    with open(input_path, "r", encoding="utf-8") as f:
        report = json.load(f)

    if CPU_TELEMETRY_SECTION in report:
        return {
            "Brief System Summary": report.get("Brief System Summary", [{}]),
            "CPU Utilization Telemetry": report[CPU_TELEMETRY_SECTION],
            "_Input_Format": "processed_json",
        }

    if "ScriptOutputs" in report:
        script_outputs = report["ScriptOutputs"]

        if RAW_MPSTAT_KEY not in script_outputs:
            available = ", ".join(sorted(script_outputs.keys()))
            raise ValueError(
                f"Raw PerfSpect JSON does not contain '{RAW_MPSTAT_KEY}'. "
                f"Available ScriptOutputs: {available}"
            )

        mpstat_output = script_outputs[RAW_MPSTAT_KEY].get("Stdout", "")
        cpu_rows = parse_mpstat_stdout(mpstat_output)

        system = {
            "Host Name": report.get("TargetName", ""),
        }

        if "date" in script_outputs:
            system["Time"] = script_outputs["date"].get("Stdout", "").strip()

        if "lscpu" in script_outputs:
            system.update(parse_lscpu_summary(script_outputs["lscpu"].get("Stdout", "")))

        return {
            "Brief System Summary": [system],
            "CPU Utilization Telemetry": cpu_rows,
            "_Input_Format": "raw_json",
        }

    available = ", ".join(sorted(report.keys()))
    raise ValueError(
        "Unsupported input JSON. Expected either processed PerfSpect JSON with "
        f"'{CPU_TELEMETRY_SECTION}' or raw PerfSpect JSON with ScriptOutputs. "
        f"Available top-level keys: {available}"
    )


def aggregate_logical_cpus(report):
    rows = report["CPU Utilization Telemetry"]
    samples_by_cpu = defaultdict(list)

    for row in rows:
        cpu = int(row["CPU"])
        idle = to_float(row["%idle"])

        sample = {
            "Time": row["Time"],
            "CPU": cpu,
            "CORE": int(row["CORE"]),
            "SOCK": int(row["SOCK"]),
            "NODE": int(row["NODE"]),
            "usr": to_float(row["%usr"]),
            "sys": to_float(row["%sys"]),
            "soft": to_float(row["%soft"]),
            "iowait": to_float(row["%iowait"]),
            "idle": idle,
            "util": 100.0 - idle,
        }

        samples_by_cpu[cpu].append(sample)

    cpu_rows = []

    for cpu in sorted(samples_by_cpu):
        samples = samples_by_cpu[cpu]

        cpu_rows.append(
            {
                "CPU": cpu,
                "CORE": samples[0]["CORE"],
                "SOCK": samples[0]["SOCK"],
                "NODE": samples[0]["NODE"],
                "Physical_Core_Key": (
                    f'S{samples[0]["SOCK"]}_N{samples[0]["NODE"]}_C{samples[0]["CORE"]}'
                ),
                "Samples": len(samples),
                "Avg_Util_%": avg([s["util"] for s in samples]),
                "Max_Util_%": max(s["util"] for s in samples),
                "Avg_usr_%": avg([s["usr"] for s in samples]),
                "Avg_sys_%": avg([s["sys"] for s in samples]),
                "Avg_soft_%": avg([s["soft"] for s in samples]),
                "Avg_iowait_%": avg([s["iowait"] for s in samples]),
                "Avg_idle_%": avg([s["idle"] for s in samples]),
            }
        )

    return cpu_rows


def aggregate_physical_cores(cpu_rows):
    by_core = defaultdict(list)

    for row in cpu_rows:
        key = (row["SOCK"], row["NODE"], row["CORE"])
        by_core[key].append(row)

    core_rows = []

    for (sock, node, core), siblings in sorted(by_core.items()):
        siblings = sorted(siblings, key=lambda r: r["CPU"])
        cpu_ids = [r["CPU"] for r in siblings]
        sibling_utils = [r["Avg_Util_%"] for r in siblings]

        core_rows.append(
            {
                "SOCK": sock,
                "NODE": node,
                "CORE": core,
                "Physical_Core_Key": f"S{sock}_N{node}_C{core}",
                "Sibling_CPU_IDs": ",".join(str(c) for c in cpu_ids),
                "Sibling_Count": len(cpu_ids),
                "Avg_Sibling_Util_%": avg(sibling_utils),
                "Max_Sibling_Avg_Util_%": max(sibling_utils),
                "Sum_Logical_Util_%": sum(sibling_utils),
                "Effective_CPU_Equiv": sum(sibling_utils) / 100.0,
            }
        )

    return core_rows


def summarize_counts(cpu_rows, core_rows, active_threshold):
    active_cpu_rows = [r for r in cpu_rows if r["Avg_Util_%"] > active_threshold]
    active_core_rows = [
        r for r in core_rows if r["Max_Sibling_Avg_Util_%"] > active_threshold
    ]

    by_numa = defaultdict(
        lambda: {
            "Logical_CPUs": 0,
            "Physical_Cores": 0,
            "Active_Logical_CPUs": 0,
            "Active_Physical_Cores": 0,
            "Effective_CPU_Equiv": 0.0,
        }
    )

    for r in cpu_rows:
        key = (r["SOCK"], r["NODE"])
        by_numa[key]["Logical_CPUs"] += 1
        by_numa[key]["Effective_CPU_Equiv"] += r["Avg_Util_%"] / 100.0
        if r["Avg_Util_%"] > active_threshold:
            by_numa[key]["Active_Logical_CPUs"] += 1

    for r in core_rows:
        key = (r["SOCK"], r["NODE"])
        by_numa[key]["Physical_Cores"] += 1
        if r["Max_Sibling_Avg_Util_%"] > active_threshold:
            by_numa[key]["Active_Physical_Cores"] += 1

    return {
        "Active_Threshold_%": active_threshold,
        "Total_Logical_CPUs": len(cpu_rows),
        "Total_Physical_Cores": len(core_rows),
        "Active_Logical_CPUs": len(active_cpu_rows),
        "Active_Physical_Cores": len(active_core_rows),
        "Effective_CPU_Equiv": sum(r["Avg_Util_%"] for r in cpu_rows) / 100.0,
        "By_NUMA": by_numa,
    }


def write_csv(rows, path):
    if not rows:
        return

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()

        for row in rows:
            writer.writerow(
                {k: round(v, 4) if isinstance(v, float) else v for k, v in row.items()}
            )


def write_numa_summary(summary, path):
    rows = []

    for (sock, node), v in sorted(summary["By_NUMA"].items()):
        rows.append(
            {
                "SOCK": sock,
                "NODE": node,
                "Logical_CPUs": v["Logical_CPUs"],
                "Physical_Cores": v["Physical_Cores"],
                "Active_Logical_CPUs": v["Active_Logical_CPUs"],
                "Active_Physical_Cores": v["Active_Physical_Cores"],
                "Effective_CPU_Equiv": v["Effective_CPU_Equiv"],
                "Ceil_Effective_CPU_Equiv": math.ceil(v["Effective_CPU_Equiv"]),
            }
        )

    write_csv(rows, path)


def add_active_core_note(summary):
    threshold = summary["Active_Threshold_%"]
    return (
        f'Active physical cores > {threshold:g}%: '
        f'{summary["Active_Physical_Cores"]} / {summary["Total_Physical_Cores"]} '
        f'| Active CPU IDs > {threshold:g}%: '
        f'{summary["Active_Logical_CPUs"]} / {summary["Total_Logical_CPUs"]}'
    )


def add_chart_note(fig, text):
    fig.text(0.5, 0.01, text, ha="center", va="bottom", fontsize=11)


def plot_all_logical_cpus(cpu_rows, summary, path):
    rows = sorted(cpu_rows, key=lambda r: r["CPU"])
    cpus = [r["CPU"] for r in rows]
    vals = [r["Avg_Util_%"] for r in rows]

    fig = plt.figure(figsize=(22, 7))
    plt.bar(cpus, vals)
    plt.title("Logical CPU Utilization")
    plt.xlabel("Logical CPU ID")
    plt.ylabel("Average utilization (%)")
    xtick_step = max(1, math.ceil(len(cpus) / 32))
    plt.xticks(cpus[::xtick_step], rotation=90)
    plt.ylim(0, max(100, math.ceil(max(vals) / 10) * 10))
    plt.grid(axis="y", alpha=0.3)
    add_chart_note(fig, add_active_core_note(summary))
    plt.tight_layout(rect=(0, 0.04, 1, 1))
    plt.savefig(path, dpi=180)
    plt.close()


def plot_top_logical_cpus(cpu_rows, summary, path, top_n):
    rows = sorted(cpu_rows, key=lambda r: r["Avg_Util_%"], reverse=True)[:top_n]
    labels = [
        f'CPU {r["CPU"]}\nS{r["SOCK"]}/N{r["NODE"]}/C{r["CORE"]}' for r in rows
    ]
    vals = [r["Avg_Util_%"] for r in rows]

    fig = plt.figure(figsize=(18, 7))
    plt.bar(range(len(rows)), vals)
    plt.title(f"Top {top_n} Logical CPUs")
    plt.xlabel("Logical CPU ID")
    plt.ylabel("Average utilization (%)")
    plt.xticks(range(len(rows)), labels, rotation=90)
    plt.ylim(0, max(100, math.ceil(max(vals) / 10) * 10))
    plt.grid(axis="y", alpha=0.3)
    add_chart_note(fig, add_active_core_note(summary))
    plt.tight_layout(rect=(0, 0.05, 1, 1))
    plt.savefig(path, dpi=180)
    plt.close()


def plot_physical_cores_by_numa(core_rows, summary, path):
    rows = sorted(core_rows, key=lambda r: (r["SOCK"], r["NODE"], r["CORE"]))
    labels = [
        f'C{r["CORE"]}\nS{r["SOCK"]}/N{r["NODE"]}\nCPU {r["Sibling_CPU_IDs"]}'
        for r in rows
    ]
    vals = [r["Max_Sibling_Avg_Util_%"] for r in rows]

    fig = plt.figure(figsize=(28, 8))
    plt.bar(range(len(rows)), vals)
    plt.title("Physical Core Utilization by NUMA")
    plt.xlabel("Physical core: CORE / Socket / NUMA / sibling CPU IDs")
    plt.ylabel("Max sibling average utilization (%)")
    step = max(1, math.ceil(len(rows) / 32))
    plt.xticks(range(0, len(rows), step), labels[::step], rotation=90)
    plt.ylim(0, 100)
    plt.grid(axis="y", alpha=0.3)

    prev = (rows[0]["SOCK"], rows[0]["NODE"])
    for i, r in enumerate(rows):
        cur = (r["SOCK"], r["NODE"])
        if cur != prev:
            plt.axvline(i - 0.5, linestyle="--", linewidth=1)
            prev = cur

    add_chart_note(fig, add_active_core_note(summary))
    plt.tight_layout(rect=(0, 0.06, 1, 1))
    plt.savefig(path, dpi=180)
    plt.close()


def plot_top_physical_cores(core_rows, summary, path, top_n):
    rows = sorted(
        core_rows, key=lambda r: r["Max_Sibling_Avg_Util_%"], reverse=True
    )[:top_n]
    labels = [
        f'C{r["CORE"]}\nS{r["SOCK"]}/N{r["NODE"]}\nCPU {r["Sibling_CPU_IDs"]}'
        for r in rows
    ]
    vals = [r["Max_Sibling_Avg_Util_%"] for r in rows]

    fig = plt.figure(figsize=(18, 7))
    plt.bar(range(len(rows)), vals)
    plt.title(f"Top {top_n} Physical Cores")
    plt.xlabel("Physical core")
    plt.ylabel("Max sibling average utilization (%)")
    plt.xticks(range(len(rows)), labels, rotation=90)
    plt.ylim(0, 100)
    plt.grid(axis="y", alpha=0.3)
    add_chart_note(fig, add_active_core_note(summary))
    plt.tight_layout(rect=(0, 0.06, 1, 1))
    plt.savefig(path, dpi=180)
    plt.close()


def print_summary(system, summary, input_format):
    print("\nInput:")
    print(f"  Format: {input_format}")

    print("\nSystem:")
    for k in [
        "Host Name",
        "Time",
        "CPU Model",
        "Sockets",
        "Cores per Socket",
        "Hyperthreading",
        "CPUs",
        "NUMA Nodes",
    ]:
        if system.get(k):
            print(f"  {k}: {system[k]}")

    threshold = summary["Active_Threshold_%"]

    print("\nCPU/core summary:")
    print(f"  Threshold: > {threshold:g}% average utilization")
    print(f"  Logical CPU IDs: {summary['Total_Logical_CPUs']}")
    print(
        "  Physical cores: "
        f"{summary['Total_Physical_Cores']} "
        "(deduped by SOCK,NODE,CORE)"
    )
    print(f"  Active logical CPU IDs > {threshold:g}%: {summary['Active_Logical_CPUs']}")
    print(f"  Active physical cores > {threshold:g}%: {summary['Active_Physical_Cores']}")
    print(
        f"  Effective CPU equivalents: {summary['Effective_CPU_Equiv']:.2f} "
        f"(ceil {math.ceil(summary['Effective_CPU_Equiv'])})"
    )

    print("\nBy Socket/NUMA:")
    print(
        f"{'SOCK':>5} {'NODE':>5} {'CPU IDs':>8} {'Cores':>8} "
        f"{'ActiveCPU':>10} {'ActiveCore':>11} {'CPUEquiv':>9}"
    )
    for (sock, node), v in sorted(summary["By_NUMA"].items()):
        print(
            f"{sock:>5} {node:>5} {v['Logical_CPUs']:>8} "
            f"{v['Physical_Cores']:>8} {v['Active_Logical_CPUs']:>10} "
            f"{v['Active_Physical_Cores']:>11} {v['Effective_CPU_Equiv']:>9.2f}"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Generate PerfSpect CPU/core utilization charts from processed JSON or raw JSON."
    )
    parser.add_argument("raw_file")
    parser.add_argument("--out-dir", default="perfspect_cpu_core_output")
    parser.add_argument("--top-n", type=int, default=40)
    parser.add_argument(
        "--active-threshold",
        type=float,
        default=10.0,
        help="Use > threshold for active CPU/core counts. Default: 10.0",
    )
    args = parser.parse_args()

    if args.top_n <= 0:
        parser.error("--top-n must be greater than 0")

    if args.active_threshold < 0 or args.active_threshold > 100:
        parser.error("--active-threshold must be between 0 and 100")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    report = load_perfspect_cpu_report(args.raw_file)
    system = report.get("Brief System Summary", [{}])[0]
    input_format = report.get("_Input_Format", "unknown")

    cpu_rows = aggregate_logical_cpus(report)
    core_rows = aggregate_physical_cores(cpu_rows)
    summary = summarize_counts(cpu_rows, core_rows, args.active_threshold)

    top_n = min(args.top_n, len(cpu_rows), len(core_rows))

    write_csv(cpu_rows, out_dir / "logical_cpu_utilization_summary.csv")
    write_csv(core_rows, out_dir / "physical_core_utilization_summary.csv")
    write_numa_summary(summary, out_dir / "numa_core_summary.csv")

    plot_all_logical_cpus(cpu_rows, summary, out_dir / "logical_cpu_utilization.png")
    plot_top_logical_cpus(
        cpu_rows, summary, out_dir / f"top{top_n}_logical_cpus.png", top_n
    )
    plot_physical_cores_by_numa(
        core_rows, summary, out_dir / "physical_core_utilization_by_numa.png"
    )
    plot_top_physical_cores(
        core_rows, summary, out_dir / f"top{top_n}_physical_cores.png", top_n
    )

    print_summary(system, summary, input_format)

    print("\nGenerated files:")
    for p in sorted(out_dir.iterdir()):
        print(f"  {p}")


if __name__ == "__main__":
    main()
