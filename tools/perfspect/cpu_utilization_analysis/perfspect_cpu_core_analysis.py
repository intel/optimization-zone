#!/usr/bin/env python3
"""
Parse Intel PerfSpect JSON CPU utilization telemetry and generate logical-CPU
and physical-core utilization summaries/charts.

Physical core dedup rule:
  PerfSpect provides CPU, CORE, SOCK, NODE in CPU Utilization Telemetry.
  With Hyper-Threading enabled, multiple logical CPU IDs can map to the same
  physical core.

  This script counts one physical core per unique:
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
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


def to_float(value):
    if value is None:
        return float("nan")
    return float(str(value).replace(",", ""))


def load_perfspect_json(json_path):
    with open(json_path, "r", encoding="utf-8") as f:
        return json.load(f)


def avg(values):
    return sum(values) / len(values) if values else float("nan")


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
    """
    Deduplicate logical CPUs into physical cores using:
        (SOCK, NODE, CORE)

    Utilization metrics:
      - Max_Sibling_Avg_Util_%:
          highest average utilization among sibling logical CPU IDs.
          This is used to decide whether the physical core is active.

      - Avg_Sibling_Util_%:
          average utilization across sibling logical CPU IDs.

      - Sum_Logical_Util_%:
          sum of sibling logical CPU utilization.
          On 2-way HT, this can range from 0 to 200.

      - Effective_CPU_Equiv:
          Sum_Logical_Util_% / 100.
    """
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
    """
    Active CPU ID:
      Avg_Util_% > active_threshold

    Active physical core:
      Max_Sibling_Avg_Util_% > active_threshold

    The physical-core count is deduplicated by (SOCK, NODE, CORE), so if both
    sibling CPU IDs are active on the same physical core, the core still counts
    once.
    """
    active_cpu_rows = [r for r in cpu_rows if r["Avg_Util_%"] > active_threshold]
    active_core_rows = [
        r for r in core_rows
        if r["Max_Sibling_Avg_Util_%"] > active_threshold
    ]

    by_numa = defaultdict(lambda: {
        "Logical_CPUs": 0,
        "Physical_Cores": 0,
        "Active_Logical_CPUs": 0,
        "Active_Physical_Cores": 0,
        "Effective_CPU_Equiv": 0.0,
    })

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
                {
                    k: round(v, 4) if isinstance(v, float) else v
                    for k, v in row.items()
                }
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
    fig.text(
        0.5,
        0.01,
        text,
        ha="center",
        va="bottom",
        fontsize=11,
    )


def plot_all_logical_cpus(cpu_rows, summary, path):
    rows = sorted(cpu_rows, key=lambda r: r["CPU"])
    cpus = [r["CPU"] for r in rows]
    vals = [r["Avg_Util_%"] for r in rows]

    fig = plt.figure(figsize=(22, 7))
    plt.bar(cpus, vals)
    plt.title("Logical CPU Utilization")
    plt.xlabel("Logical CPU ID")
    plt.ylabel("Average utilization (%)")
    plt.xticks(range(0, max(cpus) + 1, 8), rotation=90)
    plt.ylim(0, max(100, math.ceil(max(vals) / 10) * 10))
    plt.grid(axis="y", alpha=0.3)
    add_chart_note(fig, add_active_core_note(summary))
    plt.tight_layout(rect=(0, 0.04, 1, 1))
    plt.savefig(path, dpi=180)
    plt.close()


def plot_top_logical_cpus(cpu_rows, summary, path, top_n):
    rows = sorted(cpu_rows, key=lambda r: r["Avg_Util_%"], reverse=True)[:top_n]
    labels = [
        f'CPU {r["CPU"]}\nS{r["SOCK"]}/N{r["NODE"]}/C{r["CORE"]}'
        for r in rows
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
    step = 4 if len(rows) <= 128 else 8
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
        core_rows,
        key=lambda r: r["Max_Sibling_Avg_Util_%"],
        reverse=True,
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


def print_summary(system, summary):
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
        if k in system:
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
        description="Generate PerfSpect CPU/core utilization charts."
    )
    parser.add_argument("json_file")
    parser.add_argument("--out-dir", default="perfspect_cpu_core_output")
    parser.add_argument("--top-n", type=int, default=40)
    parser.add_argument(
        "--active-threshold",
        type=float,
        default=10.0,
        help="Use > threshold for active CPU/core counts. Default: 10.0",
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    report = load_perfspect_json(args.json_file)
    system = report.get("Brief System Summary", [{}])[0]

    cpu_rows = aggregate_logical_cpus(report)
    core_rows = aggregate_physical_cores(cpu_rows)
    summary = summarize_counts(cpu_rows, core_rows, args.active_threshold)

    write_csv(cpu_rows, out_dir / "logical_cpu_utilization_summary.csv")
    write_csv(core_rows, out_dir / "physical_core_utilization_summary.csv")
    write_numa_summary(summary, out_dir / "numa_core_summary.csv")

    plot_all_logical_cpus(
        cpu_rows,
        summary,
        out_dir / "logical_cpu_utilization.png",
    )
    plot_top_logical_cpus(
        cpu_rows,
        summary,
        out_dir / f"top{args.top_n}_logical_cpus.png",
        args.top_n,
    )
    plot_physical_cores_by_numa(
        core_rows,
        summary,
        out_dir / "physical_core_utilization_by_numa.png",
    )
    plot_top_physical_cores(
        core_rows,
        summary,
        out_dir / f"top{args.top_n}_physical_cores.png",
        args.top_n,
    )

    print_summary(system, summary)

    print("\nGenerated files:")
    for p in sorted(out_dir.iterdir()):
        print(f"  {p}")


if __name__ == "__main__":
    main()
