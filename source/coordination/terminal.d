module coordination.terminal;

import std.conv : to;
import std.process : environment, thisProcessID;
import std.string : endsWith, strip, toLower;

struct TerminalRef
{
    string name = "this terminal";
    int pid;
    string session;
    string title;
}

string friendlyName(string exe)
{
    auto n = baseName(exe);
    switch (n)
    {
    case "windowsterminal", "wt":
        return "Windows Terminal";
    case "cursor":
        return "Cursor";
    case "code":
        return "Visual Studio Code";
    default:
        return "";
    }
}

bool skipProcess(string exe)
{
    auto n = baseName(exe);
    switch (n)
    {
    case "agent-coordinator", "coordinationd", "dub", "ldc2", "dmd",
            "powershell", "pwsh", "cmd", "conhost", "openconsole":
        return true;
    default:
        return false;
    }
}

string terminalLine(TerminalRef terminal)
{
    auto line = terminal.name ~ " pid " ~ terminal.pid.to!string;
    if (terminal.session.length)
        line ~= " session " ~ terminal.session;
    return line;
}

TerminalRef currentTerminal()
{
    TerminalRef found;
    found.pid = thisProcessID;
    found.session = environment.get("WT_SESSION", "");
    found.title = consoleTitle();
    auto chain = parentChain();
    TerminalRef fallback;
    foreach (step; chain)
    {
        if (skipProcess(step.exe))
            continue;
        auto named = friendlyName(step.exe);
        if (named.length)
        {
            found.name = named;
            found.pid = step.pid;
            return found;
        }
        if (!fallback.name.length || fallback.name == "this terminal")
        {
            fallback.name = baseName(step.exe);
            fallback.pid = step.pid;
        }
    }
    if (fallback.name.length)
        found.name = fallback.name;
    if (fallback.pid)
        found.pid = fallback.pid;
    return found;
}

private struct Step
{
    int pid;
    string exe;
}

private string baseName(string exe)
{
    auto n = exe.toLower();
    auto slash = n.lastIndexOfAny("\\/");
    if (slash >= 0)
        n = n[slash + 1 .. $];
    if (n.endsWith(".exe"))
        n = n[0 .. $ - 4];
    return n;
}

private long lastIndexOfAny(string text, string chars)
{
    import std.string : lastIndexOf;

    long at = -1;
    foreach (ch; chars)
    {
        auto found = text.lastIndexOf(ch);
        if (found > at)
            at = found;
    }
    return at;
}

private string consoleTitle()
{
    version (Windows)
    {
        import core.sys.windows.wincon : GetConsoleTitleW;

        wchar[256] buf;
        auto n = GetConsoleTitleW(buf.ptr, buf.length);
        if (n == 0)
            return "";
        return to!string(buf[0 .. n]);
    }
    else
        return "";
}

private Step[] parentChain()
{
    version (Windows)
        return windowsChain();
    else
        return posixChain();
}

version (Windows)
private Step[] windowsChain()
{
    import core.sys.windows.tlhelp32;
    import core.sys.windows.winbase : CloseHandle, INVALID_HANDLE_VALUE;
    import core.sys.windows.windef : DWORD;
    import core.sys.windows.windows : GetCurrentProcessId;
    import std.string : fromStringz;

    Step[] chain;
    static struct Row
    {
        DWORD parent;
        string exe;
    }

    Row[DWORD] rows;
    auto snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return chain;
    scope (exit)
        CloseHandle(snap);
    PROCESSENTRY32W entry;
    entry.dwSize = PROCESSENTRY32W.sizeof;
    if (!Process32FirstW(snap, &entry))
        return chain;
    do
    {
        Row row;
        row.parent = entry.th32ParentProcessID;
        row.exe = to!string(fromStringz(entry.szExeFile.ptr));
        rows[entry.th32ProcessID] = row;
    }
    while (Process32NextW(snap, &entry));
    auto pid = GetCurrentProcessId();
    for (int hop = 0; hop < 16 && pid && (pid in rows); hop++)
    {
        chain ~= Step(cast(int) pid, rows[pid].exe);
        auto parent = rows[pid].parent;
        if (parent == pid)
            break;
        pid = parent;
    }
    return chain;
}

version (Posix)
private Step[] posixChain()
{
    import std.file : exists, readText;

    Step[] chain;
    auto pid = thisProcessID;
    for (int hop = 0; hop < 16 && pid > 0; hop++)
    {
        auto dir = "/proc/" ~ pid.to!string;
        if (!exists(dir ~ "/comm"))
            break;
        chain ~= Step(pid, readText(dir ~ "/comm").strip());
        auto status = readText(dir ~ "/status");
        int parent;
        foreach (line; status.splitLines())
        {
            if (line.length < 6 || line[0 .. 5] != "PPid:")
                continue;
            import std.conv : to;

            parent = to!int(line[5 .. $].strip());
            break;
        }
        if (parent == pid)
            break;
        pid = parent;
    }
    return chain;
}

version (Posix)
private import std.string : splitLines;

unittest
{
    assert(friendlyName("Cursor.exe") == "Cursor");
    assert(friendlyName("WindowsTerminal.exe") == "Windows Terminal");
    assert(skipProcess("powershell.exe"));
    assert(!skipProcess("Cursor.exe"));
    TerminalRef sample;
    sample.name = "Cursor";
    sample.pid = 12044;
    assert(terminalLine(sample) == "Cursor pid 12044");
}
