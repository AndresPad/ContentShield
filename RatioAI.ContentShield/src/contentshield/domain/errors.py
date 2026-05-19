"""Domain errors for the orchestrator."""



class InvalidModeError(ValueError):
    """Unknown or unsupported detection mode."""

    def __init__(self, mode: str, reason: str | None = None) -> None:
        self.mode = mode
        msg = f"Invalid detection mode: {mode!r}"
        if reason:
            msg = f"{msg} — {reason}"
        super().__init__(msg)
