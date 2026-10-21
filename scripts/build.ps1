# Builds dist\PomeloO: the C helpers (native\), then the one-folder PyInstaller app, then drops
# libraries PomeloO never loads. Used locally and by CI:  powershell -File scripts\build.ps1
param([string]$Python = ".venv\Scripts\python.exe", [switch]$NativeOnly)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot)

# C helpers via zig cc (pip install ziglang: a full C toolchain, no Visual Studio or admin needed)
New-Item -ItemType Directory -Force native\bin | Out-Null
$cc = @("-m", "ziglang", "cc", "-target", "x86_64-windows-gnu", "-O2", "-s")
& $Python @cc -municode "-Wl,--subsystem,windows" native\send.c -o native\bin\pomeloo-send.exe -lshell32  # no console flash
if ($LASTEXITCODE) { throw "compiling native\send.c failed" }
& $Python @cc -shared native\watch.c -o native\bin\pomeloo_native.dll
if ($LASTEXITCODE) { throw "compiling native\watch.c failed" }
Remove-Item native\bin\*.pdb, native\bin\*.lib -ErrorAction SilentlyContinue
if ($NativeOnly) { return }

& $Python -m PyInstaller --noconfirm --windowed --name PomeloO --icon ../assets/pomeloo.ico `
    --distpath dist --workpath build --specpath build --paths . `
    --collect-all imageio_ffmpeg --collect-all pypandoc --collect-all pillow_heif --collect-all zxingcpp `
    --collect-all pymupdf --collect-submodules pomeloo --collect-submodules winrt --collect-binaries winrt `
    --exclude-module pymupdf.layout --exclude-module onnxruntime `
    --exclude-module tkinter --exclude-module pdf2docx.gui `
    scripts/pomeloo_entry.py
if ($LASTEXITCODE) { throw "PyInstaller failed" }

# Never loaded by PomeloO (checked with PyInstaller.depend.bindepend: only the touch keyboard plugin
# needs Quick/QML/OpenGL, only the PDF image plugin needs Qt PDF; opengl32sw is a GPU-less fallback
# that widgets don't use; OpenCV's video I/O is unused by pdf2docx).
$i = "dist\PomeloO\_internal"
$q = "$i\PySide6"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    "$q\opengl32sw.dll", "$q\translations", "$q\Qt6Quick.dll", "$q\Qt6Qml.dll", "$q\Qt6QmlMeta.dll", `
    "$q\Qt6QmlModels.dll", "$q\Qt6QmlWorkerScript.dll", "$q\Qt6OpenGL.dll", "$q\Qt6VirtualKeyboard.dll", `
    "$q\Qt6Pdf.dll", "$q\plugins\platforminputcontexts", "$q\plugins\imageformats\qpdf.dll", `
    "$i\cv2\opencv_videoio_ffmpeg*.dll"
Copy-Item native\bin\pomeloo-send.exe, native\bin\pomeloo_native.dll dist\PomeloO\
"Built dist\PomeloO ({0:n0} MB)" -f ((Get-ChildItem dist\PomeloO -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
