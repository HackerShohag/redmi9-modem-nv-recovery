# Redmi 9 Modem / NV Recovery & Backup Toolkit

High‑level repository overview. Detailed operational documentation lives in `toolkit/README.md`.

---
## 1. Executive Summary
Incident: Both SIM slots oscillated between `ABSENT/UNKNOWN` with partial ICCID prefixes and bursts of `RADIO_NOT_AVAILABLE`. Kernel logs showed CCCI port spam followed by MD NVRAM assertion (`nvram_io.c:2679`). Root cause: Corrupted (or schema‑misaligned) logical NVRAM records inside `nvdata` causing early modem aborts. Remediation: Preserve failing state → isolate (rename) `nvdata`/`nvcfg` to trigger regeneration → confirm stable dual‑SIM (`LOADED,LOADED`) → create known‑good snapshots → implement proactive backup & monitoring.

## Purpose
Provide reproducible, minimally risky procedures and scripts to:
- Capture full modem/NV snapshots before/after changes
- Detect and repair dual‑SIM failures caused by modem NV corruption
- Monitor for regression and alert early
- Diff failing vs. healthy NV states for forensic analysis

---
## Contents
| Path | Description |
|------|-------------|
| `toolkit/` | All scripts + detailed README (primary docs) |
| `backups/` | Generated snapshot directories (ignored by git) |
| `.gitignore` | Excludes large binary & transient artifacts |

## Core Scripts (See toolkit README for details)
`backup_modem_nv.sh`, `repair_dualsim_nv.sh`, `monitor_modem.sh`, `health_check.sh`, `restore_nvdata.sh`, `diff_nvdata.sh`, `orchestrate_health_snapshot.sh`.

## Quick Start
```bash
chmod +x toolkit/backup_modem_nv.sh
./toolkit/backup_modem_nv.sh
```
Attempt automated repair if dual‑SIM failure reappears:
```bash
./toolkit/repair_dualsim_nv.sh
```
Monitor with alerts:
```bash
ALERT_RNA=5 EXIT_ON_ALERT=1 ./toolkit/monitor_modem.sh
```

---
## When To Use Each
| Situation | Script |
|-----------|--------|
| Pre-change snapshot | `backup_modem_nv.sh` |
| Dual-SIM absent/unknown & suspected NV issue | `repair_dualsim_nv.sh` |
| Routine nightly health + backup | `orchestrate_health_snapshot.sh` |
| Spot-check current status | `health_check.sh` |
| Compare two NV archives | `diff_nvdata.sh` |
| Restore a known good NV | `restore_nvdata.sh` |

Generated: `backups/modem_nv_*/parts/*.img`, `.../nv/*.tar.gz`, `manifest.json`, `SHA256SUMS`, optional `TAG`.

---
## Minimal Watch Properties
```
vendor.ril.md_status_from_ccci
vendor.mtk.md1.status
gsm.sim.state
gsm.operator.numeric
```

Minimal decisive indicators (pre‑fix):
```
vendor.ril.md_status_from_ccci=stop
gsm.sim.state=ABSENT,ABSENT (or UNKNOWN,ABSENT loop)
Partial ICCID (e.g. 8988002) only
MD exception trace with nvram_io.c:2679
```

---
## Safety Notes
- Never restore or flash `preloader` / `lk` from backups unless absolutely necessary.
- Always back up failing state before attempting repair.
- Keep snapshots off-device for redundancy.

---
## More Documentation
Full forensic background, failure signatures, recovery workflow, monitoring strategy, and future roadmap: see `toolkit/README.md`.

---
## 7. Backup & Integrity Model
Contents per snapshot:
| Component | Description |
|-----------|------------|
| `parts/*.img` | Raw partitions (if accessible) |
| `nv/*.tar.gz` | Logical NV archives (nvdata/nvcfg) |
| `getprop_focus.txt` / `getprop_all.txt` | Prop state |
| `manifest.json` | Structured metadata |
| `SHA256SUMS` | Integrity hashes |
| `TAG` | Optional human label |

Verify integrity:
```bash
cd backups/modem_nv_YYYYMMDD_HHMMSS
sha256sum -c SHA256SUMS
```
Resume incomplete run:
```bash
RESUME_DIR=backups/modem_nv_YYYYMMDD_HHMMSS ./toolkit/backup_modem_nv.sh
```

---
## 8. Forensic Diff & Analysis
`diff_nvdata.sh` output sections: Presence diff, content diffs, summary. Combine with orchestrator `--prev` for automated comparisons.

Example:
```bash
./toolkit/diff_nvdata.sh backups/modem_nv_A/nv/nvdata_good_A.tar.gz \
                         backups/modem_nv_B/nv/nvdata_good_B.tar.gz > diff_report.txt
```

Automated (latest vs previous tagged):
```bash
./toolkit/orchestrate_health_snapshot.sh --prev backups/modem_nv_<OLD_TS>
```

---
## 9. Safety & Governance
| Risk | Guideline |
|------|-----------|
| Low-level flash brick | Never restore `preloader` / `lk` blindly |
| Lose failing evidence | Snapshot BEFORE repair / restore |
| Silent NV drift | Schedule orchestrated periodic backups |
| Local storage loss | Offload archives externally |
| Misread partial dumps | Inspect `parts/*.log` & run checksum verification |

---
## 10. Change Log (Milestones)
| Phase | Addition |
|-------|----------|
| Diagnosis | Baseline capture & analysis |
| Recovery | `repair_dualsim_nv.sh` |
| Backup | `backup_modem_nv.sh` (manifest + hashes) |
| Monitoring | `monitor_modem.sh` alerts |
| Diffing | `diff_nvdata.sh`, orchestrator prev diff |
| Restore | `restore_nvdata.sh` safe staging |

---
## 11. Future Enhancements (Ideas)
| Idea | Benefit |
|------|---------|
| JSON health output mode | Easier integration / parsing |
| Auto pruning (retention) | Manage disk usage |
| Webhook alert plugin | Remote notification |
| Manifest diff tool | Rapid partition change detection |
| XZ compression flag | Smaller archives |

---
## 12. Appendix: Exit Codes
| Script | Exit Codes |
|--------|-----------|
| repair_dualsim_nv.sh | 0 success/no-action, 2 failure to recover |
| orchestrate_health_snapshot.sh | 0 success, 10 anomalies, 2 arg error |
| monitor_modem.sh | 20 alert-trigger exit (if EXIT_ON_ALERT=1) |

---
## 13. Minimal Watch List
```
vendor.ril.md_status_from_ccci
vendor.mtk.md1.status
gsm.sim.state
gsm.operator.numeric
```

---
## 14. License / Usage Note
Internal single-device diagnostic toolkit (Redmi 9 / MTK Helio G80). Adapt cautiously.

---
## 15. Fast Reference Commands
| Task | Command |
|------|---------|
| Dry run backup | `DRY_RUN=1 ./toolkit/backup_modem_nv.sh` |
| Resume backup | `RESUME_DIR=backups/modem_nv_<TS> ./toolkit/backup_modem_nv.sh` |
| Tag backup | `./toolkit/orchestrate_health_snapshot.sh --tag nightly` |
| Force backup | `./toolkit/orchestrate_health_snapshot.sh --force-backup` |
| Diff vs previous | `./toolkit/orchestrate_health_snapshot.sh --prev backups/modem_nv_<OLD_TS>` |
| Alerting monitor | `ALERT_RNA=5 EXIT_ON_ALERT=1 ./toolkit/monitor_modem.sh` |

---
End.
