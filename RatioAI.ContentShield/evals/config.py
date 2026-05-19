"""Experiment configuration for eval runs."""

from pathlib import Path

from pydantic import BaseModel, Field


class EvalConfig(BaseModel):
    """Configuration for a single eval run."""

    # --- Model / endpoint ---
    model_url: str = Field(description="Base URL of the vLLM endpoint (or App A endpoint for --stage1-api)")
    model_name: str = Field(default="", description="Model name sent in the API payload (not needed for --stage1-api)")

    # --- Prompt ---
    prompt: Path | None = Field(default=None, description="Path to system prompt file (not needed for --stage1-api / --classifier-api)")

    # --- Datasets ---
    datasets: list[Path] = Field(
        description="One or more dataset paths (.jsonl, .csv, .xlsx)",
    )
    xlsx_sheet: str = Field(
        default="Full Dataset",
        description="Sheet name to read from .xlsx files",
    )
    xlsx_split: str = Field(
        default="test",
        description="Value of 'split' column to filter in .xlsx (empty = all rows)",
    )

    # --- Sampling ---
    max_samples: int = Field(
        default=0,
        description="Cap total samples (0 = unlimited)",
    )

    # --- Inference ---
    concurrency: int = Field(default=5, description="Max parallel requests")
    max_tokens: int = Field(default=512, description="Max generation tokens (512 to allow thinking/CoT models)")
    temperature: float = Field(default=0.0, description="Sampling temperature")
    timeout_s: float = Field(default=120.0, description="HTTP request timeout (seconds)")
    logprobs: bool = Field(
        default=True,
        description="Request logprobs from API for continuous confidence scores",
    )
    top_logprobs: int = Field(
        default=5,
        description="Number of top logprobs per token to return",
    )

    # --- Reasoning ---
    reasoning: str | None = Field(
        default=None,
        description="Reasoning mode. "
        "'thinking' → native thinking mode (Gemma 4, etc.) via chat_template_kwargs. "
        "'low'/'medium'/'high' → safeguard prompt-level reasoning depth.",
    )
    reasoning_effort: str | None = Field(
        default=None,
        description="API-level reasoning_effort (low/medium/high). "
        "Controls CoT depth for models with native reasoning (e.g. gpt-oss-safeguard-120b).",
    )

    # --- MLflow ---
    experiment: str | None = Field(
        default=None,
        description="MLflow experiment name (default: auto-generated from model name + datetime)",
    )
    run_name: str | None = Field(
        default=None,
        description="MLflow run name (auto-generated if omitted)",
    )

    # --- Constrained decoding ---
    guided_choice: list[str] | None = Field(
        default=None,
        description="Constrained decoding choices (e.g. YES NO). "
        "vLLM masks all other tokens. Fast but may fail on safety-tuned models like Llama.",
    )
    structured_output: bool = Field(
        default=False,
        description="Use structured output (response_format json_schema) to force "
        "YES/NO verdict. More reliable than guided_choice against safety-tuned models.",
    )

    # --- Classifier API mode ---
    classifier_api: bool = Field(
        default=False,
        description="Use the /classify wrapper API instead of raw vLLM /v1/chat/completions. "
        "When enabled, model_url should point to the classifier service "
        "(e.g. https://cae-ratio-...). Prompt, model_name, logprobs, max_tokens "
        "are ignored (baked into the service).",
    )

    # --- Stage-1 orchestrator detector mode ---
    stage1_api: bool = Field(
        default=False,
        description="Evaluate the stage1 detector via the orchestrator /v1/detect endpoint. "
        "Uses Azure AD token auth (auto-refreshed). model_url should be the orchestrator base URL. "
        "Prompt, model_name, logprobs, max_tokens are ignored.",
    )
