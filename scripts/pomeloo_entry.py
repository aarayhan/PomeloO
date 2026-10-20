"""PyInstaller entry point (relative imports in pomeloo/__main__.py need a package context).

Build:
  .venv\\Scripts\\pyinstaller --noconfirm --windowed --name PomeloO --icon ../assets/pomeloo.ico --distpath dist --workpath build --paths . ^
    --collect-all imageio_ffmpeg --collect-all pypandoc --collect-all pillow_heif --collect-all zxingcpp ^
    --collect-all pymupdf --collect-submodules pomeloo ^
    --collect-submodules winrt --collect-binaries winrt scripts\\pomeloo_entry.py
"""
from pomeloo.__main__ import main

raise SystemExit(main())
