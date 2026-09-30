# Cross-Cloud Comparison: GNR on AWS vs GCP

AWS 8i and Google Cloud C4-GNR are built on the same processor generation — Intel Xeon 6
(Granite Rapids) — and both enable Sub-NUMA Cluster (SNC3), presenting each socket to the OS as
three NUMA nodes. The per-cloud configurations are not the same, so a NUMA node is **not** the same
width on both.

See also: [GNR (8i) on AWS](aws_gnr.md) and [GNR (C4) on GCP](gcp_gnr.md) for the per-cloud
topology, instance sizes, and specifications.

---

## Comparison

| | AWS 8i | GCP C4-GNR |
| --- | --- | --- |
| Cores per socket | 96 | 72 |
| vCPUs per socket | 192 | 144 |
| NUMA nodes per socket | 3 (SNC3) | 3 (SNC3) |
| **Cores per NUMA node** | **32** | **24** |
| **vCPUs per NUMA node** | **64** | **48** |
| Memory channels per socket / per node | 12 / 4 | 12 / 4 |
| Memory speed (as stated per cloud) | DDR5-7200 | 6400 MT/s |
| All-core turbo | 3.9 GHz | 3.9 GHz |
| Smallest multi-node size | 24xl (96 vCPU, 2 nodes) | `c4-standard-96` (2 nodes) |
| Largest single-socket size | 48xl (192 vCPU, 3 nodes) | `c4-standard-144` (144 vCPU, 3 nodes) |
| Largest system | 96xl (384 vCPU, 6 nodes) | `c4-standard-288` (288 vCPU, 6 nodes) |

> **Note** — code that hard-codes a 32-core NUMA node on AWS will mis-place threads on GCP, where a
> node is 24 cores. Size thread pools and pinning from the node width reported at runtime rather
> than from an assumed socket layout.

---

## Portability Guidance

- **Derive node width at runtime**, not from a socket count or an instance-family assumption. Read
  it with `lscpu` or `numactl -H` on the running instance and size thread pools from that.
- **Node width is uniform on GCP C4-GNR** (48 vCPUs / 24 cores at every multi-node shape) but
  **varies on AWS 8i** — 24xl is built from two *partial* dies of 24 cores each, so it does not
  match the 32 cores/node of the larger sizes.
- **Watch for asymmetric topologies.** `c4-standard-192` reports 2 sockets and 4 NUMA nodes covering
  three dies on one socket and a single die on the other; the nodes are not evenly distributed.
- **The largest cross-socket-free size differs**: 48xl on AWS (192 vCPU), `c4-standard-144` on GCP
  (144 vCPU). A workload sized to stay within one socket needs a different shape on each cloud.
