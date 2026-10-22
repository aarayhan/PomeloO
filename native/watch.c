/* pomeloo_native.dll: the always-on parts of the tray app, on one native thread, so Python only
 * wakes up when something actually happens (it used to poll 40x a second).
 *
 *  - drag gesture: while the left button drags from Explorer/desktop, a tap of exactly one of
 *    Shift/Ctrl/Alt calls back EV_KEY(key); releasing the button calls back EV_UP.
 *  - Ctrl+V in an Explorer folder or on the desktop calls back EV_PASTE (Python saves a copied image
 *    there as a file; Explorer itself can't paste images).
 *  - WhatsApp Desktop leaves a full-screen WebView2 window at opacity 0 above the desktop that
 *    swallows clicks on the wallpaper; such fully invisible windows are made click-through.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>

enum { EV_KEY = 1, EV_UP = 2, EV_PASTE = 3, EV_DRAG_TOP = 4, EV_QUIET = 5 };
/* EV_PASTE: Ctrl+V in an Explorer folder / the desktop. EV_DRAG_TOP: a file dragged from Explorer reached
 * the top edge of a monitor (the notch opens its drop zones). EV_QUIET(1/0): a full-screen app, game or
 * presentation started/ended (the notch hides). */
typedef void (*pomeloo_cb)(int event, int key);  /* Qt reads the cursor itself (DPI scaling) */

static pomeloo_cb callback;
static volatile LONG stopping;  /* set at exit: no callbacks into a Python that is shutting down */
static volatile LONG drag_on = 1, overlay_on = 1, paste_on = 1, notch_on = 0;
static const int VK[3] = {VK_SHIFT, VK_CONTROL, VK_MENU};  /* key index: 0 shift, 1 ctrl, 2 alt */

static void emit(int event, int key) {
    if (!stopping) callback(event, key);
}

static int down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

static int from_file_source(void) {
    HWND h = GetForegroundWindow();
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid == GetCurrentProcessId()) return 1;
    wchar_t cls[64] = {0};
    GetClassNameW(h, cls, 64);
    return !lstrcmpW(cls, L"CabinetWClass") || !lstrcmpW(cls, L"ExploreWClass") ||
           !lstrcmpW(cls, L"Progman") || !lstrcmpW(cls, L"WorkerW");
}

/* Ctrl+V meant for a folder view: the keyboard focus is Explorer's file list or the desktop's icons.
 * Anything else (renaming a file, the address or search box) keeps its normal text paste. */
static int paste_into_folder(void) {
    HWND fg = GetForegroundWindow();
    wchar_t cls[64] = {0};
    GetClassNameW(fg, cls, 64);
    if (lstrcmpW(cls, L"CabinetWClass") && lstrcmpW(cls, L"Progman") && lstrcmpW(cls, L"WorkerW")) return 0;
    GUITHREADINFO gti = {sizeof gti};
    if (!GetGUIThreadInfo(GetWindowThreadProcessId(fg, NULL), &gti) || !gti.hwndFocus) return 0;
    GetClassNameW(gti.hwndFocus, cls, 64);
    return !lstrcmpW(cls, L"DirectUIHWND") || !lstrcmpW(cls, L"SysListView32") || !lstrcmpW(cls, L"SHELLDLL_DefView");
}

static int near_top(POINT p) {
    MONITORINFO mi = {sizeof mi};
    return GetMonitorInfoW(MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST), &mi) && p.y - mi.rcMonitor.top < 40;
}

static int quiet_now(void) {
    QUERY_USER_NOTIFICATION_STATE st;
    if (SHQueryUserNotificationState(&st) != S_OK) return 0;
    return st == QUNS_BUSY || st == QUNS_RUNNING_D3D_FULL_SCREEN || st == QUNS_PRESENTATION_MODE;
}

static BOOL CALLBACK fix_overlay(HWND h, LPARAM screen) {
    wchar_t cls[32], title[256];
    if (!IsWindowVisible(h) || !GetClassNameW(h, cls, 32) || lstrcmpW(cls, L"Chrome_WidgetWin_1")) return TRUE;
    int n = GetWindowTextW(h, title, 256);
    if (n < 8 || lstrcmpW(title + n - 8, L"WhatsApp")) return TRUE;
    LONG ex = GetWindowLongW(h, GWL_EXSTYLE);
    if (!(ex & WS_EX_LAYERED) || (ex & WS_EX_TRANSPARENT)) return TRUE;
    BYTE alpha;
    DWORD flags;
    RECT r;
    if (!GetLayeredWindowAttributes(h, NULL, &alpha, &flags) || !GetWindowRect(h, &r)) return TRUE;
    if ((flags & LWA_ALPHA) && alpha == 0 && (LONGLONG)(r.right - r.left) * (r.bottom - r.top) >= screen / 2)
        SetWindowLongW(h, GWL_EXSTYLE, ex | WS_EX_TRANSPARENT);
    return TRUE;
}

static DWORD WINAPI loop(LPVOID unused) {
    int lb = 0, armed = 0, from_files = 0, prev[3] = {0}, v = 0, topped = 0, quiet = 0;
    POINT start = {0}, p;
    for (unsigned tick = 0; !stopping; tick++) {
        Sleep(25);
        if (overlay_on && tick % 80 == 0) {  /* every 2 s */
            LONGLONG screen = (LONGLONG)GetSystemMetrics(SM_CXSCREEN) * GetSystemMetrics(SM_CYSCREEN);
            EnumWindows(fix_overlay, (LPARAM)screen);
        }
        if (notch_on && tick % 40 == 0) {  /* every second: tell Python only when it changes */
            int q = quiet_now();
            if (q != quiet) emit(EV_QUIET, quiet = q);
        }
        int now_lb = down(VK_LBUTTON), now[3];
        GetCursorPos(&p);
        for (int k = 0; k < 3; k++) now[k] = down(VK[k]);
        int now_v = down('V');
        if (paste_on && now_v && !v && now[1] && !now[0] && !now[2] && !down(VK_LWIN) && paste_into_folder())
            emit(EV_PASTE, -1);
        v = now_v;
        if (now_lb && !lb) {
            start = p;
            from_files = from_file_source();
            armed = drag_on && from_files;
            for (int k = 0; k < 3; k++) prev[k] = now[k];
            topped = 0;
        } else if (now_lb && from_files && notch_on && !topped && abs(p.x - start.x) + abs(p.y - start.y) > 12
                   && near_top(p)) {
            emit(EV_DRAG_TOP, -1);
            topped = 1;
        } else if (now_lb && armed && abs(p.x - start.x) + abs(p.y - start.y) > 12) {
            int held = now[0] + now[1] + now[2], tapped = -1;
            for (int k = 0; k < 3; k++)
                if (now[k] && !prev[k]) tapped = k;
            if (held == 1 && tapped >= 0) emit(EV_KEY, tapped);
            for (int k = 0; k < 3; k++) prev[k] = now[k];
        } else if (!now_lb && lb && from_files) {  /* clicks in other apps never wake Python */
            emit(EV_UP, -1);
        }
        lb = now_lb;
    }
    return 0;
}

__declspec(dllexport) int pomeloo_start(pomeloo_cb cb) {
    if (callback || !cb) return 0;
    callback = cb;
    HANDLE t = CreateThread(NULL, 0, loop, NULL, 0, NULL);
    if (!t) return 0;
    CloseHandle(t);
    return 1;
}

__declspec(dllexport) void pomeloo_notch(int on) { InterlockedExchange(&notch_on, on); }

__declspec(dllexport) void pomeloo_stop(void) { InterlockedExchange(&stopping, 1); }

__declspec(dllexport) void pomeloo_config(int drag_wheel, int overlay_fix, int paste_images) {
    InterlockedExchange(&drag_on, drag_wheel);
    InterlockedExchange(&overlay_on, overlay_fix);
    InterlockedExchange(&paste_on, paste_images);
}
