"""Per-job progress reporting. The worker thread running a job installs a callback; engines that know
how far along they are (ffmpeg) call report(fraction). Engines that don't simply never report."""
import threading

_local = threading.local()


def set_reporter(cb):
    _local.cb = cb


def reporter():
    return getattr(_local, "cb", None)


def report(fraction: float):
    if cb := reporter():
        cb(min(1.0, max(0.0, fraction)))
