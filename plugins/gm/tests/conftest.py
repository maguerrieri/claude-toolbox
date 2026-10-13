import os
import sys

import pytest

# The CLIs' shared helpers (lib/gm_screen.py), importable by the tests as they are by scripts/.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "lib")))


@pytest.fixture
def roll_path():
    """Absolute path to scripts/roll, so tests are location-independent."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "scripts", "roll"))


@pytest.fixture
def validate_path():
    """Absolute path to scripts/validate-adapter."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "scripts", "validate-adapter"))


@pytest.fixture
def campaign_path():
    """Absolute path to scripts/campaign."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "scripts", "campaign"))


@pytest.fixture
def forge_path():
    """Absolute path to scripts/forge."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "scripts", "forge"))
