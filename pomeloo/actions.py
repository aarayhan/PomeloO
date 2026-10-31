"""File actions (the Actions wheel): work on files, folders and mixed selections."""
import shutil
import subprocess
from pathlib import Path

from PySide6.QtCore import QFileInfo, QMimeData, QPoint, Qt, QTimer, QUrl
from PySide6.QtGui import QDrag, QGuiApplication
from PySide6.QtWidgets import (QApplication, QFileDialog, QFileIconProvider, QHBoxLayout, QLabel,
                               QListWidget, QListWidgetItem, QMessageBox, QPushButton, QVBoxLayout,
                               QWidget)

from .catalog import unique


def file_mime(paths) -> QMimeData:
    m = QMimeData()
    m.setUrls([QUrl.fromLocalFile(str(p)) for p in paths])  # Qt adds CF_HDROP on Windows
    return m


def copy(paths):
    m = file_mime(paths)
    m.setData('application/x-qt-windows-mime;value="Preferred DropEffect"', b"\x01\x00\x00\x00")  # copy
    QApplication.clipboard().setMimeData(m)


def copy_path(paths):
    QApplication.clipboard().setText("\n".join(str(Path(p)) for p in paths))


def select_in_explorer(path):
    """Open an Explorer window with this file selected (when the user asks to see it)."""
    import subprocess
    subprocess.Popen(["explorer", "/select,", str(path)])


def reveal(paths):
    """Select the files in an Explorer window that already shows their folder. Never opens a new window."""
    paths = [Path(p) for p in paths]
    if not paths:
        return
    try:
        import win32com.client
        for w in win32com.client.Dispatch("Shell.Application").Windows():
            try:
                folder = w.Document.Folder
                if Path(folder.Self.Path) != paths[0].parent:
                    continue
            except Exception:
                continue  # not a folder view (e.g. Control Panel)
            for i, p in enumerate(q for q in paths if q.parent == paths[0].parent):
                if item := folder.ParseName(p.name):
                    # 1 select | 4 deselect others | 8 scroll into view | 16 focus; later items just add
                    w.Document.SelectItem(item, 1 | 4 | 8 | 16 if i == 0 else 1)
            return
    except Exception:
        pass  # revealing is a convenience; the files are already saved


def move(paths):
    dest = QFileDialog.getExistingDirectory(None, "Move to…", str(Path(paths[0]).parent))
    if not dest:
        return
    moved = []
    for p in paths:
        moved.append(shutil.move(str(p), str(unique(Path(dest) / Path(p).name))))
    reveal(moved)


def terminal(paths):
    p = Path(paths[0])
    folder = p if p.is_dir() else p.parent
    try:
        subprocess.Popen(["wt.exe", "-d", str(folder)])
    except OSError:
        subprocess.Popen(["cmd.exe", "/K", f"cd /d {folder}"], creationflags=subprocess.CREATE_NEW_CONSOLE)


# The share sheet is WinRT's DataTransferManager shown for a window of the calling process. Windows PowerShell
# 5.1 (always present) projects WinRT, so a small helper process hosts it: a tiny window at the cursor, the files
# as StorageItems, then ShowShareUIForWindow. Keeping it out of the tray app also means a failure there can't
# take PomeloO down. (The old IContextMenu "Windows.ModernShare" route gave "Invalid window handle" and, with the
# verb as text, an access violation in pywin32 that killed the whole app.)
SHARE_PS = r"""
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
try {
Add-Type -AssemblyName System.Windows.Forms, System.Runtime.WindowsRuntime
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDataTransferManagerInterop {
    IntPtr GetForWindow([In] IntPtr appWindow, [In] ref Guid riid);
    void ShowShareUIForWindow(IntPtr appWindow);
}
public static class ShareInterop {
    public static IntPtr ForWindow(object f, IntPtr h, Guid iid) { return ((IDataTransferManagerInterop)f).GetForWindow(h, ref iid); }
    public static void Show(object f, IntPtr h) { ((IDataTransferManagerInterop)f).ShowShareUIForWindow(h); }
}
'@
$null = [Windows.ApplicationModel.DataTransfer.DataTransferManager, Windows.ApplicationModel.DataTransfer, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(); $task.Result }
$items = New-Object 'System.Collections.Generic.List[Windows.Storage.IStorageItem]'
foreach ($p in ($env:POMELOO_SHARE | ConvertFrom-Json)) {
    if (Test-Path -LiteralPath $p -PathType Container) { $items.Add((Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($p)) ([Windows.Storage.StorageFolder]))) }
    else { $items.Add((Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($p)) ([Windows.Storage.StorageFile]))) }
}
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.TopMost = $true
$form.Location = [System.Windows.Forms.Cursor]::Position; $form.Size = New-Object System.Drawing.Size(2, 2)
$form.Show()
$factory = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeMarshal]::GetActivationFactory([Windows.ApplicationModel.DataTransfer.DataTransferManager])
$ptr = [ShareInterop]::ForWindow($factory, $form.Handle, [Guid]'A5CAEE9B-8708-49D1-8D36-67D25A8DA00C')
$dtm = [System.Runtime.InteropServices.Marshal]::GetObjectForIUnknown($ptr)
$dtm.add_DataRequested([Windows.Foundation.TypedEventHandler[Windows.ApplicationModel.DataTransfer.DataTransferManager, Windows.ApplicationModel.DataTransfer.DataRequestedEventArgs]]{
    param($s, $e)
    $e.Request.Data.Properties.Title = 'Shared from PomeloO'
    $e.Request.Data.SetStorageItems($items)
}) | Out-Null
[ShareInterop]::Show($factory, $form.Handle)
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 300000  # a transfer may outlive the sheet
$timer.Add_Tick({ $form.Close() }); $timer.Start()
[System.Windows.Forms.Application]::Run($form)
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }  # plain text: -EncodedCommand forces CLIXML otherwise
"""


def share(paths):
    """Open the Windows share sheet (Nearby Share, Phone Link, Mail, WhatsApp…) for these files and folders."""
    import base64
    import json
    import os
    script = base64.b64encode(SHARE_PS.encode("utf-16-le")).decode()
    try:
        helper = subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
             "-EncodedCommand", script], env={**os.environ, "POMELOO_SHARE": json.dumps([str(p) for p in paths])},
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW)
    except OSError as e:
        return QMessageBox.warning(None, "PomeloO", f"Windows share sheet unavailable: {e}")

    def check():  # a helper that already ended with an error never opened the sheet
        if helper.poll() not in (None, 0) and (why := helper.stderr.read().strip()):
            QMessageBox.warning(None, "PomeloO", f"Windows share sheet unavailable: {why[:400]}")
    QTimer.singleShot(10_000, check)


class Shelf(QWidget):
    """Float: a small always-on-top shelf pinned to the right screen edge. Drag files out of it."""
    _instance = None

    def __init__(self):
        super().__init__(None, Qt.WindowStaysOnTopHint | Qt.Tool | Qt.FramelessWindowHint)
        self.setAcceptDrops(True)
        self.setStyleSheet("QWidget{background:#1c1c1e;color:white;border-radius:10px}"
                           "QListWidget{border:none} QPushButton{border:none;padding:2px 6px}")
        lay = QVBoxLayout(self)
        top = QHBoxLayout()
        top.addWidget(QLabel("  Float"))
        top.addStretch()
        clear, close = QPushButton("Clear"), QPushButton("✕")
        clear.clicked.connect(lambda: self.list.clear())
        close.clicked.connect(self.close)
        top.addWidget(clear)
        top.addWidget(close)
        lay.addLayout(top)
        self.list = QListWidget(viewMode=QListWidget.IconMode)
        self.list.setSelectionMode(QListWidget.ExtendedSelection)
        self.list.setDragEnabled(True)
        self.list.startDrag = self._start_drag
        lay.addWidget(self.list)
        self.icons = QFileIconProvider()
        self.resize(170, 360)
        geo = QGuiApplication.primaryScreen().availableGeometry()
        self.move(geo.right() - self.width() - 8, geo.center().y() - self.height() // 2)
        self._grab = None

    @classmethod
    def add(cls, paths):
        if cls._instance is None:
            cls._instance = Shelf()
        s = cls._instance
        have = {s.list.item(i).data(Qt.UserRole) for i in range(s.list.count())}
        for p in paths:
            if str(p) not in have:
                it = QListWidgetItem(s.icons.icon(QFileInfo(str(p))), Path(p).name)
                it.setData(Qt.UserRole, str(p))
                it.setToolTip(str(p))
                s.list.addItem(it)
        s.show()
        s.raise_()

    def _start_drag(self, actions):
        items = self.list.selectedItems()
        if items:
            d = QDrag(self.list)
            d.setMimeData(file_mime([i.data(Qt.UserRole) for i in items]))
            d.exec(Qt.CopyAction | Qt.MoveAction, Qt.CopyAction)

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls() and e.source() is not self.list:
            e.acceptProposedAction()

    def dropEvent(self, e):
        self.add([u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()])

    def mousePressEvent(self, e):  # drag the shelf by its title bar
        self._grab = e.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, e):
        if self._grab is not None and e.buttons() & Qt.LeftButton:
            self.move(e.globalPosition().toPoint() - self._grab)

    def mouseReleaseEvent(self, e):
        self._grab = None
        geo = self.screen().availableGeometry()  # snap to the nearest side edge
        x = geo.left() + 8 if self.x() + self.width() / 2 < geo.center().x() else geo.right() - self.width() - 8
        self.move(QPoint(x, self.y()))


def run_action(aid: str, paths):
    paths = [str(Path(p)) for p in paths]
    {"share": share, "float": Shelf.add, "copy": copy, "move": move, "copyPath": copy_path,
     "terminal": terminal}[aid](paths)
