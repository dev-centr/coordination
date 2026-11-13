module coordination.supervisor;

import core.thread : Thread;
import core.time : dur, msecs;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, thisExePath;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName, baseName, stripExtension;
import std.process : Config, Pid, spawnProcess, tryWait;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketSet, TcpSocket;
import std.stdio : File, stderr, writeln;
import std.string : join, splitLines, startsWith, strip, toLower;

import coordination.ident : coordinationBanner;
import coordination.serve : serve;
import coordination.store : Store, defaultDatabasePath;
import coordination.terminal : TerminalRef, currentTerminal, terminalLine;

enum ushort managerPort = 17360;

struct ServeOpts
{
    string dbPath;
    string bindAddr = "127.0.0.1";
    ushort port = 17359;
    string appDir = "app";
    bool publicMode;
    bool listen;
    bool manager;
    bool worker;
    bool version_;
    string action = "start";
    int stopId = -2;
    string error;
}

int dispatchServe(string[] args, bool asJson, string inheritedDb)
{
    auto opt = parseServe(args, inheritedDb);
    if (opt.action == "help")
    {
        import coordination.prohelp_gate : showProhelpPath;

        showProhelpPath("serve");
        return 0;
    }
    if (opt.version_)
    {
        writeln(coordinationBanner());
        return 0;
    }
    if (opt.error.length)
    {
        stderr.writeln(opt.error);
        stderr.writeln("Run agent-coordinator ? serve to see the server flags.");
        return 1;
    }
    if (opt.manager)
        return runManager();
    if (opt.worker)
        return runWorker(opt);
    if (opt.action == "status")
        return runStatus(asJson);
    if (opt.action == "stop")
        return runStop(opt, asJson);
    if (opt.listen)
        return runForeground(opt);
    return runBackground(opt, asJson);
}

ServeOpts parseServe(string[] args, string inheritedDb)
{
    ServeOpts opt;
    opt.dbPath = inheritedDb.length ? inheritedDb : defaultDatabasePath();
    opt.appDir = findApp();
    string[] words;
    for (size_t i = 0; i < args.length; i++)
    {
        auto a = args[i];
        auto name = flagName(a);
        if (a == "?" || a == "help" || name == "help" || name == "h")
        {
            opt.action = "help";
            return opt;
        }
        if (name == "version")
        {
            opt.version_ = true;
            return opt;
        }
        if (name == "listen")
        {
            opt.listen = true;
            continue;
        }
        if (name == "manager")
        {
            opt.manager = true;
            continue;
        }
        if (name == "worker")
        {
            opt.worker = true;
            continue;
        }
        if (name == "public")
        {
            opt.publicMode = true;
            if (opt.bindAddr == "127.0.0.1")
                opt.bindAddr = "0.0.0.0";
            continue;
        }
        if (name == "db" && i + 1 < args.length)
            opt.dbPath = args[++i];
        else if (name == "bind" && i + 1 < args.length)
            opt.bindAddr = args[++i];
        else if (name == "port" && i + 1 < args.length)
            opt.port = to!ushort(args[++i]);
        else if (name == "app" && i + 1 < args.length)
            opt.appDir = args[++i];
        else if (a.startsWith("-"))
        {
            opt.error = "Unknown argument " ~ a ~ ".";
            return opt;
        }
        else
            words ~= a;
    }
    if (!words.length)
        return opt;
    if (words[0] == "status" && words.length == 1)
    {
        opt.action = "status";
        return opt;
    }
    if (words[0] == "stop")
    {
        opt.action = "stop";
        opt.stopId = parseServerId(words[1 .. $]);
        if (opt.stopId < 0)
            opt.error = "Unknown server id \"" ~ words[1 .. $].join(" ") ~ "\".";
        return opt;
    }
    opt.error = "Unknown argument " ~ words[0] ~ ".";
    return opt;
}

int parseServerId(string[] words)
{
    if (!words.length)
        return 0;
    auto text = words.join("").toLower();
    if (text.startsWith("server"))
        text = text[6 .. $];
    if (!text.length)
        return -1;
    foreach (ch; text)
    {
        if (ch < '0' || ch > '9')
            return -1;
    }
    return to!int(text);
}

string detachCard(string banner, int id, int pid, string address, string spawnedBy, string logPath)
{
    return banner ~ "\n"
        ~ "server " ~ id.to!string ~ " is running in the background.\n"
        ~ "id: " ~ id.to!string ~ "\n"
        ~ "pid: " ~ pid.to!string ~ "\n"
        ~ "address: " ~ address ~ "\n"
        ~ "spawned by: " ~ spawnedBy ~ "\n"
        ~ "stop: agent-coordinator serve stop " ~ id.to!string ~ "\n"
        ~ "status: agent-coordinator serve status\n"
        ~ "Use -listen when you want the lines in this window.\n"
        ~ logPath;
}

string listenCard(string banner, int id, int pid, string address, string where)
{
    return banner ~ "\n"
        ~ "server " ~ id.to!string ~ " is showing its lines in this window.\n"
        ~ "id: " ~ id.to!string ~ "\n"
        ~ "pid: " ~ pid.to!string ~ "\n"
        ~ "address: " ~ address ~ "\n"
        ~ "listening in: " ~ where ~ "\n"
        ~ "stop: agent-coordinator serve stop " ~ id.to!string;
}

private int runBackground(ServeOpts opt, bool asJson)
{
    auto term = currentTerminal();
    ensureManager(opt.dbPath);
    JSONValue req;
    req["cmd"] = "start";
    req["mode"] = "detached";
    fillRequest(req, opt, term);
    auto reply = exchange(req.toString());
    if (!reply["ok"].get!bool)
    {
        stderr.writeln(reply["error"].get!string);
        return 1;
    }
    if (asJson)
    {
        writeln(reply.toPrettyString());
        return 0;
    }
    writeln(detachCard(
            coordinationBanner(),
            cast(int) reply["id"].get!long,
            cast(int) reply["pid"].get!long,
            reply["address"].get!string,
            reply["spawnedBy"].get!string,
            reply["log"].get!string));
    return 0;
}

private int runForeground(ServeOpts opt)
{
    auto term = currentTerminal();
    auto line = terminalLine(term);
    ensureManager(opt.dbPath);
    JSONValue req;
    req["cmd"] = "register";
    req["mode"] = "listen";
    req["pid"] = thisProcessId();
    fillRequest(req, opt, term);
    auto reply = exchange(req.toString());
    if (!reply["ok"].get!bool)
    {
        stderr.writeln(reply["error"].get!string);
        return 1;
    }
    auto id = cast(int) reply["id"].get!long;
    scope (exit)
        forgetInstance(id);
    writeln(listenCard(coordinationBanner(), id, thisProcessId(), addressOf(opt), line));
    return runWorker(opt);
}

private int runStatus(bool asJson)
{
    if (!managerUp())
    {
        if (asJson)
            writeln(`{"instances":[]}`);
        else
            writeln("No servers are running.");
        return 0;
    }
    JSONValue req;
    req["cmd"] = "status";
    auto reply = exchange(req.toString());
    if (asJson)
    {
        writeln(reply.toPrettyString());
        return 0;
    }
    writeln(statusText(reply));
    return 0;
}

private int runStop(ServeOpts opt, bool asJson)
{
    if (!managerUp())
    {
        stderr.writeln("No servers are running.");
        return 1;
    }
    JSONValue req;
    req["cmd"] = "stop";
    if (opt.stopId == 0)
        req["all"] = true;
    else
        req["id"] = opt.stopId;
    auto reply = exchange(req.toString());
    if (!reply["ok"].get!bool)
    {
        stderr.writeln(reply["error"].get!string);
        return 1;
    }
    if (asJson)
        writeln(reply.toPrettyString());
    else if (opt.stopId == 0)
        writeln("Stopped every server.");
    else
        writeln("Stopped server " ~ opt.stopId.to!string ~ ".");
    return 0;
}

private int runWorker(ServeOpts opt)
{
    writeln(coordinationBanner());
    writeln("database: " ~ opt.dbPath);
    writeln("listening: " ~ addressOf(opt) ~ (opt.publicMode ? " (hosted)" : ""));
    auto store = Store.open(opt.dbPath);
    scope (exit)
        store.close();
    serve(store, opt.bindAddr, opt.port, opt.appDir, opt.publicMode);
    return 0;
}

private void fillRequest(ref JSONValue req, ServeOpts opt, TerminalRef term)
{
    req["bind"] = opt.bindAddr;
    req["port"] = opt.port;
    req["db"] = opt.dbPath;
    req["app"] = opt.appDir;
    req["public"] = opt.publicMode;
    req["spawnedBy"] = terminalLine(term);
    req["log"] = instanceLog(opt.dbPath, opt.port);
}

private string addressOf(ServeOpts opt)
{
    auto host = opt.bindAddr == "0.0.0.0" ? "127.0.0.1" : opt.bindAddr;
    return "http://" ~ host ~ ":" ~ opt.port.to!string;
}

private string instanceLog(string dbPath, ushort port)
{
    return buildPath(dirName(dbPath), "logs", port.to!string ~ ".log");
}

private string managerLog(string dbPath)
{
    return buildPath(dirName(dbPath), "logs", "manager.log");
}

private bool managerUp()
{
    try
    {
        JSONValue req;
        req["cmd"] = "ping";
        auto reply = exchange(req.toString());
        return reply["ok"].get!bool;
    }
    catch (Exception)
    {
        return false;
    }
}

private void ensureManager(string dbPath)
{
    if (managerUp())
        return;
    auto logPath = managerLog(dbPath);
    mkdirRecurse(dirName(logPath));
    auto exe = thisExePath();
    string[] args = [exe];
    if (coordinatorExe(exe))
        args ~= "serve";
    args ~= "-manager";
    auto nul = nullFile();
    auto log = File(logPath, "a");
    spawnProcess(args, nul, log, log, null, Config.detached | Config.suppressConsole);
    for (int i = 0; i < 40; i++)
    {
        Thread.sleep(100.msecs);
        if (managerUp())
            return;
    }
    throw new Exception("The manager did not start. The log is " ~ logPath);
}

private bool coordinatorExe(string exe)
{
    return baseName(stripExtension(exe)).toLower().startsWith("agent-coordinator");
}

private File nullFile()
{
    version (Windows)
        return File("NUL", "r");
    else
        return File("/dev/null", "r");
}

private int thisProcessId()
{
    import std.process : thisProcessID;

    return thisProcessID;
}

private void forgetInstance(int id)
{
    try
    {
        JSONValue gone;
        gone["cmd"] = "forget";
        gone["id"] = id;
        exchange(gone.toString());
    }
    catch (Exception)
    {
    }
}

private JSONValue exchange(string line)
{
    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", managerPort));
    scope (exit)
        socket.close();
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(8));
    auto payload = line ~ "\n";
    socket.send(payload);
    char[] buf;
    while (!buf.canFind('\n'))
    {
        char[512] chunk;
        auto n = socket.receive(chunk);
        if (n <= 0)
            break;
        buf ~= chunk[0 .. n];
    }
    auto text = buf.strip();
    if (!text.length)
        throw new Exception("The manager closed the connection.");
    return parseJSON(text);
}

private struct Inst
{
    int id;
    int osPid;
    Pid child;
    string mode;
    string address;
    string logPath;
    string spawnedBy;
    string listening;
    ushort port;
}

private int runManager()
{
    Inst[] items;
    int nextId = 1;
    bool startedAny;
    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    listener.blocking = false;
    listener.bind(new InternetAddress("127.0.0.1", managerPort));
    listener.listen(8);
    int idle = 0;
    while (true)
    {
        auto reads = new SocketSet(8);
        reads.add(listener);
        Socket.select(reads, null, null, dur!"msecs"(200));
        if (reads.isSet(listener))
        {
            try
            {
                auto client = listener.accept();
                scope (exit)
                    client.close();
                client.blocking = true;
                auto line = readClientLine(client);
                auto reply = handleManager(line, items, nextId, startedAny);
                auto bytes = reply ~ "\n";
                client.send(bytes);
            }
            catch (Exception)
            {
            }
        }
        reap(items);
        if (startedAny && items.length == 0)
            break;
        if (!startedAny)
        {
            idle++;
            if (idle > 50)
                break;
        }
        else
            idle = 0;
    }
    return 0;
}

private string readClientLine(Socket client)
{
    char[] buf;
    while (!buf.canFind('\n') && buf.length < 8192)
    {
        char[512] chunk;
        auto n = client.receive(chunk);
        if (n <= 0)
            break;
        buf ~= chunk[0 .. n];
    }
    return buf.strip().idup;
}

private string handleManager(string line, ref Inst[] items, ref int nextId, ref bool startedAny)
{
    JSONValue req;
    try
        req = parseJSON(line);
    catch (Exception)
    {
        return fail("The manager could not read that request.");
    }
    auto cmd = req["cmd"].get!string;
    if (cmd == "ping")
    {
        JSONValue ok;
        ok["ok"] = true;
        return ok.toString();
    }
    if (cmd == "status")
        return statusReply(items);
    if (cmd == "stop")
        return stopReply(req, items);
    if (cmd == "forget")
    {
        auto id = cast(int) req["id"].get!long;
        dropId(items, id);
        JSONValue ok;
        ok["ok"] = true;
        return ok.toString();
    }
    if (cmd == "start")
        return startReply(req, items, nextId, startedAny);
    if (cmd == "register")
        return registerReply(req, items, nextId, startedAny);
    return fail("Unknown manager command.");
}

private string startReply(JSONValue req, ref Inst[] items, ref int nextId, ref bool startedAny)
{
    auto port = cast(ushort) req["port"].get!long;
    foreach (item; items)
    {
        if (item.port == port)
            return fail("server " ~ item.id.to!string ~ " is already on port " ~ port.to!string ~ ".");
    }
    auto logPath = req["log"].get!string;
    mkdirRecurse(dirName(logPath));
    auto exe = thisExePath();
    string[] args = [exe];
    if (coordinatorExe(exe))
        args ~= "serve";
    args ~= [
        "-worker", "-db", req["db"].get!string, "-bind", req["bind"].get!string,
        "-port", port.to!string, "-app", req["app"].get!string
    ];
    if (req["public"].get!bool)
        args ~= "-public";
    Pid child;
    try
    {
        auto nul = nullFile();
        auto log = File(logPath, "w");
        child = spawnProcess(args, nul, log, log, null, Config.suppressConsole);
    }
    catch (Exception e)
    {
        return fail("Could not start the server. " ~ e.msg);
    }
    auto bound = false;
    for (int i = 0; i < 20; i++)
    {
        auto waited = tryWait(child);
        if (waited.terminated)
            return fail("The server stopped. " ~ logTail(logPath));
        if (portOpen(req["bind"].get!string, port))
        {
            bound = true;
            break;
        }
        Thread.sleep(100.msecs);
    }
    if (!bound && !processAlive(child.processID))
        return fail("The server stopped. " ~ logTail(logPath));
    Inst item;
    item.id = nextId++;
    item.osPid = child.processID;
    item.child = child;
    item.mode = "detached";
    item.port = port;
    item.logPath = logPath;
    item.spawnedBy = req["spawnedBy"].get!string;
    item.address = "http://" ~ req["bind"].get!string ~ ":" ~ port.to!string;
    items ~= item;
    startedAny = true;
    return instanceReply(item);
}

private string registerReply(JSONValue req, ref Inst[] items, ref int nextId, ref bool startedAny)
{
    auto port = cast(ushort) req["port"].get!long;
    foreach (item; items)
    {
        if (item.port == port)
            return fail("server " ~ item.id.to!string ~ " is already on port " ~ port.to!string ~ ".");
    }
    Inst item;
    item.id = nextId++;
    item.osPid = cast(int) req["pid"].get!long;
    item.mode = "listen";
    item.port = port;
    item.logPath = "";
    item.spawnedBy = req["spawnedBy"].get!string;
    item.listening = req["spawnedBy"].get!string;
    item.address = "http://" ~ req["bind"].get!string ~ ":" ~ port.to!string;
    items ~= item;
    startedAny = true;
    return instanceReply(item);
}

private string instanceReply(Inst item)
{
    JSONValue ok;
    ok["ok"] = true;
    ok["id"] = item.id;
    ok["pid"] = item.osPid;
    ok["mode"] = item.mode;
    ok["address"] = item.address;
    ok["log"] = item.logPath;
    ok["spawnedBy"] = item.spawnedBy;
    ok["listening"] = item.listening;
    return ok.toString();
}

private string stopReply(JSONValue req, ref Inst[] items)
{
    if ("all" in req && req["all"].get!bool)
    {
        foreach (item; items)
            endProcess(item);
        items = [];
        JSONValue ok;
        ok["ok"] = true;
        return ok.toString();
    }
    auto id = cast(int) req["id"].get!long;
    bool found;
    Inst[] kept;
    foreach (item; items)
    {
        if (item.id != id)
        {
            kept ~= item;
            continue;
        }
        endProcess(item);
        found = true;
    }
    items = kept;
    if (!found)
        return fail("No server " ~ id.to!string ~ ". Run agent-coordinator serve status.");
    JSONValue ok;
    ok["ok"] = true;
    ok["id"] = id;
    return ok.toString();
}

private string statusReply(Inst[] items)
{
    JSONValue ok;
    ok["ok"] = true;
    JSONValue[] rows;
    foreach (item; items)
    {
        JSONValue row;
        row["id"] = item.id;
        row["mode"] = item.mode;
        row["pid"] = item.osPid;
        row["address"] = item.address;
        row["log"] = item.logPath;
        row["spawnedBy"] = item.spawnedBy;
        row["listening"] = item.listening.length ? item.listening : "output is in the log";
        rows ~= row;
    }
    ok["instances"] = rows;
    return ok.toString();
}

private string statusText(JSONValue reply)
{
    auto rows = reply["instances"].array;
    if (!rows.length)
        return "No servers are running.";
    string[] lines;
    string[][string] byTerminal;
    foreach (row; rows)
    {
        auto id = row["id"].get!long;
        auto mode = row["mode"].get!string;
        auto spawned = row["spawnedBy"].get!string;
        lines ~= "server " ~ id.to!string ~ "  " ~ mode ~ "  pid " ~ to!string(row["pid"].get!long)
            ~ "  " ~ row["address"].get!string;
        lines ~= "  spawned by " ~ spawned;
        if (mode == "listen")
            lines ~= "  listening in " ~ row["listening"].get!string;
        else
        {
            lines ~= "  output is in the log";
            lines ~= "  " ~ row["log"].get!string;
        }
        byTerminal[spawned] ~= "server " ~ id.to!string;
    }
    lines ~= "";
    lines ~= "Terminals";
    foreach (name, ids; byTerminal)
    {
        lines ~= "  " ~ name;
        foreach (id; ids)
            lines ~= "    " ~ id;
    }
    return lines.join("\n");
}

private void dropId(ref Inst[] items, int id)
{
    Inst[] kept;
    foreach (item; items)
    {
        if (item.id != id)
            kept ~= item;
    }
    items = kept;
}

private void reap(ref Inst[] items)
{
    Inst[] kept;
    foreach (item; items)
    {
        if (item.child !is null)
        {
            auto waited = tryWait(item.child);
            if (waited.terminated)
                continue;
        }
        else if (!processAlive(item.osPid))
            continue;
        kept ~= item;
    }
    items = kept;
}

private void endProcess(Inst item)
{
    if (item.child !is null)
    {
        try
        {
            import std.process : kill;

            kill(item.child);
            tryWait(item.child);
            return;
        }
        catch (Exception)
        {
        }
    }
    forceStop(item.osPid);
}

private bool portOpen(string bind, ushort port)
{
    auto host = bind == "0.0.0.0" ? "127.0.0.1" : bind;
    try
    {
        auto socket = new TcpSocket(new InternetAddress(host, port));
        socket.close();
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

private bool processAlive(int pid)
{
    if (pid <= 0)
        return false;
    version (Windows)
    {
        import core.sys.windows.winbase : CloseHandle, GetExitCodeProcess, OpenProcess;
        import core.sys.windows.windef : DWORD;

        enum DWORD query = 0x1000;
        enum DWORD stillActive = 259;
        auto handle = OpenProcess(query, 0, pid);
        if (handle is null)
            return false;
        scope (exit)
            CloseHandle(handle);
        DWORD code;
        if (!GetExitCodeProcess(handle, &code))
            return false;
        return code == stillActive;
    }
    else
    {
        import core.sys.posix.signal : kill;

        return kill(pid, 0) == 0;
    }
}

private void forceStop(int pid)
{
    if (pid <= 0)
        return;
    version (Windows)
    {
        import core.sys.windows.winbase : CloseHandle, OpenProcess, TerminateProcess;

        enum uint terminate = 0x0001;
        auto handle = OpenProcess(terminate, 0, pid);
        if (handle is null)
            return;
        scope (exit)
            CloseHandle(handle);
        TerminateProcess(handle, 1);
    }
    else
    {
        import core.sys.posix.signal : SIGTERM, kill;

        kill(pid, SIGTERM);
    }
}

private string fail(string message)
{
    JSONValue bad;
    bad["ok"] = false;
    bad["error"] = message;
    return bad.toString();
}

private string logTail(string path)
{
    if (!exists(path))
        return "No log at " ~ path;
    auto lines = readText(path).splitLines;
    if (!lines.length)
        return "The log is empty: " ~ path;
    auto start = lines.length > 12 ? lines.length - 12 : 0;
    return lines[start .. $].join(" ");
}

private string findApp()
{
    if (exists("app/index.html"))
        return "app";
    auto beside = buildPath(dirName(thisExePath()), "app");
    if (exists(buildPath(beside, "index.html")))
        return beside;
    return "app";
}

private string flagName(string arg)
{
    if (arg.startsWith("--"))
        return arg[2 .. $];
    if (arg.startsWith("-"))
        return arg[1 .. $];
    return "";
}

unittest
{
    assert(parseServerId([]) == 0);
    assert(parseServerId(["1"]) == 1);
    assert(parseServerId(["server", "2"]) == 2);
    assert(parseServerId(["server1"]) == 1);
    assert(parseServerId(["nope"]) == -1);
    auto card = detachCard("agent-coordinator 0.1.0 (dev)", 1, 42, "http://127.0.0.1:17359", "Cursor pid 9", `C:\logs\17359.log`);
    assert(card.canFind("-listen"));
    assert(card.canFind("serve stop 1"));
    auto tail = card.splitLines[$ - 1];
    assert(tail == `C:\logs\17359.log`);
}
