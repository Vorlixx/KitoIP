"""KitoIP unified entry point.

Usage:
    python run.py                  -> interactive CLI
    python run.py --target X --auto-> headless assessment of X
    python run.py --web            -> web dashboard
"""

import argparse
import sys


def main() -> None:
    parser = argparse.ArgumentParser(prog="kitoip")
    parser.add_argument("--web", action="store_true", help="start the web dashboard")
    parser.add_argument("--target", help="target domain/URL")
    parser.add_argument("--auto", action="store_true", help="headless auto-pipeline")
    parser.add_argument("--program", default="KitoIP Program")
    parser.add_argument("--version", action="store_true")
    args, _ = parser.parse_known_args()

    if args.version:
        from kitoip import __version__

        print(f"KitoIP {__version__}")
        return

    if args.web:
        from kitoip.webapp import main as web_main

        web_main()
        return

    from kitoip.cli import main as cli_main

    cli_main()


if __name__ == "__main__":
    main()
