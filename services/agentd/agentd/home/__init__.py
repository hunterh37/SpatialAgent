"""Home execution backends for `ServerExecutor`.

`HomeExecutor` is the seam (agentd/executors.py). Everything here is an implementation of it,
so adding a backend never touches the agent loop — which is what the executor boundary was
for.
"""

from .companion import CompanionHome, CompanionUnavailable

__all__ = ["CompanionHome", "CompanionUnavailable"]
