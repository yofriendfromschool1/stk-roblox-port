# SPDX-License-Identifier: GPL-3.0-or-later
"""Module entrypoint for `python -m tools.stk2rbx`."""

import sys

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
