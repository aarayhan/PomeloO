"""File actions (the Actions wheel): work on files, folders and mixed selections."""
import shutil
import subprocess
from pathlib import Path

from PySide6.QtCore import QFileInfo, QMimeData, QPoint, Qt, QUrl
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


def share(paths, hwnd=0):
    """Open the Windows share sheet (Nearby Share, Mail, Phone Link…) via the shell's
    'Windows.ModernShare' verb, the same entry Explorer's context menu uses."""
    try:
        from win32com.shell import shell
        import win32con
        import win32gui
        parent = Path(paths[0]).parent
        folder = shell.SHGetDesktopFolder()
        _, pidl, _ = folder.ParseDisplayName(0, None, str(parent))
        sub = folder.BindToObject(pidl, None, shell.IID_IShellFolder)
        kids = [sub.ParseDisplayName(0, None, Path(p).name)[1] for p in paths if Path(p).parent == parent]
        _, cm = sub.GetUIObjectOf(hwnd, kids, shell.IID_IContextMenu, 0)
        menu = win32gui.CreatePopupMenu()
        cm.QueryContextMenu(menu, 0, 1, 0x7FFF, 0)
        cm.InvokeCommand((0, hwnd, "Windows.ModernShare", None, None, win32con.SW_SHOWNORMAL, 0, None))
        win32gui.DestroyMenu(menu)
    except Exception as e:
        QMessageBox.warning(None, "PomeloO", f"Windows share sheet unavailable: {e}")


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
