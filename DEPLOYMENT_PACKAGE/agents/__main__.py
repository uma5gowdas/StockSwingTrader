"""Entry point: python -m agents <agent> <command> [options]."""

import sys

from agents.cli import main

if __name__ == "__main__":
    sys.exit(main())
