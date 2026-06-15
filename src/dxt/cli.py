from __future__ import annotations

import argparse

from . import __version__


PLANNED_COMMANDS = ("parse", "ls", "compile", "build")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dxt",
        description="Data Transformation eXecutor: a dbt-project-compatible transformation engine.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"dxt {__version__}",
    )

    subparsers = parser.add_subparsers(dest="command")

    version_parser = subparsers.add_parser("version", help="Print the dxt version.")
    version_parser.set_defaults(handler=_version)

    for command in PLANNED_COMMANDS:
        planned = subparsers.add_parser(command, help=f"Planned command: {command}.")
        _add_common_project_args(planned)
        _add_selection_args(planned)
        if command == "ls":
            planned.add_argument("--resource-type")
            planned.add_argument("--output", choices=("text", "json"), default="text")
        if command == "build":
            planned.add_argument("--full-refresh", action="store_true")
        planned.add_argument("--threads", type=int)
        planned.set_defaults(display_command=command)
        planned.set_defaults(handler=_planned)

    docs_parser = subparsers.add_parser("docs", help="Planned docs commands.")
    docs_subparsers = docs_parser.add_subparsers(dest="docs_command")
    docs_generate = docs_subparsers.add_parser("generate", help="Planned command: docs generate.")
    _add_common_project_args(docs_generate)
    docs_generate.set_defaults(display_command="docs generate", handler=_planned)

    return parser


def _add_common_project_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--project-dir")
    parser.add_argument("--profiles-dir")
    parser.add_argument("--profile")
    parser.add_argument("--target")
    parser.add_argument("--target-path")
    parser.add_argument("--vars")


def _add_selection_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--select", action="append")
    parser.add_argument("--exclude", action="append")


def _version(_args: argparse.Namespace) -> int:
    print(__version__)
    return 0


def _planned(args: argparse.Namespace) -> int:
    print(f"`dxt {args.display_command}` is planned but not implemented yet. See PLAN.md.")
    return 2


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "handler"):
        parser.print_help()
        return 0
    return args.handler(args)
