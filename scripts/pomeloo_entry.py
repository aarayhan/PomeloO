"""PyInstaller entry point (relative imports in pomeloo/__main__.py need a package context).
Build with scripts\\build.ps1."""
from pomeloo.__main__ import main

raise SystemExit(main())
