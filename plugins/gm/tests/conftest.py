import os

import pytest


@pytest.fixture
def roll_path():
    """Absolute path to bin/roll, so tests are location-independent."""
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "bin", "roll"))
