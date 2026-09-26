import os
import sys

import pytest

# bin/'s shared helpers (lib/gm_screen.py), importable by the tests as they are by bin/.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "lib")))


@pytest.fixture
def roll_path():
    """Absolute path to bin/roll, so tests are location-independent."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "bin", "roll"))


@pytest.fixture
def validate_path():
    """Absolute path to bin/validate-adapter."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "bin", "validate-adapter"))


@pytest.fixture
def campaign_path():
    """Absolute path to bin/campaign."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "bin", "campaign"))


@pytest.fixture
def forge_path():
    """Absolute path to bin/forge."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "bin", "forge"))
