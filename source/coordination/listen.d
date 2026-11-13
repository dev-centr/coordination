module coordination.listen;

import std.conv : to;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.stdio : stderr, writeln;

import coordination.ident : coordinationBanner;
import coordination.serve : serve;
import coordination.store : Store, defaultDatabasePath;

int runListen(string[] args)
{
    string dbPath = defaultDatabasePath();
    string bindAddr = "127.0.0.1";
    ushort port = 17359;
    bool publicMode;
    string appDir = findApp();
    for (size_t i = 0; i < args.length; i++)
    {
        auto a = args[i];
        if (a == "--help" || a == "-h")
        {
            writeln(listenHelp());
            return 0;
        }
        if (a == "--version")
        {
            writeln(coordinationBanner());
            return 0;
        }
        if (a == "--public")
        {
            publicMode = true;
            if (bindAddr == "127.0.0.1")
                bindAddr = "0.0.0.0";
            continue;
        }
        if (a == "--db" && i + 1 < args.length)
            dbPath = args[++i];
        else if (a == "--bind" && i + 1 < args.length)
            bindAddr = args[++i];
        else if (a == "--port" && i + 1 < args.length)
            port = to!ushort(args[++i]);
        else if (a == "--app" && i + 1 < args.length)
            appDir = args[++i];
        else
        {
            stderr.writeln("Unknown argument " ~ a ~ ".");
            stderr.writeln("Run agent-coordinator serve --help for the server flags.");
            return 1;
        }
    }
    writeln(coordinationBanner());
    writeln("database: " ~ dbPath);
    writeln("listening: http://" ~ bindAddr ~ ":" ~ to!string(port) ~ (publicMode ? " (hosted)" : ""));
    auto store = Store.open(dbPath);
    scope (exit)
        store.close();
    serve(store, bindAddr, port, appDir, publicMode);
    return 0;
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

string listenHelp()
{
    return coordinationBanner() ~ `

Opens the plan database and a page that lists plans and the waits on them.

  agent-coordinator serve
      Listens on http://127.0.0.1:17359. This machine needs no token.
  agent-coordinator serve --public [--bind ADDR] [--port N]
      Accepts a hosted token. Dev-Centr issues that token for the online database.
      A workstation token is refused on this bind.

  --db PATH    database file
  --bind ADDR  address
  --port N     port
  --app DIR    folder that holds the browser page
`;
}
