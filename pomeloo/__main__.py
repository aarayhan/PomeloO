"""CLI.

  pomeloo                              start the tray app (wheel, drop pad, hotkey)
  pomeloo list FILE                    show conversions/tools for a file
  pomeloo convert png FILES...         convert headless, print outputs
  pomeloo tool compress FILES... [--set key=json]
  pomeloo run convert|tool|action ID FILES...   hand off to the running app (used by Explorer)
  pomeloo --register | --unregister    add/remove the Explorer context menu
"""
import json
import sys


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        from .app import main as app_main
        return app_main()
    cmd, rest = argv[0], argv[1:]
    if cmd in ("--register", "--unregister"):
        from . import shell
        n = shell.register() if cmd == "--register" else shell.unregister()
        print(f"{'Registered' if cmd == '--register' else 'Removed'} Explorer menu ({n} keys).")
        return 0
    if cmd == "run":
        from .app import send_or_start
        return send_or_start(rest[0], rest[1], rest[2:])
    if cmd == "list":
        from .catalog import ext_of, targets, tools
        e = ext_of(rest[0])
        print("convert:", " ".join(targets(e)) or "-")
        print("tools:  ", " ".join(tools(e, max(1, len(rest)))) or "-")
        return 0
    if cmd in ("convert", "tool"):
        params, files = {}, []
        it = iter(rest[1:])
        for a in it:
            if a == "--set":
                k, _, v = next(it).partition("=")
                try:
                    params[k] = json.loads(v)
                except json.JSONDecodeError:
                    params[k] = v
            else:
                files.append(a)
        rc = 0
        if cmd == "convert":
            from .engines import convert
            for f in files:
                try:
                    print(convert(f, rest[0]))
                except Exception as e:
                    print(f"error: {f}: {e}", file=sys.stderr)
                    rc = 1
        else:
            from .tools import run_tool
            try:
                for out in run_tool(rest[0], files, params):
                    print(out)
            except Exception as e:
                print(f"error: {e}", file=sys.stderr)
                rc = 1
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
