module coordination.cli;

import std.conv : to;
import std.json : JSONValue;
import std.stdio : stderr, writeln;
import std.string : join, startsWith;

import coordination.ident : coordinationBanner;
import coordination.kdl : importSessions;
import coordination.listen : runListen;
import coordination.prohelp_gate : showProhelp;
import coordination.store : Store, defaultDatabasePath, diagnosticsText;

int main(string[] args)
{
    if (showProhelp(args))
        return 0;
    bool asJson;
    string dbPath = defaultDatabasePath();
    string[] rest;
    for (size_t i = 1; i < args.length; i++)
    {
        if (flagName(args[i]) == "json")
            asJson = true;
        else if (flagName(args[i]) == "db" && i + 1 < args.length)
            dbPath = args[++i];
        else if (flagName(args[i]) == "version")
        {
            writeln(coordinationBanner());
            return 0;
        }
        else
            rest ~= args[i];
    }
    if (!rest.length)
    {
        showProhelp(["agent-coordinator", "?"]);
        return 0;
    }
    if (rest[0] == "serve")
    {
        try
            return runListen(rest[1 .. $], asJson, dbPath);
        catch (Exception e)
        {
            stderr.writeln(e.msg);
            return 1;
        }
    }
    auto store = Store.open(dbPath);
    scope (exit)
        store.close();
    try
    {
        return run(store, dbPath, rest, asJson);
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        return 1;
    }
}

private int run(ref Store store, string dbPath, string[] args, bool asJson)
{
    auto cmd = args[0];
    if (cmd == "plan")
    {
        if (args.length < 2)
        {
            stderr.writeln("Missing a plan command.");
            stderr.writeln("Try: agent-coordinator plan boards");
            return 1;
        }
        return runPlan(store, dbPath, args[1 .. $], asJson);
    }
    if (cmd == "schedule")
    {
        if (args.length < 2)
        {
            stderr.writeln("Missing a schedule command.");
            stderr.writeln("Try: agent-coordinator schedule wait --board ID --node ID");
            return 1;
        }
        return runSchedule(store, args[1 .. $]);
    }
    if (cmd == "doctor")
    {
        writeln(diagnosticsText(store, dbPath));
        return 0;
    }
    if (cmd == "account" && args.length > 1 && args[1] == "issue")
    {
        auto opt = flags(args[2 .. $]);
        need(opt, "token");
        need(opt, "plan");
        store.issueToken(opt["token"], opt["plan"], opt.get("label", ""));
        writeln("issued " ~ opt["plan"] ~ " token");
        return 0;
    }
    stderr.writeln("Unknown command " ~ cmd ~ ".");
    stderr.writeln("Run agent-coordinator ? to see plan, schedule, and serve.");
    showProhelp(["agent-coordinator", "?"]);
    return 1;
}

private int runPlan(ref Store store, string dbPath, string[] args, bool asJson)
{
    auto cmd = args[0];
    auto opt = flags(args[1 .. $]);
    if (cmd == "import")
    {
        import std.path : buildPath, dirName;
        auto sessions = opt.get("sessions", buildPath(dirName(dirName(dbPath)), "sessions"));
        auto count = importSessions(store, sessions);
        writeln("imported " ~ count.nodes.to!string ~ " nodes from " ~ sessions);
        return 0;
    }
    if (cmd == "boards")
    {
        auto rows = store.db.execute("SELECT id, title, kind FROM boards ORDER BY id");
        foreach (row; rows)
            writeln(row.peek!string(0) ~ "\t" ~ row.peek!string(2) ~ "\t" ~ row.peek!string(1));
        return 0;
    }
    if (cmd == "tree")
    {
        need(opt, "board");
        auto rows = store.db.execute(
            "SELECT id, parent, status, title, cached_wait_status FROM nodes WHERE board_id=?1 ORDER BY position, id",
            opt["board"]);
        foreach (row; rows)
        {
            auto parent = row.peek!string(1);
            auto wait = row.peek!string(4);
            writeln((parent.length ? parent ~ "/" : "") ~ row.peek!string(0) ~ "\t" ~ row.peek!string(2)
                ~ (wait.length ? "\twait=" ~ wait : "") ~ "\t" ~ row.peek!string(3));
        }
        return 0;
    }
    if (cmd == "path")
    {
        need(opt, "board");
        need(opt, "node");
        writeln(join(store.pathTo(opt["board"], opt["node"]), " / "));
        return 0;
    }
    if (cmd == "node")
    {
        need(opt, "board");
        need(opt, "id");
        need(opt, "title");
        store.upsertNode(opt["board"], opt["id"], opt["title"], opt.get("status", "open"), opt.get("parent", ""),
            opt.get("position", "0").to!long, opt.get("summary", ""), opt.get("plan", ""), opt.get("repo", ""),
            opt.get("quote", ""), opt.get("cursor-chat", ""), 0, 0, false, false);
        writeln("saved node " ~ opt["id"]);
        return 0;
    }
    if (cmd == "record-move")
    {
        foreach (name; ["canonical", "from-cursor-chat", "to-cursor-chat", "from-project-key", "to-project-key", "from-root", "to-root"])
            need(opt, name);
        store.recordMove(opt["canonical"], opt["from-cursor-chat"], opt["to-cursor-chat"], opt["from-project-key"],
            opt["to-project-key"], opt["from-root"], opt["to-root"], opt.get("from-workspace-uri", ""), opt.get("to-workspace-uri", ""));
        auto line = "status: recorded\nreason: workspace-move\ncanonical: " ~ opt["canonical"]
            ~ "\nhint: Recorded the new transcript folder as an alias of " ~ opt["canonical"] ~ ".";
        writeln(asJson ? jsonStatus("recorded", "workspace-move", opt["canonical"]) : line);
        return 0;
    }
    if (cmd == "resolve")
    {
        need(opt, "chat");
        auto hit = store.resolve(opt["chat"], opt.get("cursor-chat", ""), opt.get("segment", ""), opt.get("quote", ""));
        if (asJson)
            writeln(jsonHit(hit.status, hit.reason, hit.hint, hit.canonical, hit.path));
        else
            writeln("status: " ~ hit.status ~ "\nreason: " ~ hit.reason ~ "\ncanonical: " ~ hit.canonical
                ~ "\npath: " ~ hit.path ~ "\nhint: " ~ hit.hint);
        return hit.code;
    }
    if (cmd == "repair")
    {
        need(opt, "chat");
        store.repair(opt["chat"], opt.get("cursor-chat", ""), opt.get("live-root", ""), opt.get("project-key", ""),
            ("files-moved" in opt) !is null);
        writeln("status: repaired\nhint: Marked the live folder current and kept the old keys.");
        return 0;
    }
    stderr.writeln("Unknown plan command " ~ cmd ~ ".");
    stderr.writeln("Try: agent-coordinator plan boards");
    return 1;
}

private int runSchedule(ref Store store, string[] args)
{
    auto cmd = args[0];
    auto opt = flags(args[1 .. $]);
    if (cmd == "wait")
    {
        need(opt, "board");
        need(opt, "node");
        auto id = opt.get("id", opt["node"] ~ "-wait");
        store.upsertWait(id, opt["board"], opt["node"], opt.get("position", "0").to!long,
            opt.get("estimate-ms", "0").to!long, opt.get("status", "pending"), opt.get("wait-hub", ""),
            opt.get("harness", ""), opt.get("session", ""));
        writeln("saved wait " ~ id ~ " on node " ~ opt["node"]);
        return 0;
    }
    stderr.writeln("Unknown schedule command " ~ cmd ~ ".");
    stderr.writeln("Try: agent-coordinator schedule wait --board ID --node ID");
    return 1;
}

private string[string] flags(string[] args)
{
    string[string] opt;
    for (size_t i = 0; i < args.length; i++)
    {
        auto name = flagName(args[i]);
        if (!name.length)
            continue;
        if (name == "files-moved")
        {
            opt[name] = "true";
            continue;
        }
        if (i + 1 >= args.length)
            throw new Exception("Missing value for --" ~ name);
        opt[name] = args[++i];
    }
    return opt;
}

private void need(string[string] opt, string name)
{
    if ((name in opt) is null || !opt[name].length)
        throw new Exception("missing --" ~ name);
}

private string jsonStatus(string status, string reason, string canonical)
{
    JSONValue doc;
    doc["status"] = status;
    doc["reason"] = reason;
    doc["canonical"] = canonical;
    return doc.toString();
}

private string jsonHit(string status, string reason, string hint, string canonical, string path)
{
    JSONValue doc;
    doc["status"] = status;
    doc["reason"] = reason;
    doc["hint"] = hint;
    doc["canonical"] = canonical;
    doc["path"] = path;
    return doc.toString();
}

private string flagName(string arg)
{
    if (arg.startsWith("--") && arg.length > 2)
        return arg[2 .. $];
    if (arg.length > 1 && arg[0] == '-' && arg[1] != '-')
        return arg[1 .. $];
    return "";
}

private string get(string[string] opt, string key, string fallback)
{
    return (key in opt) is null ? fallback : opt[key];
}
