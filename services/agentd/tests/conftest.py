"""Test isolation for the profile store.

Every test process gets its own profile file. Without this, running the suite would write
into the developer's real `~/.spatialagent/profile.json` — a test that edits the user's
memory is exactly the failure mode this project is meant to rule out.
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def isolated_profile(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTD_PROFILE", str(tmp_path / "profile.json"))
    yield
