module coordination.api;

import std.algorithm : startsWith;
import std.conv : to;
import std.file : exists, read;
import std.json : JSONType, JSONValue, parseJSON;

import d2sqlite3 : Row;
import std.path : buildPath;
import std.string : endsWith, indexOf, split, strip;
import std.uri : decodeComponent;

import coordination.ident : coordinationBuild, coordinationVersion;
import coordination.kdl : importSessions;
import coordination.store : Store, defaultDatabasePath, diagnosticsText;

struct Reply
{
    int status = 200;
    string contentType = "application/json; charset=utf-8";
    string body;
}

Reply dispatch(ref Store store, string method, string target, string body, bool publicMode, string bearer, bool loopback, string appDir)
{
    string path;
    string[string] query;
    splitTarget(target, path, query);
    if (method == "GET" && (path == "/health" || path == "/version"))
        return json(200, versionBody());
    if (method == "GET" && (path == "/" || path == "/index.html" || path == "/app.js" || path == "/app.css"))
        return staticFile(appDir, path);
    auto access = authorize(store, publicMode, bearer, loopback, method, path);
    if (!access.ok)
        return json(access.status, hintBody("miss", access.reason, access.hint));
    try
    {
        if (method == "GET" && path == "/api/diagnostics")
            return Reply(200, "text/plain; charset=utf-8", diagnosticsText(store, defaultDatabasePath()));
        if (method == "GET" && path == "/api/boards")
            return json(200, boardsJson(store));
        if (method == "GET" && path == "/api/queue")
            return json(200, queueJson(store, field(query, "harness"), field(query, "session")));
        if (method == "POST" && path == "/api/import")
            return json(200, importBody(store, body));
        if (method == "POST" && path == "/api/record-move")
            return recordMove(store, body);
        if (method == "POST" && path == "/api/resolve")
            return resolve(store, body);
        if (method == "POST" && path == "/api/repair")
            return repair(store, body);
        if (method == "POST" && path == "/api/queue/mirror")
            return mirror(store, body);
        if (method == "POST" && path == "/api/account/issue")
        {
            if (!loopback)
                return json(403, hintBody("miss", "loopback", "Tokens are issued on this machine. A remote caller cannot mint one."));
            return issue(store, body);
        }
        if (path.startsWith("/api/boards/"))
            return boardRoute(store, method, path, query, body);
        return json(404, hintBody("miss", "not-found", "No route for " ~ method ~ " " ~ path));
    }
    catch (Exception e)
    {
        return json(400, hintBody("miss", "rejected", e.msg));
    }
}

private struct Access
{
    bool ok = true;
    int status = 200;
    string reason;
    string hint;
}

private Access authorize(ref Store store, bool publicMode, string bearer, bool loopback, string method, string path)
{
    Access ok;
    if (!publicMode)
        return ok;
    if (path == "/api/account/issue" && loopback)
        return ok;
    auto plan = store.tokenPlan(bearer);
    if (!plan.length)
    {
        ok.ok = false;
        ok.status = 401;
        ok.reason = "hosted-plan";
        ok.hint = "This online database is the Dev-Centr hosted plan. Send a hosted token. A workstation token only opens the database on the machine where it was issued.";
        return ok;
    }
    if (plan != "hosted")
    {
        ok.ok = false;
        ok.status = 402;
        ok.reason = "hosted-plan";
        ok.hint = "This online database is the Dev-Centr hosted plan. A workstation token only opens the database on this machine.";
        return ok;
    }
    return ok;
}

private Reply boardRoute(ref Store store, string method, string path, string[string] query, string body)
{
    auto rest = path["/api/boards/".length .. $];
    string id;
    string action;
    auto slash = rest.indexOf('/');
    if (slash < 0)
        id = decodeComponent(rest);
    else
    {
        id = decodeComponent(rest[0 .. slash]);
        action = rest[slash + 1 .. $];
    }
    if (method == "GET" && !action.length)
        return json(200, boardJson(store, id));
    if (method == "GET" && action == "tree")
        return json(200, boardJson(store, id));
    if (method == "GET" && action == "path")
    {
        auto node = field(query, "node");
        JSONValue doc;
        doc["board"] = id;
        JSONValue titles = parseJSON("[]");
        foreach (title; store.pathTo(id, node))
            titles.array ~= JSONValue(title);
        doc["path"] = titles;
        return json(200, doc.toString());
    }
    if (method == "POST" && action == "nodes")
        return saveNode(store, id, body);
    if (method == "POST" && action == "waits")
        return saveWait(store, id, body);
    return json(404, hintBody("miss", "not-found", "No board route for " ~ action));
}

private Reply saveNode(ref Store store, string boardId, string body)
{
    auto doc = parseJSON(body.length ? body : "{}");
    auto id = str(doc, "id");
    if (!id.length)
        throw new Exception("node id is required");
    store.upsertNode(boardId, id, str(doc, "title"), str(doc, "status", "open"), str(doc, "parent"),
        num(doc, "position"), str(doc, "summary"), str(doc, "plan"), str(doc, "repo"), str(doc, "quote"),
        str(doc, "cursorChat"), num(doc, "segment"), num(doc, "turn"), ("segment" in doc) !is null, ("turn" in doc) !is null);
    if ("needs" in doc)
    {
        string[] needs;
        foreach (item; doc["needs"].array)
            needs ~= item.str;
        store.setNeeds(boardId, id, needs);
    }
    return json(200, boardJson(store, boardId));
}

private Reply saveWait(ref Store store, string boardId, string body)
{
    auto doc = parseJSON(body.length ? body : "{}");
    auto nodeId = str(doc, "nodeId");
    if (!nodeId.length)
        throw new Exception("a wait references a plan node");
    auto id = str(doc, "id", nodeId ~ "-wait");
    store.upsertWait(id, boardId, nodeId, num(doc, "position"), num(doc, "estimatedWaitMs"),
        str(doc, "status", "pending"), str(doc, "waitHubId"), str(doc, "harnessId"), str(doc, "sessionId"));
    return json(200, boardJson(store, boardId));
}

private Reply mirror(ref Store store, string body)
{
    auto doc = parseJSON(body);
    auto boardId = str(doc, "boardId");
    if (!boardId.length)
        throw new Exception("boardId is required");
    long position;
    foreach (phase; doc["phases"].array)
    {
        string[] depends;
        if ("dependsOn" in phase)
            foreach (item; phase["dependsOn"].array)
                depends ~= item.str;
        store.mirrorPhase(boardId, str(doc, "title"), str(doc, "harnessId"), str(doc, "sessionId"),
            str(phase, "id"), str(phase, "planNodeId"), str(phase, "title"), position,
            num(phase, "estimatedWaitMs"), str(phase, "status", "pending"), str(phase, "waitHubId"), depends);
        position++;
    }
    return json(200, queueJson(store, str(doc, "harnessId"), str(doc, "sessionId")));
}

private Reply recordMove(ref Store store, string body)
{
    auto doc = parseJSON(body);
    auto canonical = str(doc, "canonical");
    store.recordMove(canonical, str(doc, "fromCursorChat"), str(doc, "toCursorChat"),
        str(doc, "fromProjectKey"), str(doc, "toProjectKey"), str(doc, "fromRoot"), str(doc, "toRoot"),
        str(doc, "fromWorkspaceUri"), str(doc, "toWorkspaceUri"));
    return json(200, hintBody("recorded", "workspace-move", "Recorded the new transcript folder as an alias of " ~ canonical ~ ". The plan stays on that board. The previous folder was kept."));
}

private Reply resolve(ref Store store, string body)
{
    auto doc = parseJSON(body.length ? body : "{}");
    auto hit = store.resolve(str(doc, "chat"), str(doc, "cursorChat"), str(doc, "segment"), str(doc, "quote"));
    auto code = hit.code == 0 ? 200 : 404;
    return json(code, hintBody(hit.status, hit.reason, hit.hint, hit.canonical, hit.via, hit.path));
}

private Reply repair(ref Store store, string body)
{
    auto doc = parseJSON(body);
    store.repair(str(doc, "chat"), str(doc, "cursorChat"), str(doc, "liveRoot"), str(doc, "projectKey"),
        ("filesMoved" in doc) !is null && doc["filesMoved"].type == JSONType.true_);
    return json(200, hintBody("repaired", "workspace-fragmented", "Marked the live folder current and kept the old keys."));
}

private Reply issue(ref Store store, string body)
{
    auto doc = parseJSON(body);
    auto token = str(doc, "token");
    if (!token.length)
        throw new Exception("token is required");
    store.issueToken(token, str(doc, "plan"), str(doc, "label"));
    JSONValue outp;
    outp["status"] = "issued";
    outp["plan"] = str(doc, "plan");
    outp["label"] = str(doc, "label");
    return json(200, outp.toString());
}

private string importBody(ref Store store, string body)
{
    string root;
    if (body.length)
    {
        auto doc = parseJSON(body);
        root = str(doc, "sessions");
    }
    if (!root.length)
    {
        import std.path : dirName;
        root = buildPath(dirName(dirName(defaultDatabasePath())), "sessions");
    }
    auto count = importSessions(store, root);
    JSONValue outp;
    outp["status"] = "imported";
    outp["boards"] = count.boards;
    outp["nodes"] = count.nodes;
    outp["sessions"] = root;
    return outp.toString();
}

private string boardsJson(ref Store store)
{
    JSONValue list = parseJSON("[]");
    auto rows = store.db.execute("SELECT id, title, kind, harness_id, session_id FROM boards ORDER BY id");
    foreach (row; rows)
    {
        JSONValue item;
        item["id"] = row.peek!string(0);
        item["title"] = row.peek!string(1);
        item["kind"] = row.peek!string(2);
        item["harnessId"] = row.peek!string(3);
        item["sessionId"] = row.peek!string(4);
        list.array ~= item;
    }
    JSONValue doc;
    doc["boards"] = list;
    return doc.toString();
}

private string boardJson(ref Store store, string id)
{
    JSONValue doc;
    doc["id"] = id;
    auto board = store.db.execute("SELECT title, kind, harness_id, session_id FROM boards WHERE id=?1", id);
    bool have;
    foreach (row; board)
    {
        have = true;
        doc["title"] = row.peek!string(0);
        doc["kind"] = row.peek!string(1);
        doc["harnessId"] = row.peek!string(2);
        doc["sessionId"] = row.peek!string(3);
    }
    if (!have)
        throw new Exception("no board " ~ id);
    JSONValue nodes = parseJSON("[]");
    auto nrows = store.db.execute(
        "SELECT id, parent, position, title, summary, status, plan, repo, quote, link_cursor_chat, link_segment, link_turn, wait_id, cached_wait_status FROM nodes WHERE board_id=?1 ORDER BY position, id",
        id);
    foreach (row; nrows)
    {
        JSONValue node;
        node["id"] = row.peek!string(0);
        node["parent"] = row.peek!string(1);
        node["position"] = row.peek!long(2);
        node["title"] = row.peek!string(3);
        node["summary"] = row.peek!string(4);
        node["status"] = row.peek!string(5);
        node["plan"] = row.peek!string(6);
        node["repo"] = row.peek!string(7);
        node["quote"] = row.peek!string(8);
        node["cursorChat"] = row.peek!string(9);
        node["segment"] = row.peek!long(10);
        node["turn"] = row.peek!long(11);
        node["waitId"] = row.peek!string(12);
        node["cachedWaitStatus"] = row.peek!string(13);
        JSONValue needs = parseJSON("[]");
        foreach (need; store.needsOf(id, row.peek!string(0)))
            needs.array ~= JSONValue(need);
        node["needs"] = needs;
        nodes.array ~= node;
    }
    doc["nodes"] = nodes;
    JSONValue waits = parseJSON("[]");
    auto wrows = store.db.execute(
        "SELECT id, node_id, position, estimated_wait_ms, wait_status, wait_hub_id, harness_id, session_id FROM waits WHERE board_id=?1 ORDER BY position, id",
        id);
    foreach (row; wrows)
        waits.array ~= waitJson(row);
    doc["waits"] = waits;
    JSONValue aliases = parseJSON("[]");
    auto arows = store.db.execute(
        "SELECT kind, value, role, live, status, reason FROM aliases WHERE board_id=?1 ORDER BY kind, value",
        id);
    foreach (row; arows)
    {
        JSONValue aliasRow;
        aliasRow["kind"] = row.peek!string(0);
        aliasRow["value"] = row.peek!string(1);
        aliasRow["role"] = row.peek!string(2);
        aliasRow["live"] = row.peek!long(3) != 0;
        aliasRow["status"] = row.peek!string(4);
        aliasRow["reason"] = row.peek!string(5);
        aliases.array ~= aliasRow;
    }
    doc["aliases"] = aliases;
    return doc.toString();
}

private string queueJson(ref Store store, string harnessId, string sessionId)
{
    JSONValue list = parseJSON("[]");
    auto rows = store.db.execute(
        `SELECT w.id, w.node_id, w.position, w.estimated_wait_ms, w.wait_status, w.wait_hub_id, w.harness_id, w.session_id, w.board_id, n.title
         FROM waits w JOIN nodes n ON n.board_id = w.board_id AND n.id = w.node_id
         ORDER BY w.harness_id, w.session_id, w.position`);
    foreach (row; rows)
    {
        if (harnessId.length && row.peek!string(6) != harnessId)
            continue;
        if (sessionId.length && row.peek!string(7) != sessionId)
            continue;
        auto item = waitJson(row);
        item["boardId"] = row.peek!string(8);
        item["title"] = row.peek!string(9);
        list.array ~= item;
    }
    JSONValue doc;
    doc["queue"] = list;
    return doc.toString();
}

private JSONValue waitJson(Row row)
{
    JSONValue item;
    item["id"] = row.peek!string(0);
    item["nodeId"] = row.peek!string(1);
    item["position"] = row.peek!long(2);
    item["estimatedWaitMs"] = row.peek!long(3);
    item["status"] = row.peek!string(4);
    item["waitHubId"] = row.peek!string(5);
    item["harnessId"] = row.peek!string(6);
    item["sessionId"] = row.peek!string(7);
    return item;
}

private string versionBody()
{
    JSONValue doc;
    doc["ok"] = true;
    doc["service"] = "coordinationd";
    doc["version"] = coordinationVersion;
    doc["build"] = coordinationBuild;
    return doc.toString();
}

private string hintBody(string status, string reason, string hint, string canonical = "", string via = "", string path = "")
{
    JSONValue doc;
    doc["status"] = status;
    doc["reason"] = reason;
    doc["hint"] = hint;
    if (canonical.length)
        doc["canonical"] = canonical;
    if (via.length)
        doc["via"] = via;
    if (path.length)
        doc["path"] = path;
    return doc.toString();
}

private Reply json(int status, string body)
{
    return Reply(status, "application/json; charset=utf-8", body);
}

private Reply staticFile(string appDir, string path)
{
    string name = path == "/" || path == "/index.html" ? "index.html" : path[1 .. $];
    auto file = buildPath(appDir, name);
    if (!exists(file))
        return json(404, hintBody("miss", "not-found", "The local app file is not next to the daemon: " ~ file));
    string type = "text/plain; charset=utf-8";
    if (name.endsWith(".html"))
        type = "text/html; charset=utf-8";
    else if (name.endsWith(".js"))
        type = "text/javascript; charset=utf-8";
    else if (name.endsWith(".css"))
        type = "text/css; charset=utf-8";
    return Reply(200, type, cast(string) read(file));
}

private void splitTarget(string target, out string path, out string[string] query)
{
    auto q = target.indexOf('?');
    path = q < 0 ? target : target[0 .. q];
    if (q < 0)
        return;
    foreach (part; target[q + 1 .. $].split("&"))
    {
        auto eq = part.indexOf('=');
        if (eq < 0)
            query[decodeComponent(part)] = "";
        else
            query[decodeComponent(part[0 .. eq])] = decodeComponent(part[eq + 1 .. $]);
    }
}

private string str(JSONValue doc, string key, string fallback = "")
{
    if ((key in doc) is null)
        return fallback;
    if (doc[key].type == JSONType.string)
        return doc[key].str;
    return doc[key].toString();
}

private long num(JSONValue doc, string key)
{
    if ((key in doc) is null)
        return 0;
    if (doc[key].type == JSONType.integer || doc[key].type == JSONType.uinteger)
        return doc[key].integer;
    if (doc[key].type == JSONType.string && doc[key].str.length)
        return to!long(doc[key].str);
    return 0;
}

private string field(string[string] query, string key)
{
    return (key in query) is null ? "" : query[key];
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.uuid : randomUUID;

    auto dir = buildPath(tempDir(), "coordination-api-" ~ randomUUID().toString());
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto store = Store.open(buildPath(dir, "t.db"));
    scope (exit)
        store.close();
    auto denied = dispatch(store, "GET", "/api/boards", "", true, "", false, dir);
    assert(denied.status == 401);
    assert(denied.body.indexOf("hosted") > 0);
    store.issueToken("hosted-token", "hosted", "dev-centr");
    store.issueToken("desk-token", "workstation", "this-pc");
    auto workstation = dispatch(store, "GET", "/api/boards", "", true, "desk-token", false, dir);
    assert(workstation.status == 402);
    auto hosted = dispatch(store, "GET", "/api/boards", "", true, "hosted-token", false, dir);
    assert(hosted.status == 200);
    auto local = dispatch(store, "POST", "/api/boards/chat/nodes", `{"id":"ask","title":"Original ask","status":"open"}`, false, "", true, dir);
    assert(local.status == 200);
    auto waiting = dispatch(store, "POST", "/api/boards/chat/waits", `{"id":"w1","nodeId":"ask","estimatedWaitMs":1500,"status":"waiting","waitHubId":"ci-1"}`, false, "", true, dir);
    assert(waiting.status == 200);
    auto queued = dispatch(store, "GET", "/api/queue", "", false, "", true, dir);
    assert(queued.body.indexOf("Original ask") > 0);
    assert(queued.body.indexOf("ci-1") > 0);
}
