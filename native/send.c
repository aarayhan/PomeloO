/* pomeloo-send.exe: what the Explorer menu runs. Hands one request to the running tray app over
 * \\.\pipe\pomeloo-<USERNAME> as JSON {"kind","id","paths"} and exits in milliseconds, instead of
 * booting Python + Qt once per selected file. Starts PomeloO.exe (same folder) if it isn't running.
 *
 *   pomeloo-send.exe convert|tool|action ID PATH...
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>

static char *out;
static size_t len, cap;

static void put(const char *s, size_t n) {
    if (len + n + 1 > cap) {
        cap = (len + n + 1) * 2;
        out = HeapReAlloc(GetProcessHeap(), 0, out, cap);
    }
    CopyMemory(out + len, s, n);
    len += n;
}

static void put_str(const wchar_t *w) {  /* UTF-16 -> JSON string (UTF-8, escaped) */
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *u = HeapAlloc(GetProcessHeap(), 0, n);
    WideCharToMultiByte(CP_UTF8, 0, w, -1, u, n, NULL, NULL);
    put("\"", 1);
    for (char *c = u; *c; c++) {
        if (*c == '"' || *c == '\\') {
            put("\\", 1);
            put(c, 1);
        } else if ((unsigned char)*c < 0x20) {
            char esc[7];
            wsprintfA(esc, "\\u%04x", (unsigned char)*c);
            put(esc, 6);
        } else {
            put(c, 1);
        }
    }
    put("\"", 1);
    HeapFree(GetProcessHeap(), 0, u);
}

static void start_app(void) {
    wchar_t exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
    while (n && exe[n - 1] != L'\\') n--;
    lstrcpyW(exe + n, L"PomeloO.exe");
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    if (CreateProcessW(exe, NULL, NULL, NULL, FALSE, DETACHED_PROCESS, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show) {
    int argc;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 4) return 2;
    cap = 4096;
    out = HeapAlloc(GetProcessHeap(), 0, cap);
    put("{\"kind\":", 8);
    put_str(argv[1]);
    put(",\"id\":", 6);
    put_str(argv[2]);
    put(",\"paths\":[", 10);
    for (int i = 3; i < argc; i++) {
        wchar_t full[32768];
        if (!GetFullPathNameW(argv[i], 32768, full, NULL)) continue;
        if (i > 3) put(",", 1);
        put_str(full);
    }
    put("]}", 2);

    wchar_t pipe[300] = L"\\\\.\\pipe\\pomeloo-", user[256];
    if (!GetEnvironmentVariableW(L"USERNAME", user, 256)) lstrcpyW(user, L"user");
    lstrcatW(pipe, user);
    for (int attempt = 0; attempt < 150; attempt++) {  /* up to ~15 s while the app boots */
        HANDLE h = CreateFileW(pipe, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD done;
            BOOL ok = WriteFile(h, out, (DWORD)len, &done, NULL) && done == len;
            FlushFileBuffers(h);  /* wait until the app has read it */
            CloseHandle(h);
            return ok ? 0 : 1;
        }
        if (GetLastError() == ERROR_PIPE_BUSY) {
            WaitNamedPipeW(pipe, 2000);
            continue;
        }
        if (attempt == 0) start_app();
        Sleep(100);
    }
    return 1;
}
