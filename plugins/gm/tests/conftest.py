import os

import pytest


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
