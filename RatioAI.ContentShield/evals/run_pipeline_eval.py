#!/usr/bin/env python3
"""
Pipeline eval runner — evaluates the orchestrator /v1/detect endpoint across
all detector configurations, datasets, and modes requested in
Experiments_For_Demo.md.

Runs each (config, dataset) permutation as a separate MLflow run under a single
experiment. Generates per-run charts + a cross-config comparison summary.

Usage:
    # Run everything (all configs × all datasets)
    python -m evals.run_pipeline_eval

    # Quick smoke-test (5 samples, 2 configs)
    python -m evals.run_pipeline_eval --max-samples 5 --configs fast standard

    # Single dataset only
    python -m evals.run_pipeline_eval --datasets data/unified_eval.xlsx

    # Custom orchestrator URL
    python -m evals.run_pipeline_eval --orch-url https://my-orch.azurecontainerapps.io
"""

import asyncio
import csv
import hashlib
import json
import logging
import math
import os
import shutil
import subprocess
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import httpx
import matplotlib
import matplotlib.pyplot as plt
import mlflow
import numpy as np
import pandas as pd
import tyro
from pydantic import BaseModel, Field
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
    precision_recall_curve,
    precision_score,
    recall_score,
    roc_auc_score,
    roc_curve,
)

matplotlib.use("Agg")

from evals.adapters import adapt_detect_response, eval_error

logger = logging.getLogger("pipeline_eval")
POC_DIR = Path(__file__).resolve().parent.parent

ORCH_URL_DEFAULT = "https://ratio-pi-orch.graywater-ed11bb19.centralus.azurecontainerapps.io"

# ── Configuration permutations ─────────────────────────────────────────────
# Each config maps to the canonical /v1/detect request shape.

PIPELINE_CONFIGS: dict[str, dict] = {
    # --- Section 1: Baseline individual detectors ---
    "acs_alone":       {"detectors": ["acs_prompt_shield"]},
    "stage1_alone":    {"detectors": ["stage1"]},
    "stage2_alone":    {"detectors": ["stage2"]},
    "query_detect_alone": {"detectors": ["query_detect"]},

    # --- Section 1: Pipeline modes ---
    "fast":            {"mode": "fast"},
    "fast_query":      {"mode": "fast", "options": {"enable_query_detection": True}},
    "standard":        {"mode": "standard"},
    "standard_query":  {"mode": "standard", "options": {"enable_query_detection": True}},
}

# Human-readable experiment names — one MLflow experiment per config.
EXPERIMENT_NAMES: dict[str, str] = {
    "acs_alone":         "ACS Prompt Shield",
    "stage1_alone":      "Stage1 Residual Detector",
    "stage2_alone":      "Stage2 Classifier",
    "query_detect_alone": "Query Detection",
    "fast":              "Fast Pipeline",
    "fast_query":        "Fast + Query Pipeline",
    "standard":          "Standard Pipeline",
    "standard_query":    "Standard + Query Pipeline",
}

# Note: The orchestrator rejects arbitrary multi-detector combos via the
# detectors field (only single-detector selection is accepted). Ablation
# analysis (Section 3) is computed analytically: for each mode, we re-derive
# the pipeline verdict by masking out one detector from per-sample results.


# ── CLI config ─────────────────────────────────────────────────────────────

class PipelineEvalConfig(BaseModel):
    orch_url: str = Field(default=ORCH_URL_DEFAULT, description="Orchestrator base URL")
    datasets: list[Path] = Field(
        default=[
            POC_DIR / "data" / "unified_eval.xlsx",
        ],
        description="Dataset paths to evaluate",
    )
    xlsx_sheet: str = Field(default="Full Dataset", description="Sheet for .xlsx")
    xlsx_split: str = Field(default="test", description="Split filter for .xlsx")
    configs: list[str] = Field(
        default=[],
        description="Subset of config names to run (empty = all)",
    )
    max_samples: int = Field(default=0, description="Cap samples per dataset (0=all)")
    concurrency: int = Field(default=10, description="Max parallel requests")
    timeout_s: float = Field(default=60.0, description="Per-request timeout (seconds)")
    experiment: str = Field(default="", description="MLflow experiment name (empty = auto per config)")
    auth_token_env: str = Field(
        default="CONTENTSHIELD_EVAL_BEARER_TOKEN",
        description="Environment variable containing a bearer token for APIM-protected orchestrator URLs",
    )
    aad_resource: str = Field(
        default="",
        description="Optional Entra resource/audience for az account get-access-token when calling APIM",
    )


def _auth_headers(cfg: PipelineEvalConfig) -> dict[str, str]:
    """Resolve optional Authorization headers without logging secret material."""
    token = os.getenv(cfg.auth_token_env, "").strip() if cfg.auth_token_env else ""
    if not token and cfg.aad_resource:
        az_executable = shutil.which("az") or shutil.which("az.cmd")
        if not az_executable:
            raise RuntimeError(
                "aad_resource is set but Azure CLI ('az') was not found on PATH. "
                f"Install Azure CLI or set a bearer token via {cfg.auth_token_env}."
            )
        try:
            result = subprocess.run(
                [
                    az_executable,
                    "account",
                    "get-access-token",
                    "--resource",
                    cfg.aad_resource,
                    "--query",
                    "accessToken",
                    "-o",
                    "tsv",
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                "Timed out while running 'az account get-access-token'. "
                "Ensure Azure CLI is logged in and network access is available, "
                f"or set a bearer token via {cfg.auth_token_env}."
            ) from exc
        token = result.stdout.strip()
    return {"Authorization": f"Bearer {token}"} if token else {}


# ── Dataset loading (reuse existing loaders) ───────────────────────────────

def load_eval_hf(path: str) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            rows.append({
                "id": r["id"],
                "text": r["text"],
                "expected_label": "INJECTION" if r["is_injection"] else "OK",
                "source": r.get("source", "eval_hf"),
                "category": "injection" if r["is_injection"] else "benign",
                "family_type": "attack" if r["is_injection"] else "benign",
            })
    return rows


def load_foundry_cases(path: str) -> list[dict]:
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            is_inj = r["expected_label"] == "INJECTION"
            rows.append({
                "id": r["case_name"],
                "text": r["prompt_text"],
                "expected_label": r["expected_label"],
                "source": "foundry_cases",
                "category": r.get("category", ""),
                "family_type": "attack" if is_inj else "benign",
            })
    return rows


def load_unified_eval(path: str, *, sheet: str = "Full Dataset", split: str = "test") -> list[dict]:
    df = pd.read_excel(path, sheet_name=sheet)
    if split:
        df = df[df["split"] == split]
    df = df.dropna(subset=["text"])
    rows = []
    for _, r in df.iterrows():
        label = "INJECTION" if r["human_label"] == "INJECTION" else "OK"
        attack_fam = str(r.get("attack_family") or "").strip()
        benign_fam = str(r.get("benign_family") or "").strip()
        if attack_fam and attack_fam.lower() != "nan":
            category, family_type = attack_fam, "attack"
        elif benign_fam and benign_fam.lower() != "nan":
            category, family_type = benign_fam, "benign"
        else:
            category, family_type = "", ""
        rows.append({
            "id": r["case_id"],
            "text": r["text"],
            "expected_label": label,
            "source": r.get("source", "unified_eval"),
            "category": category,
            "family_type": family_type,
        })
    return rows


def load_dataset(path: Path, *, xlsx_sheet: str, xlsx_split: str) -> list[dict]:
    ext = path.suffix
    if ext == ".xlsx":
        return load_unified_eval(str(path), sheet=xlsx_sheet, split=xlsx_split)
    elif ext == ".jsonl":
        return load_eval_hf(str(path))
    elif ext == ".csv":
        return load_foundry_cases(str(path))
    raise ValueError(f"Unknown dataset format: {ext}")


# ── Orchestrator call ──────────────────────────────────────────────────────

async def call_orchestrator(
    client: httpx.AsyncClient,
    orch_url: str,
    text: str,
    config_kwargs: dict,
    semaphore: asyncio.Semaphore,
    headers: dict[str, str] | None = None,
) -> dict:
    """POST /v1/detect and return parsed response + latency."""
    payload = {"text": text, **config_kwargs}
    async with semaphore:
        t0 = time.perf_counter()
        try:
            resp = await client.post(f"{orch_url}/v1/detect", json=payload, headers=headers)
            resp.raise_for_status()
            latency_ms = (time.perf_counter() - t0) * 1000
            data = resp.json()
            return {"ok": True, "data": data, "latency_ms": latency_ms}
        except Exception as e:
            latency_ms = (time.perf_counter() - t0) * 1000
            return {"ok": False, "error": str(e), "latency_ms": latency_ms}


async def run_config(
    orch_url: str,
    samples: list[dict],
    config_kwargs: dict,
    concurrency: int,
    timeout_s: float,
    headers: dict[str, str] | None = None,
) -> list[dict]:
    """Run all samples through the orchestrator with a given config."""
    sem = asyncio.Semaphore(concurrency)
    timeout = httpx.Timeout(timeout_s, connect=30.0)
    results = []

    async with httpx.AsyncClient(timeout=timeout) as client:
        tasks = [
            _process_sample(client, orch_url, s, config_kwargs, sem, headers)
            for s in samples
        ]
        for i, coro in enumerate(asyncio.as_completed(tasks), 1):
            result = await coro
            results.append(result)
            if i % 50 == 0 or i == len(tasks):
                logger.info("  Progress: %d/%d", i, len(tasks))

    return results


async def _process_sample(client, orch_url, sample, config_kwargs, sem, headers=None):
    """Call orchestrator for one sample and normalize the result."""
    if headers is None:
        resp = await call_orchestrator(client, orch_url, sample["text"], config_kwargs, sem)
    else:
        resp = await call_orchestrator(client, orch_url, sample["text"], config_kwargs, sem, headers)

    if resp["ok"]:
        data = resp["data"]
        eval_score = adapt_detect_response(data, source="pipeline_eval")
        e2e_latency = data.get("latency_ms", {}).get("end_to_end", resp["latency_ms"])

        return {
            **sample,
            "predicted_label": eval_score.predicted_label,
            "raw_verdict": eval_score.raw_output,
            "score": round(eval_score.score, 6),
            "logprob_extracted": eval_score.logprob_extracted,
            "degraded": eval_score.degraded,
            "detector_status_counts": eval_score.detector_status_counts,
            "incomplete_detectors": eval_score.incomplete_detectors,
            "detector_reasons": eval_score.detector_reasons,
            "latency_ms": round(e2e_latency, 2),
            "client_latency_ms": round(resp["latency_ms"], 2),
            "detectors": {
                name: evidence.as_result_dict()
                for name, evidence in eval_score.detectors.items()
            },
            "reasons": data.get("reasons", []),
        }
    else:
        eval_score = eval_error("dependency_error", source="pipeline_eval", raw_output=f"ERROR: {resp['error']}")
        return {
            **sample,
            "predicted_label": eval_score.predicted_label,
            "raw_verdict": eval_score.raw_output,
            "score": eval_score.score,
            "logprob_extracted": eval_score.logprob_extracted,
            "degraded": eval_score.degraded,
            "error": eval_score.error,
            "latency_ms": round(resp["latency_ms"], 2),
            "client_latency_ms": round(resp["latency_ms"], 2),
            "detector_status_counts": eval_score.detector_status_counts,
            "incomplete_detectors": eval_score.incomplete_detectors,
            "detector_reasons": eval_score.detector_reasons,
            "detectors": {},
            "reasons": [],
        }


# ── Metrics ────────────────────────────────────────────────────────────────

def compute_metrics(results: list[dict]) -> dict:
    scored = [r for r in results if r["predicted_label"] in ("INJECTION", "OK")]
    total = len(results)
    unknown_count = total - len(scored)

    y_true = [1 if r["expected_label"] == "INJECTION" else 0 for r in scored]
    y_pred = [1 if r["predicted_label"] == "INJECTION" else 0 for r in scored]
    y_scores = [r["score"] for r in scored]
    latencies = [r["latency_ms"] for r in results if r["predicted_label"] != "UNKNOWN"]

    metrics = {}
    metrics["accuracy"] = accuracy_score(y_true, y_pred) if y_true else 0.0
    metrics["precision"] = precision_score(y_true, y_pred, zero_division=0) if y_true else 0.0
    metrics["recall"] = recall_score(y_true, y_pred, zero_division=0) if y_true else 0.0
    metrics["f1"] = f1_score(y_true, y_pred, zero_division=0) if y_true else 0.0

    if len(y_true) >= 2 and len(set(y_true)) == 2:
        tn, fp, fn, tp = confusion_matrix(y_true, y_pred, labels=[0, 1]).ravel()
    else:
        tp = sum(a == 1 and b == 1 for a, b in zip(y_true, y_pred))
        fp = sum(a == 0 and b == 1 for a, b in zip(y_true, y_pred))
        fn = sum(a == 1 and b == 0 for a, b in zip(y_true, y_pred))
        tn = sum(a == 0 and b == 0 for a, b in zip(y_true, y_pred))

    metrics.update({"tp": int(tp), "fp": int(fp), "tn": int(tn), "fn": int(fn)})
    metrics["tpr"] = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    metrics["fpr"] = fp / (fp + tn) if (fp + tn) > 0 else 0.0
    metrics["fnr"] = fn / (tp + fn) if (tp + fn) > 0 else 0.0
    metrics["total_samples"] = total
    metrics["scored_samples"] = len(scored)
    metrics["unknown_count"] = unknown_count

    if len(set(y_true)) > 1:
        try:
            metrics["roc_auc"] = roc_auc_score(y_true, y_scores)
        except ValueError:
            metrics["roc_auc"] = 0.0
    else:
        metrics["roc_auc"] = 0.0

    # Per-family breakdown
    attack_fm, benign_fm = _compute_family_metrics(scored)
    for family, fm in {**attack_fm, **benign_fm}.items():
        safe_name = family.replace(" ", "_").replace("/", "_")[:50]
        for k, v in fm.items():
            metrics[f"family_{safe_name}_{k}"] = v

    # Latency
    if latencies:
        lat = np.array(latencies)
        metrics["latency_mean_ms"] = float(np.mean(lat))
        metrics["latency_p50_ms"] = float(np.percentile(lat, 50))
        metrics["latency_p90_ms"] = float(np.percentile(lat, 90))
        metrics["latency_p95_ms"] = float(np.percentile(lat, 95))
        metrics["latency_p99_ms"] = float(np.percentile(lat, 99))
        metrics["latency_min_ms"] = float(np.min(lat))
        metrics["latency_max_ms"] = float(np.max(lat))
    else:
        for k in ("latency_mean_ms", "latency_p50_ms", "latency_p90_ms",
                   "latency_p95_ms", "latency_p99_ms", "latency_min_ms", "latency_max_ms"):
            metrics[k] = 0.0

    return metrics, y_true, y_pred, y_scores, attack_fm, benign_fm


def _compute_family_metrics(scored):
    attack_buckets: dict[str, list[dict]] = defaultdict(list)
    benign_buckets: dict[str, list[dict]] = defaultdict(list)
    for r in scored:
        cat = r.get("category", "").strip()
        if not cat or cat.lower() == "nan":
            continue
        ft = r.get("family_type", "")
        if ft == "benign":
            benign_buckets[cat].append(r)
        else:
            attack_buckets[cat].append(r)

    def _calc(buckets):
        family_metrics = {}
        for family, rows in sorted(buckets.items()):
            yt = [1 if r["expected_label"] == "INJECTION" else 0 for r in rows]
            yp = [1 if r["predicted_label"] == "INJECTION" else 0 for r in rows]
            tp = sum(a == 1 and b == 1 for a, b in zip(yt, yp))
            fp = sum(a == 0 and b == 1 for a, b in zip(yt, yp))
            fn = sum(a == 1 and b == 0 for a, b in zip(yt, yp))
            tn = sum(a == 0 and b == 0 for a, b in zip(yt, yp))
            family_metrics[family] = {
                "n": len(rows), "n_injection": sum(yt), "n_safe": len(rows) - sum(yt),
                "recall": tp / (tp + fn) if (tp + fn) > 0 else 0.0,
                "precision": tp / (tp + fp) if (tp + fp) > 0 else 0.0,
                "fpr": fp / (fp + tn) if (fp + tn) > 0 else 0.0,
                "tp": tp, "fp": fp, "fn": fn, "tn": tn,
            }
        return family_metrics

    return _calc(attack_buckets), _calc(benign_buckets)


# ── Charts ─────────────────────────────────────────────────────────────────

def log_charts(
    metrics, y_true, y_pred, y_scores,
    attack_fm, benign_fm, results, output_dir,
):
    """Generate per-run charts and log to MLflow."""

    # 1. Confusion matrix
    if len(y_true) >= 2 and len(set(y_true)) == 2:
        cm = confusion_matrix(y_true, y_pred, labels=[0, 1])
    else:
        cm = np.array([[metrics["tn"], metrics["fp"]], [metrics["fn"], metrics["tp"]]])
    fig, ax = plt.subplots(figsize=(5, 4))
    im = ax.imshow(cm, cmap="Blues")
    ax.set_xticks([0, 1]); ax.set_yticks([0, 1])
    ax.set_xticklabels(["OK", "INJECTION"]); ax.set_yticklabels(["OK", "INJECTION"])
    ax.set_xlabel("Predicted"); ax.set_ylabel("Actual"); ax.set_title("Confusion Matrix")
    for i in range(2):
        for j in range(2):
            ax.text(j, i, str(cm[i, j]), ha="center", va="center",
                    color="white" if cm[i, j] > cm.max() / 2 else "black", fontsize=16)
    fig.colorbar(im, ax=ax); fig.tight_layout()
    mlflow.log_figure(fig, "charts/confusion_matrix.png"); plt.close(fig)

    # 2. ROC curve
    if len(set(y_true)) > 1 and len(set(y_scores)) > 1:
        fpr_arr, tpr_arr, _ = roc_curve(y_true, y_scores)
        fig, ax = plt.subplots(figsize=(6, 5))
        ax.plot(fpr_arr, tpr_arr, linewidth=2, label=f"AUC = {metrics.get('roc_auc', 0):.3f}")
        ax.plot([0, 1], [0, 1], "k--", alpha=0.3)
        ax.set_xlabel("False Positive Rate"); ax.set_ylabel("True Positive Rate")
        ax.set_title("ROC Curve"); ax.legend(loc="lower right")
        ax.set_xlim([0, 1]); ax.set_ylim([0, 1.02]); fig.tight_layout()
        mlflow.log_figure(fig, "charts/roc_curve.png"); plt.close(fig)

        # 3. PR curve
        prec_arr, rec_arr, _ = precision_recall_curve(y_true, y_scores)
        fig, ax = plt.subplots(figsize=(6, 5))
        ax.plot(rec_arr, prec_arr, linewidth=2)
        ax.set_xlabel("Recall"); ax.set_ylabel("Precision")
        ax.set_title("Precision-Recall Curve")
        ax.set_xlim([0, 1]); ax.set_ylim([0, 1.02]); fig.tight_layout()
        mlflow.log_figure(fig, "charts/pr_curve.png"); plt.close(fig)

    # 4. Attack family recall
    if attack_fm:
        families = list(attack_fm.keys())
        recalls = [attack_fm[f]["recall"] for f in families]
        ns = [attack_fm[f]["n"] for f in families]
        fig, ax = plt.subplots(figsize=(max(8, len(families) * 0.9), 5))
        bars = ax.bar(range(len(families)), recalls, color="#4C72B0", edgecolor="black", alpha=0.85)
        ax.set_xticks(range(len(families)))
        ax.set_xticklabels(families, rotation=45, ha="right", fontsize=8)
        ax.set_ylabel("Recall"); ax.set_title("Per-Attack-Family Recall"); ax.set_ylim([0, 1.05])
        ax.axhline(y=0.95, color="red", linestyle="--", alpha=0.6, label="95% target"); ax.legend()
        for bar, n in zip(bars, ns):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.02,
                    f"n={n}", ha="center", va="bottom", fontsize=7)
        fig.tight_layout(); mlflow.log_figure(fig, "charts/attack_family_recall.png"); plt.close(fig)

    # 5. Benign family FPR
    if benign_fm:
        families = list(benign_fm.keys())
        fprs = [benign_fm[f]["fpr"] for f in families]
        ns = [benign_fm[f]["n"] for f in families]
        fig, ax = plt.subplots(figsize=(max(8, len(families) * 0.9), 5))
        bars = ax.bar(range(len(families)), fprs, color="#DD8452", edgecolor="black", alpha=0.85)
        ax.set_xticks(range(len(families)))
        ax.set_xticklabels(families, rotation=45, ha="right", fontsize=8)
        ax.set_ylabel("False Positive Rate"); ax.set_title("Per-Benign-Family FPR")
        ax.set_ylim([0, max(0.3, max(fprs) * 1.3) if fprs else 0.3])
        ax.axhline(y=0.08, color="red", linestyle="--", alpha=0.6, label="8% target"); ax.legend()
        for bar, n in zip(bars, ns):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.005,
                    f"n={n}", ha="center", va="bottom", fontsize=7)
        fig.tight_layout(); mlflow.log_figure(fig, "charts/benign_family_fpr.png"); plt.close(fig)

    # 6. Score distribution
    inj_scores = [r["score"] for r in results if r["expected_label"] == "INJECTION" and r["predicted_label"] != "UNKNOWN"]
    safe_scores = [r["score"] for r in results if r["expected_label"] != "INJECTION" and r["predicted_label"] != "UNKNOWN"]
    if inj_scores or safe_scores:
        fig, ax = plt.subplots(figsize=(7, 4))
        bins = np.linspace(0, 1, 30)
        if safe_scores:
            ax.hist(safe_scores, bins=bins, alpha=0.6, label="Safe", color="#55A868", edgecolor="black")
        if inj_scores:
            ax.hist(inj_scores, bins=bins, alpha=0.6, label="Injection", color="#C44E52", edgecolor="black")
        ax.set_xlabel("Score"); ax.set_ylabel("Count"); ax.set_title("Score Distribution"); ax.legend()
        fig.tight_layout(); mlflow.log_figure(fig, "charts/score_distribution.png"); plt.close(fig)

    # 7. Latency distribution
    latencies = [r["latency_ms"] for r in results if r["predicted_label"] != "UNKNOWN"]
    if latencies:
        fig, ax = plt.subplots(figsize=(7, 4))
        ax.hist(latencies, bins=40, color="#8172B2", edgecolor="black", alpha=0.8)
        for pct, color in [("p50", "green"), ("p90", "blue"), ("p95", "orange"), ("p99", "red")]:
            val = metrics.get(f"latency_{pct}_ms", 0)
            ax.axvline(val, color=color, linestyle="--", label=f"{pct}={val:.0f}ms")
        ax.set_xlabel("Latency (ms)"); ax.set_ylabel("Count"); ax.set_title("Latency Distribution")
        ax.legend(); fig.tight_layout()
        mlflow.log_figure(fig, "charts/latency_distribution.png"); plt.close(fig)

    # 8. Per-detector agreement heatmap (from per-sample detector results)
    _log_detector_agreement(results, output_dir)


def _log_detector_agreement(results, output_dir):
    """Compute Cohen's kappa and agreement % between each detector pair."""
    # Collect per-sample detector verdicts
    all_detectors = set()
    for r in results:
        all_detectors.update(r.get("detectors", {}).keys())
    all_detectors = sorted(all_detectors)

    if len(all_detectors) < 2:
        return

    # Build verdict arrays per detector
    det_verdicts: dict[str, list[int | None]] = {d: [] for d in all_detectors}
    for r in results:
        dets = r.get("detectors", {})
        for d in all_detectors:
            if d in dets:
                if dets[d].get("status", "completed") != "completed":
                    det_verdicts[d].append(None)
                else:
                    det_verdicts[d].append(1 if dets[d]["detected"] else 0)
            else:
                det_verdicts[d].append(None)

    # Cohen's kappa for each pair
    from sklearn.metrics import cohen_kappa_score
    pairs = []
    for i, d1 in enumerate(all_detectors):
        for d2 in all_detectors[i + 1:]:
            # Only compare samples where both detectors ran
            v1, v2 = [], []
            for a, b in zip(det_verdicts[d1], det_verdicts[d2]):
                if a is not None and b is not None:
                    v1.append(a); v2.append(b)
            if len(v1) < 5:
                continue
            agree = sum(a == b for a, b in zip(v1, v2)) / len(v1) * 100
            try:
                kappa = cohen_kappa_score(v1, v2)
            except Exception:
                kappa = 0.0
            pairs.append({"detector_1": d1, "detector_2": d2,
                          "cohens_kappa": round(kappa, 3), "agreement_pct": round(agree, 1),
                          "n_compared": len(v1)})

    if pairs:
        agreement_path = output_dir / "detector_agreement.json"
        agreement_path.write_text(json.dumps(pairs, indent=2))
        mlflow.log_artifact(str(agreement_path))

        # Heatmap
        n = len(all_detectors)
        kappa_matrix = np.eye(n)
        for p in pairs:
            i = all_detectors.index(p["detector_1"])
            j = all_detectors.index(p["detector_2"])
            kappa_matrix[i, j] = p["cohens_kappa"]
            kappa_matrix[j, i] = p["cohens_kappa"]

        fig, ax = plt.subplots(figsize=(max(6, n * 1.5), max(5, n * 1.2)))
        im = ax.imshow(kappa_matrix, cmap="RdYlGn", vmin=-1, vmax=1)
        ax.set_xticks(range(n)); ax.set_yticks(range(n))
        ax.set_xticklabels(all_detectors, rotation=45, ha="right", fontsize=9)
        ax.set_yticklabels(all_detectors, fontsize=9)
        ax.set_title("Detector Agreement (Cohen's κ)")
        for i in range(n):
            for j in range(n):
                ax.text(j, i, f"{kappa_matrix[i, j]:.2f}", ha="center", va="center", fontsize=10)
        fig.colorbar(im, ax=ax); fig.tight_layout()
        mlflow.log_figure(fig, "charts/detector_agreement_heatmap.png"); plt.close(fig)


# ── Cross-config comparison charts ─────────────────────────────────────────

def log_comparison_charts(all_run_metrics: list[dict], output_dir: Path):
    """Generate cross-config comparison charts logged to a summary MLflow run."""

    if not all_run_metrics:
        return

    df = pd.DataFrame(all_run_metrics)

    # 1. Baseline comparison table (Section 1)
    _log_baseline_table(df, output_dir)

    # 2. Ablation delta table (Section 3)
    _log_ablation_table(df, output_dir)

    # 3. Latency vs Recall tradeoff chart (Section 5)
    _log_latency_vs_recall(df, output_dir)

    # 4. Attack family heatmap across configs (Section 4)
    _log_attack_family_heatmap(df, output_dir)

    # 5. FP characterization across modes (Section 7)
    _log_fp_comparison(df, output_dir)


def _log_baseline_table(df, output_dir):
    """Section 1: Baseline comparison table."""
    cols = ["config", "dataset", "recall", "fpr", "f1", "latency_p95_ms", "accuracy", "precision"]
    table = df[cols].sort_values(["dataset", "config"])
    path = output_dir / "baseline_comparison.csv"
    table.to_csv(path, index=False)
    mlflow.log_artifact(str(path))

    # Chart: grouped bar — recall by config, one group per dataset
    datasets = sorted(df["dataset"].unique())
    configs_order = [c for c in PIPELINE_CONFIGS if c in df["config"].values]

    for ds in datasets:
        sub = df[df["dataset"] == ds].set_index("config")
        if sub.empty:
            continue
        present = [c for c in configs_order if c in sub.index]
        recalls = [sub.loc[c, "recall"] for c in present]
        fprs = [sub.loc[c, "fpr"] for c in present]

        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))

        # Recall bars
        bars = ax1.bar(range(len(present)), recalls, color="#4C72B0", edgecolor="black", alpha=0.85)
        ax1.set_xticks(range(len(present)))
        ax1.set_xticklabels(present, rotation=55, ha="right", fontsize=8)
        ax1.set_ylabel("Recall"); ax1.set_title(f"Recall by Config — {ds}"); ax1.set_ylim([0, 1.05])
        ax1.axhline(y=0.95, color="red", linestyle="--", alpha=0.6, label="95% target"); ax1.legend()
        for bar, val in zip(bars, recalls):
            ax1.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.01,
                     f"{val:.3f}", ha="center", va="bottom", fontsize=7)

        # FPR bars
        bars = ax2.bar(range(len(present)), fprs, color="#DD8452", edgecolor="black", alpha=0.85)
        ax2.set_xticks(range(len(present)))
        ax2.set_xticklabels(present, rotation=55, ha="right", fontsize=8)
        ax2.set_ylabel("FPR"); ax2.set_title(f"FPR by Config — {ds}")
        ax2.set_ylim([0, max(0.3, max(fprs) * 1.3) if fprs else 0.3])
        ax2.axhline(y=0.08, color="red", linestyle="--", alpha=0.6, label="8% target"); ax2.legend()
        for bar, val in zip(bars, fprs):
            ax2.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.005,
                     f"{val:.3f}", ha="center", va="bottom", fontsize=7)

        fig.tight_layout()
        safe_ds = ds.replace("/", "_").replace(" ", "_")
        mlflow.log_figure(fig, f"charts/baseline_{safe_ds}.png"); plt.close(fig)


def _log_ablation_table(df, output_dir):
    """Section 3: Ablation delta table — computed analytically.

    For each pipeline mode, re-derive the verdict by masking out one detector
    at a time from the per-sample predictions CSV. The OR-gate logic means:
    if we remove a detector, a sample flips from INJECTION→SAFE only if that
    detector was the sole trigger.
    """
    # Load per-sample results from modes that have multiple detectors
    ablation_modes = ["fast", "fast_query", "standard", "standard_query"]
    rows = []

    for ds in df["dataset"].unique():
        for mode_name in ablation_modes:
            mode_row = df[(df["config"] == mode_name) & (df["dataset"] == ds)]
            if mode_row.empty:
                continue

            # Find the predictions CSV for this run
            run_name_prefix = f"{mode_name}__{ds}__"
            pred_dir = POC_DIR / "evals" / "runs" / df.attrs.get("experiment", "pipeline-eval")
            matching_dirs = sorted(pred_dir.glob(f"{run_name_prefix}*"))
            if not matching_dirs:
                continue
            pred_csv = matching_dirs[-1] / "predictions.csv"
            if not pred_csv.exists():
                continue

            pred_df = pd.read_csv(pred_csv)
            full_recall = mode_row.iloc[0]["recall"]
            full_fpr = mode_row.iloc[0]["fpr"]

            # Find which detectors are present in columns
            det_cols = [c.replace("_detected", "") for c in pred_df.columns if c.endswith("_detected")]

            for removed_det in det_cols:
                # Re-compute verdict without this detector
                remaining = [d for d in det_cols if d != removed_det]
                if not remaining:
                    continue

                # Analytical OR-gate, NOT the production verdict.
                # Production uses Stage2-authoritative semantics; this
                # leave-one-out simulation keeps OR so that masking ACS
                # vs Stage2 produces a comparable per-detector signal.
                new_preds = []
                for _, row in pred_df.iterrows():
                    any_detected = any(
                        row.get(f"{d}_status", "completed") == "completed"
                        and row.get(f"{d}_detected", False) in (True, "True", 1, 1.0)
                        for d in remaining
                    )
                    new_preds.append("INJECTION" if any_detected else "OK")

                y_true = [1 if r == "INJECTION" else 0 for r in pred_df["expected_label"]]
                y_pred_new = [1 if r == "INJECTION" else 0 for r in new_preds]

                if not y_true:
                    continue

                tp = sum(a == 1 and b == 1 for a, b in zip(y_true, y_pred_new))
                fp = sum(a == 0 and b == 1 for a, b in zip(y_true, y_pred_new))
                fn = sum(a == 1 and b == 0 for a, b in zip(y_true, y_pred_new))
                tn = sum(a == 0 and b == 0 for a, b in zip(y_true, y_pred_new))

                abl_recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
                abl_fpr = fp / (fp + tn) if (fp + tn) > 0 else 0.0

                # Find specific attack examples now missed
                missed_examples = []
                for idx, row in pred_df.iterrows():
                    if row["expected_label"] == "INJECTION" and new_preds[idx] == "OK" and row.get("predicted_label") == "INJECTION":
                        text_preview = str(row.get("text", ""))[:80]
                        missed_examples.append(text_preview)

                rows.append({
                    "mode": mode_name,
                    "dataset": ds,
                    "removed": removed_det,
                    "recall_full": round(full_recall, 4),
                    "recall_ablated": round(abl_recall, 4),
                    "recall_drop": round(full_recall - abl_recall, 4),
                    "fpr_full": round(full_fpr, 4),
                    "fpr_ablated": round(abl_fpr, 4),
                    "fpr_change": round(abl_fpr - full_fpr, 4),
                    "attacks_now_missed": len(missed_examples),
                    "missed_examples": "; ".join(missed_examples[:3]),
                })

    if rows:
        abl_df = pd.DataFrame(rows)
        path = output_dir / "ablation_deltas.csv"
        abl_df.to_csv(path, index=False)
        mlflow.log_artifact(str(path))

        # Ablation chart for each dataset+mode
        for ds in abl_df["dataset"].unique():
            for mode_name in abl_df["mode"].unique():
                sub = abl_df[(abl_df["dataset"] == ds) & (abl_df["mode"] == mode_name)]
                if sub.empty:
                    continue

                fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))
                x = range(len(sub))
                labels = [r.replace("_", "\n") for r in sub["removed"]]

                # Recall drop
                bars = ax1.bar(x, sub["recall_drop"], color="#C44E52", edgecolor="black", alpha=0.85)
                ax1.set_xticks(list(x)); ax1.set_xticklabels(labels, fontsize=9)
                ax1.set_ylabel("Recall Drop"); ax1.set_title(f"Ablation Recall Drop — {mode_name} / {ds}")
                for bar, val in zip(bars, sub["recall_drop"]):
                    ax1.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.002,
                             f"{val:.3f}", ha="center", va="bottom", fontsize=8)

                # FPR change
                colors = ["#55A868" if v <= 0 else "#DD8452" for v in sub["fpr_change"]]
                bars = ax2.bar(x, sub["fpr_change"], color=colors, edgecolor="black", alpha=0.85)
                ax2.set_xticks(list(x)); ax2.set_xticklabels(labels, fontsize=9)
                ax2.set_ylabel("FPR Change"); ax2.set_title(f"Ablation FPR Change — {mode_name} / {ds}")
                ax2.axhline(y=0, color="black", linewidth=0.5)
                for bar, val in zip(bars, sub["fpr_change"]):
                    ax2.text(bar.get_x() + bar.get_width() / 2,
                             bar.get_height() + (0.002 if val >= 0 else -0.012),
                             f"{val:+.3f}", ha="center", va="bottom", fontsize=8)

                fig.tight_layout()
                safe_ds = ds.replace("/", "_").replace(" ", "_")
                mlflow.log_figure(fig, f"charts/ablation_{mode_name}_{safe_ds}.png"); plt.close(fig)


def _log_latency_vs_recall(df, output_dir):
    """Section 5: Latency vs Recall tradeoff curve."""
    mode_configs = ["fast", "fast_query", "standard", "standard_query"]

    for ds in df["dataset"].unique():
        sub = df[df["dataset"] == ds]
        present = [c for c in mode_configs if c in sub["config"].values]
        if len(present) < 2:
            continue
        sub = sub[sub["config"].isin(present)].set_index("config")

        fig, ax = plt.subplots(figsize=(8, 5))
        for cfg_name in present:
            if cfg_name in sub.index:
                row = sub.loc[cfg_name]
                ax.scatter(row["latency_p95_ms"], row["recall"], s=120, zorder=5)
                ax.annotate(cfg_name, (row["latency_p95_ms"], row["recall"]),
                            textcoords="offset points", xytext=(8, 5), fontsize=9)

        ax.set_xlabel("Latency p95 (ms)"); ax.set_ylabel("Recall")
        ax.set_title(f"Latency vs Recall Tradeoff — {ds}")
        ax.axhline(y=0.95, color="red", linestyle="--", alpha=0.4, label="95% recall target")
        ax.legend(); fig.tight_layout()
        safe_ds = ds.replace("/", "_").replace(" ", "_")
        mlflow.log_figure(fig, f"charts/latency_vs_recall_{safe_ds}.png"); plt.close(fig)


def _log_attack_family_heatmap(df, output_dir):
    """Section 4: Attack family × config heatmap."""
    # Collect family recall from metrics keys
    family_keys = set()
    for _, row in df.iterrows():
        for k in row.keys():
            if isinstance(k, str) and k.startswith("family_") and k.endswith("_recall"):
                fam = k[len("family_"):-len("_recall")]
                family_keys.add(fam)
    if not family_keys:
        return

    for ds in df["dataset"].unique():
        sub = df[df["dataset"] == ds]
        configs = list(sub["config"])
        families = sorted(family_keys)

        matrix = np.full((len(families), len(configs)), np.nan)
        for j, cfg in enumerate(configs):
            row = sub[sub["config"] == cfg]
            if row.empty:
                continue
            for i, fam in enumerate(families):
                key = f"family_{fam}_recall"
                if key in row.columns and pd.notna(row.iloc[0].get(key)):
                    matrix[i, j] = row.iloc[0][key]

        # Only plot if we have data
        if np.all(np.isnan(matrix)):
            continue

        fig, ax = plt.subplots(figsize=(max(10, len(configs) * 1.2), max(6, len(families) * 0.5)))
        masked = np.ma.masked_invalid(matrix)
        im = ax.imshow(masked, cmap="RdYlGn", vmin=0, vmax=1, aspect="auto")
        ax.set_xticks(range(len(configs))); ax.set_yticks(range(len(families)))
        ax.set_xticklabels(configs, rotation=55, ha="right", fontsize=8)
        ax.set_yticklabels([f.replace("_", " ") for f in families], fontsize=8)
        ax.set_title(f"Attack Family Recall × Config — {ds}")
        for i in range(len(families)):
            for j in range(len(configs)):
                val = matrix[i, j]
                if not np.isnan(val):
                    txt = f"{val:.0%}"
                    color = "white" if val < 0.5 else "black"
                    ax.text(j, i, txt, ha="center", va="center", fontsize=7, color=color)
        fig.colorbar(im, ax=ax, label="Recall"); fig.tight_layout()
        safe_ds = ds.replace("/", "_").replace(" ", "_")
        mlflow.log_figure(fig, f"charts/attack_family_heatmap_{safe_ds}.png"); plt.close(fig)


def _log_fp_comparison(df, output_dir):
    """Section 7: FP characterization — benign family FPR across modes."""
    benign_keys = set()
    for _, row in df.iterrows():
        for k in row.keys():
            if isinstance(k, str) and k.startswith("family_") and k.endswith("_fpr"):
                fam = k[len("family_"):-len("_fpr")]
                # Check the family has benign samples (n_safe > 0)
                n_safe_key = f"family_{fam}_n_safe"
                if n_safe_key in df.columns:
                    benign_keys.add(fam)
    if not benign_keys:
        return

    for ds in df["dataset"].unique():
        sub = df[df["dataset"] == ds]
        mode_configs = ["fast", "fast_query", "standard", "standard_query"]
        present = [c for c in mode_configs if c in sub["config"].values]
        if not present:
            continue

        families = sorted(benign_keys)
        rows = []
        for fam in families:
            row_data = {"family": fam.replace("_", " ")}
            for cfg in present:
                cfg_row = sub[sub["config"] == cfg]
                key = f"family_{fam}_fpr"
                if not cfg_row.empty and key in cfg_row.columns:
                    row_data[cfg] = cfg_row.iloc[0].get(key, np.nan)
            rows.append(row_data)

        fp_df = pd.DataFrame(rows)
        path = output_dir / f"fp_characterization_{ds.replace('/', '_')}.csv"
        fp_df.to_csv(path, index=False)
        mlflow.log_artifact(str(path))


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    cfg = tyro.cli(PipelineEvalConfig)

    # Resolve configs to run
    configs_to_run = cfg.configs if cfg.configs else list(PIPELINE_CONFIGS.keys())
    logger.info("Configs to run: %s", configs_to_run)

    # Timestamp for this eval session
    session_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")

    all_run_metrics: list[dict] = []
    summary_output_dir = POC_DIR / "evals" / "runs" / "pipeline-eval" / f"summary_{session_ts}"
    summary_output_dir.mkdir(parents=True, exist_ok=True)

    # Pre-load all datasets so we don't reload per config
    loaded_datasets: dict[str, tuple[str, list[dict]]] = {}
    for ds_path in cfg.datasets:
        ds_tag = ds_path.stem
        logger.info("Loading dataset: %s", ds_path)
        samples = load_dataset(ds_path, xlsx_sheet=cfg.xlsx_sheet, xlsx_split=cfg.xlsx_split)
        if cfg.max_samples > 0:
            samples = samples[:cfg.max_samples]
        logger.info("  Loaded %d samples from %s", len(samples), ds_tag)
        loaded_datasets[ds_tag] = (ds_path, samples)

    total_runs = len(configs_to_run) * len(loaded_datasets)
    run_idx = 0

    # ── One MLflow experiment per config (detector / pipeline mode) ────────
    for config_name in configs_to_run:
        experiment_name = (
            cfg.experiment if cfg.experiment
            else EXPERIMENT_NAMES.get(config_name, config_name)
        )
        mlflow.set_experiment(experiment_name)
        config_kwargs = PIPELINE_CONFIGS[config_name]

        for ds_tag, (ds_path, samples) in loaded_datasets.items():
            run_idx += 1
            run_name = ds_tag           # clean name: "unified_eval", "eval_hf", "foundry_cases"
            run_output_dir = POC_DIR / "evals" / "runs" / "pipeline-eval" / f"{config_name}__{ds_tag}__{session_ts}"
            run_output_dir.mkdir(parents=True, exist_ok=True)

            logger.info(
                "=== [%d/%d] Experiment=%s  Dataset=%s  Samples=%d ===",
                run_idx, total_runs, experiment_name, ds_tag, len(samples),
            )

            # Run inference
            headers = _auth_headers(cfg)
            results = asyncio.run(
                run_config(cfg.orch_url, samples, config_kwargs, cfg.concurrency, cfg.timeout_s, headers)
            )

            auth_error_count = sum("401 Unauthorized" in str(r.get("error", "")) for r in results)
            if auth_error_count:
                raise RuntimeError(
                    f"{auth_error_count}/{len(results)} requests failed with 401 Unauthorized. "
                    "Refresh the bearer token or AAD login before logging eval metrics."
                )

            # Compute metrics
            metrics, y_true, y_pred, y_scores, attack_fm, benign_fm = compute_metrics(results)

            # Log summary
            logger.info(
                "  Acc=%.3f Prec=%.3f Rec=%.3f F1=%.3f FPR=%.3f | "
                "TP=%d FP=%d TN=%d FN=%d | p50=%.0fms p95=%.0fms",
                metrics["accuracy"], metrics["precision"], metrics["recall"],
                metrics["f1"], metrics["fpr"],
                metrics["tp"], metrics["fp"], metrics["tn"], metrics["fn"],
                metrics["latency_p50_ms"], metrics["latency_p95_ms"],
            )

            # MLflow run — run_name = dataset, experiment = detector/mode
            with mlflow.start_run(run_name=run_name):
                params = {
                    "config": config_name,
                    "dataset": ds_tag,
                    "orch_url": cfg.orch_url,
                    "concurrency": cfg.concurrency,
                    "total_samples": len(samples),
                    "xlsx_sheet": cfg.xlsx_sheet,
                    "xlsx_split": cfg.xlsx_split,
                    "auth_kind": "aad_resource" if cfg.aad_resource else ("bearer_env" if headers else "none"),
                }
                if "mode" in config_kwargs:
                    params["mode"] = config_kwargs["mode"]
                if "detectors" in config_kwargs:
                    params["detectors"] = ",".join(config_kwargs["detectors"])

                mlflow.log_params(params)
                mlflow.log_metrics(metrics)

                # Save predictions CSV
                pred_path = run_output_dir / "predictions.csv"
                flat_results = []
                for r in results:
                    flat = {k: v for k, v in r.items() if k != "detectors"}
                    for det_name, det_data in r.get("detectors", {}).items():
                        flat[f"{det_name}_detected"] = det_data.get("detected")
                        flat[f"{det_name}_score"] = det_data.get("score")
                        flat[f"{det_name}_latency_ms"] = det_data.get("latency_ms")
                        flat[f"{det_name}_status"] = det_data.get("status")
                        flat[f"{det_name}_reason"] = det_data.get("reason")
                    flat_results.append(flat)
                pd.DataFrame(flat_results).to_csv(pred_path, index=False)
                mlflow.log_artifact(str(pred_path))

                # Save misclassified
                errors = [r for r in flat_results if r["predicted_label"] != r["expected_label"]]
                if errors:
                    err_path = run_output_dir / "misclassified.csv"
                    pd.DataFrame(errors).to_csv(err_path, index=False)
                    mlflow.log_artifact(str(err_path))

                # Family metrics JSON
                if attack_fm or benign_fm:
                    fam_path = run_output_dir / "family_metrics.json"
                    fam_path.write_text(json.dumps({
                        "attack_families": attack_fm,
                        "benign_families": benign_fm,
                    }, indent=2))
                    mlflow.log_artifact(str(fam_path))

                # Classification report
                if y_true and len(set(y_true)) > 1:
                    report = classification_report(y_true, y_pred, labels=[0, 1],
                                                   target_names=["OK", "INJECTION"])
                    rpt_path = run_output_dir / "classification_report.txt"
                    rpt_path.write_text(report)
                    mlflow.log_artifact(str(rpt_path))

                # Charts
                log_charts(metrics, y_true, y_pred, y_scores,
                           attack_fm, benign_fm, results, run_output_dir)

            # Collect for cross-config comparison
            run_metrics = {"config": config_name, "dataset": ds_tag, **metrics}
            all_run_metrics.append(run_metrics)

    # ── Summary experiment for cross-config comparison ─────────────────────
    logger.info("=== Generating cross-config comparison charts ===")
    mlflow.set_experiment("Pipeline Comparison Summary")
    with mlflow.start_run(run_name=f"Summary {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')}"):
        mlflow.log_param("type", "summary")
        mlflow.log_param("session_ts", session_ts)
        mlflow.log_param("configs_run", ",".join(configs_to_run))
        mlflow.log_param("datasets_run", ",".join(loaded_datasets.keys()))

        summary_df = pd.DataFrame(all_run_metrics)
        summary_df.attrs["experiment"] = "pipeline-eval"
        summary_path = summary_output_dir / "all_metrics.csv"
        summary_df.to_csv(summary_path, index=False)
        mlflow.log_artifact(str(summary_path))

        log_comparison_charts(all_run_metrics, summary_output_dir)

    logger.info("Done. %d runs completed. Summary at: %s", len(all_run_metrics), summary_output_dir)


if __name__ == "__main__":
    main()
