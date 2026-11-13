module coordination.store;

import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, readText;
import std.path : buildPath, dirName, baseName;
import std.string : format, indexOf;

import d2sqlite3 : Database, Row;

import coordination.ident : coordinationBanner;

struct ResolveHit
{
    string status = "miss";
    string reason;
    string canonical;
    string via;
    string path;
    string hint;
    int code = 2;
}

struct Store
{
    Database db;

    static Store open(string path)
    {
        mkdirRecurse(dirName(path));
        Store s;
        s.db = Database(path);
        s.db.execute("PRAGMA foreign_keys = ON");
        s.migrate();
        return s;
    }

    void close()
    {
        db.close();
    }

    void migrate()
    {
        db.execute(`CREATE TABLE IF NOT EXISTS boards (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL DEFAULT 'chat',
            harness_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL
        )`);
        db.execute(`CREATE TABLE IF NOT EXISTS aliases (
            board_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            value TEXT NOT NULL,
            role TEXT NOT NULL,
            live INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT '',
            since TEXT NOT NULL,
            reason TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (board_id, kind, value)
        )`);
        db.execute(`CREATE TABLE IF NOT EXISTS nodes (
            board_id TEXT NOT NULL,
            id TEXT NOT NULL,
            parent TEXT NOT NULL DEFAULT '',
            position INTEGER NOT NULL DEFAULT 0,
            title TEXT NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'open',
            plan TEXT NOT NULL DEFAULT '',
            repo TEXT NOT NULL DEFAULT '',
            quote TEXT NOT NULL DEFAULT '',
            link_cursor_chat TEXT NOT NULL DEFAULT '',
            link_segment INTEGER,
            link_turn INTEGER,
            wait_id TEXT NOT NULL DEFAULT '',
            cached_wait_status TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (board_id, id)
        )`);
        db.execute(`CREATE TABLE IF NOT EXISTS needs (
            board_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            needs_id TEXT NOT NULL,
            PRIMARY KEY (board_id, node_id, needs_id)
        )`);
        db.execute(`CREATE TABLE IF NOT EXISTS waits (
            id TEXT PRIMARY KEY,
            board_id TEXT NOT NULL,
            node_id TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            estimated_wait_ms INTEGER NOT NULL DEFAULT 0,
            wait_status TEXT NOT NULL DEFAULT 'pending',
            wait_hub_id TEXT NOT NULL DEFAULT '',
            harness_id TEXT NOT NULL DEFAULT '',
            session_id TEXT NOT NULL DEFAULT '',
            updated TEXT NOT NULL
        )`);
        db.execute(`CREATE TABLE IF NOT EXISTS tokens (
            token TEXT PRIMARY KEY,
            plan TEXT NOT NULL,
            label TEXT NOT NULL DEFAULT ''
        )`);
    }

    string now()
    {
        return Clock.currTime.toISOExtString();
    }

    void ensureBoard(string id, string title, string kind, string harnessId = "", string sessionId = "")
    {
        auto found = db.execute("SELECT title FROM boards WHERE id = ?1", id);
        bool have;
        foreach (row; found)
            have = true;
        if (!have)
        {
            db.execute(
                "INSERT INTO boards (id, title, kind, harness_id, session_id, created) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                id, title, kind, harnessId, sessionId, now());
            return;
        }
        if (harnessId.length || sessionId.length)
        {
            db.execute(
                "UPDATE boards SET harness_id = ?2, session_id = ?3 WHERE id = ?1",
                id, harnessId, sessionId);
        }
    }

    /// Insert the plan body only when the node is new. Returns true when inserted.
    bool ensureNode(string boardId, string id, string title, string status = "open", string parent = "", long position = 0)
    {
        auto found = db.execute("SELECT id FROM nodes WHERE board_id = ?1 AND id = ?2", boardId, id);
        bool have;
        foreach (row; found)
            have = true;
        if (have)
            return false;
        db.execute(
            "INSERT INTO nodes (board_id, id, parent, position, title, status) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            boardId, id, parent, position, title, status);
        return true;
    }

    void upsertNode(string boardId, string id, string title, string status, string parent, long position,
            string summary, string plan, string repo, string quote, string linkChat, long linkSegment, long linkTurn, bool hasSegment, bool hasTurn)
    {
        ensureBoard(boardId, "", "chat");
        auto found = db.execute("SELECT id FROM nodes WHERE board_id = ?1 AND id = ?2", boardId, id);
        bool have;
        foreach (row; found)
            have = true;
        if (!have)
        {
            db.execute(
                `INSERT INTO nodes (board_id, id, parent, position, title, summary, status, plan, repo, quote, link_cursor_chat, link_segment, link_turn)
                 VALUES (?1, ?2, COALESCE(?3, ''), ?4, ?5, COALESCE(?6, ''), COALESCE(?7, 'open'), COALESCE(?8, ''), COALESCE(?9, ''), COALESCE(?10, ''), COALESCE(?11, ''), ?12, ?13)`,
                boardId, id, parent, position, title, summary, status, plan, repo, quote, linkChat,
                hasSegment ? linkSegment : -1, hasTurn ? linkTurn : -1);
        }
        else
        {
            db.execute(
                `UPDATE nodes SET parent=COALESCE(?3, ''), position=?4, title=?5, summary=COALESCE(?6, ''), status=COALESCE(?7, 'open'), plan=COALESCE(?8, ''), repo=COALESCE(?9, ''), quote=COALESCE(?10, ''), link_cursor_chat=COALESCE(?11, '')
                 WHERE board_id=?1 AND id=?2`,
                boardId, id, parent, position, title, summary, status, plan, repo, quote, linkChat);
            if (hasSegment)
                db.execute("UPDATE nodes SET link_segment=?3 WHERE board_id=?1 AND id=?2", boardId, id, linkSegment);
            if (hasTurn)
                db.execute("UPDATE nodes SET link_turn=?3 WHERE board_id=?1 AND id=?2", boardId, id, linkTurn);
        }
    }

    void setNeeds(string boardId, string nodeId, string[] needIds)
    {
        db.execute("DELETE FROM needs WHERE board_id = ?1 AND node_id = ?2", boardId, nodeId);
        foreach (need; needIds)
        {
            if (!need.length)
                continue;
            db.execute(
                "INSERT OR IGNORE INTO needs (board_id, node_id, needs_id) VALUES (?1, ?2, ?3)",
                boardId, nodeId, need);
        }
    }

    string[] needsOf(string boardId, string nodeId)
    {
        string[] ids;
        auto rows = db.execute(
            "SELECT needs_id FROM needs WHERE board_id = ?1 AND node_id = ?2 ORDER BY needs_id",
            boardId, nodeId);
        foreach (row; rows)
            ids ~= row.peek!string(0);
        return ids;
    }

    void upsertWait(string id, string boardId, string nodeId, long position, long estimatedWaitMs,
            string waitStatus, string waitHubId, string harnessId, string sessionId)
    {
        auto node = db.execute("SELECT id FROM nodes WHERE board_id = ?1 AND id = ?2", boardId, nodeId);
        bool haveNode;
        foreach (row; node)
            haveNode = true;
        if (!haveNode)
            throw new Exception("plan node " ~ nodeId ~ " is not on board " ~ boardId);
        auto stamp = now();
        auto existing = db.execute("SELECT id FROM waits WHERE id = ?1", id);
        bool have;
        foreach (row; existing)
            have = true;
        if (!have)
        {
            db.execute(
                `INSERT INTO waits (id, board_id, node_id, position, estimated_wait_ms, wait_status, wait_hub_id, harness_id, session_id, updated)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
                id, boardId, nodeId, position, estimatedWaitMs, waitStatus, waitHubId, harnessId, sessionId, stamp);
        }
        else
        {
            db.execute(
                `UPDATE waits SET board_id=?2, node_id=?3, position=?4, estimated_wait_ms=?5, wait_status=?6, wait_hub_id=?7, harness_id=?8, session_id=?9, updated=?10
                 WHERE id=?1`,
                id, boardId, nodeId, position, estimatedWaitMs, waitStatus, waitHubId, harnessId, sessionId, stamp);
        }
        db.execute(
            "UPDATE nodes SET wait_id=?3, cached_wait_status=?4 WHERE board_id=?1 AND id=?2",
            boardId, nodeId, id, waitStatus);
    }

    void mirrorPhase(string boardId, string boardTitle, string harnessId, string sessionId,
            string phaseId, string planNodeId, string titleIfNew, long position, long estimatedWaitMs,
            string waitStatus, string waitHubId, string[] dependsOn)
    {
        ensureBoard(boardId, boardTitle, "session", harnessId, sessionId);
        auto nodeId = planNodeId.length ? planNodeId : phaseId;
        bool created = ensureNode(boardId, nodeId, titleIfNew.length ? titleIfNew : nodeId, "open", "", position);
        if (created)
            setNeeds(boardId, nodeId, dependsOn);
        upsertWait(phaseId, boardId, nodeId, position, estimatedWaitMs, waitStatus, waitHubId, harnessId, sessionId);
    }

    void putAlias(string boardId, string kind, string value, string role, bool live, string status, string reason)
    {
        auto found = db.execute(
            "SELECT role FROM aliases WHERE board_id=?1 AND kind=?2 AND value=?3",
            boardId, kind, value);
        string existingRole;
        bool have;
        foreach (row; found)
        {
            have = true;
            existingRole = row.peek!string(0);
        }
        auto stamp = now();
        if (!have)
        {
            db.execute(
                `INSERT INTO aliases (board_id, kind, value, role, live, status, since, reason)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
                boardId, kind, value, role, live ? 1 : 0, status, stamp, reason);
        }
        else
        {
            auto keep = existingRole == "original" ? "original" : existingRole;
            db.execute(
                "UPDATE aliases SET live=?4, status=?5 WHERE board_id=?1 AND kind=?2 AND value=?3",
                boardId, kind, value, live ? 1 : 0, status);
            if (keep == "original")
                db.execute(
                    "UPDATE aliases SET role='original' WHERE board_id=?1 AND kind=?2 AND value=?3",
                    boardId, kind, value);
        }
    }

    void setLive(string boardId, string kind, string value)
    {
        db.execute("UPDATE aliases SET live=0 WHERE board_id=?1 AND kind=?2", boardId, kind);
        db.execute(
            "UPDATE aliases SET live=1 WHERE board_id=?1 AND kind=?2 AND value=?3",
            boardId, kind, value);
    }

    void recordMove(string canonical, string fromChat, string toChat, string fromKey, string toKey,
            string fromRoot, string toRoot, string fromUri, string toUri)
    {
        ensureBoard(canonical, "", "chat");
        recordPair("cursor-chat", canonical, fromChat, toChat, "");
        recordPair("project-key", canonical, fromKey, toKey, "");
        recordPair("root", canonical, fromRoot, toRoot, rootStatus(fromRoot), rootStatus(toRoot));
        if (fromUri.length || toUri.length)
            recordPair("workspace-uri", canonical, fromUri, toUri, "");
    }

    private void recordPair(string kind, string boardId, string fromValue, string toValue, string fromStatus, string toStatus = "")
    {
        if (!toStatus.length && kind == "root")
            toStatus = fromStatus;
        if (fromValue == toValue)
        {
            putAlias(boardId, kind, fromValue, "original", true, fromStatus, "");
            setLive(boardId, kind, toValue);
            markOriginal(boardId, kind, fromValue);
            return;
        }
        putAlias(boardId, kind, fromValue, "original", false, fromStatus, "");
        putAlias(boardId, kind, toValue, "alias", true, toStatus, "workspace-move");
        setLive(boardId, kind, toValue);
        markOriginal(boardId, kind, fromValue);
    }

    private void markOriginal(string boardId, string kind, string value)
    {
        auto rows = db.execute(
            "SELECT value FROM aliases WHERE board_id=?1 AND kind=?2 AND role='original'",
            boardId, kind);
        bool have;
        foreach (row; rows)
            have = true;
        if (!have)
            db.execute(
                "UPDATE aliases SET role='original' WHERE board_id=?1 AND kind=?2 AND value=?3",
                boardId, kind, value);
    }

    string findBoard(string chatOrBoard)
    {
        auto direct = db.execute("SELECT id FROM boards WHERE id=?1", chatOrBoard);
        foreach (row; direct)
            return row.peek!string(0);
        auto byChat = db.execute(
            "SELECT board_id FROM aliases WHERE kind='cursor-chat' AND value=?1",
            chatOrBoard);
        foreach (row; byChat)
            return row.peek!string(0);
        auto root = db.execute(
            "SELECT board_id FROM aliases WHERE kind='root' AND value=?1",
            chatOrBoard);
        foreach (row; root)
            return row.peek!string(0);
        return "";
    }

    ResolveHit resolve(string chat, string cursorChat, string segment, string quote)
    {
        ResolveHit hit;
        auto board = findBoard(chat);
        if (!board.length)
        {
            hit.reason = "never-recorded";
            hit.hint = "No location record for " ~ chat ~ ". Cursor keys transcript folders by the workspace path, so a rename starts a new folder and can mint a new chat id. If this conversation was moved, record both folders with record-move. Until then a link to this id cannot be followed.";
            return hit;
        }
        hit.canonical = board;
        if (segment.length && !cursorChat.length && !quote.length)
        {
            hit.reason = "workspace-fragmented";
            hit.hint = "Segment " ~ segment ~ " needs the transcript id it was recorded against. Each folder numbers its own segments from zero, so the same segment number in another folder is a different sentence.";
            return hit;
        }
        auto roots = liveRootsFirst(board);
        string segmentFile;
        if (segment.length)
        {
            import std.conv : to;
            auto n = to!int(segment);
            segmentFile = format("segment_%03d.md", n);
        }
        string[] tried;
        foreach (root; roots)
        {
            auto folder = root.value;
            auto leaf = baseName(folder);
            if (cursorChat.length && !quote.length && leaf != cursorChat && folder != cursorChat)
                continue;
            auto candidate = folder;
            if (segmentFile.length)
                candidate = buildPath(folder, "compaction", segmentFile);
            else
            {
                auto jsonl = buildPath(folder, leaf ~ ".jsonl");
                if (exists(jsonl))
                    candidate = jsonl;
            }
            auto present = exists(candidate);
            tried ~= candidate ~ " status=" ~ (present ? "present" : "missing");
            if (!present)
                continue;
            if (quote.length)
            {
                auto body = readText(candidate);
                if (body.indexOf(quote) < 0)
                    continue;
            }
            hit.status = "found";
            hit.code = 0;
            hit.via = leaf;
            hit.path = candidate;
            if (!root.live)
            {
                hit.reason = "resolved-via-alias";
                hit.hint = "Resolved through an older transcript folder. This chat was rebound and Cursor left the earlier files in place. The current folder is " ~ liveRoot(board) ~ ". The file you asked for is still at " ~ candidate ~ ".";
            }
            else if (roots.length > 1 && !cursorChat.length)
            {
                hit.reason = "found";
                hit.hint = "This chat has more than one transcript folder. Opened the live one at " ~ candidate ~ ".";
            }
            else
            {
                hit.reason = "found";
                hit.hint = "Opened the transcript recorded for " ~ board ~ ".";
            }
            return hit;
        }
        hit.reason = roots.length > 1 ? "workspace-fragmented" : "file-missing";
        if (hit.reason == "workspace-fragmented")
            hit.hint = "This link names chat " ~ board ~ ", and Cursor has more than one transcript folder for it. Segment numbers restart in each folder. Tried: " ~ joinSemi(tried) ~ ". If the files have since been gathered into one folder, run repair with the folder you found.";
        else
            hit.hint = "The location record exists, and the recorded folder is not on disk. Chat " ~ board ~ " was not deleted from this record. The folder may have been renamed again without record-move.";
        return hit;
    }

    void repair(string chat, string cursorChat, string liveRootPath, string projectKey, bool filesMoved)
    {
        auto board = findBoard(chat);
        if (!board.length)
            throw new Exception("never-recorded");
        auto roots = db.execute("SELECT value FROM aliases WHERE board_id=?1 AND kind='root'", board);
        string[] values;
        foreach (row; roots)
            values ~= row.peek!string(0);
        foreach (value; values)
        {
            string status;
            if (exists(value))
                status = "present";
            else if (filesMoved)
                status = "reunited";
            else
                status = "missing";
            db.execute(
                "UPDATE aliases SET status=?3 WHERE board_id=?1 AND kind='root' AND value=?2",
                board, value, status);
        }
        if (!liveRootPath.length)
            return;
        if (!cursorChat.length)
            throw new Exception("repair with a live folder also needs the transcript id");
        putAlias(board, "root", liveRootPath, "alias", true, rootStatus(liveRootPath), "repaired");
        setLive(board, "root", liveRootPath);
        putAlias(board, "cursor-chat", cursorChat, "alias", true, "", "repaired");
        setLive(board, "cursor-chat", cursorChat);
        if (projectKey.length)
        {
            putAlias(board, "project-key", projectKey, "alias", true, "", "repaired");
            setLive(board, "project-key", projectKey);
        }
    }

    void issueToken(string token, string plan, string label)
    {
        if (plan != "workstation" && plan != "hosted")
            throw new Exception("plan must be workstation or hosted");
        db.execute(
            "INSERT INTO tokens (token, plan, label) VALUES (?1, ?2, ?3) ON CONFLICT(token) DO UPDATE SET plan=?2, label=?3",
            token, plan, label);
    }

    string tokenPlan(string token)
    {
        if (!token.length)
            return "";
        auto rows = db.execute("SELECT plan FROM tokens WHERE token=?1", token);
        foreach (row; rows)
            return row.peek!string(0);
        return "";
    }

    long countBoards()
    {
        auto rows = db.execute("SELECT COUNT(*) FROM boards");
        foreach (row; rows)
            return row.peek!long(0);
        return 0;
    }

    long countNodes()
    {
        auto rows = db.execute("SELECT COUNT(*) FROM nodes");
        foreach (row; rows)
            return row.peek!long(0);
        return 0;
    }

    string[] pathTo(string boardId, string nodeId)
    {
        string[] titles;
        auto rows = db.execute(
            `WITH RECURSIVE anc(id, parent, title, depth) AS (
                SELECT id, parent, title, 0 FROM nodes WHERE board_id = ?1 AND id = ?2
                UNION ALL
                SELECT n.id, n.parent, n.title, anc.depth + 1
                FROM nodes n
                JOIN anc ON n.id = anc.parent
                WHERE n.board_id = ?1
            )
            SELECT title FROM anc ORDER BY depth DESC`,
            boardId, nodeId);
        foreach (row; rows)
            titles ~= row.peek!string(0);
        return titles;
    }

    long countWaits()
    {
        auto rows = db.execute("SELECT COUNT(*) FROM waits");
        foreach (row; rows)
            return row.peek!long(0);
        return 0;
    }

    private static struct RootRow
    {
        string value;
        bool live;
    }

    private RootRow[] liveRootsFirst(string boardId)
    {
        RootRow[] rows;
        auto q = db.execute(
            "SELECT value, live FROM aliases WHERE board_id=?1 AND kind='root' ORDER BY live DESC, value",
            boardId);
        foreach (row; q)
            rows ~= RootRow(row.peek!string(0), row.peek!long(1) != 0);
        return rows;
    }

    private string liveRoot(string boardId)
    {
        auto rows = db.execute(
            "SELECT value FROM aliases WHERE board_id=?1 AND kind='root' AND live=1",
            boardId);
        foreach (row; rows)
            return row.peek!string(0);
        return "(none recorded)";
    }
}

string rootStatus(string folder)
{
    return exists(folder) ? "present" : "missing";
}

private string joinSemi(string[] parts)
{
    string s;
    foreach (i, part; parts)
    {
        if (i)
            s ~= "; ";
        s ~= part;
    }
    return s;
}

string defaultDatabasePath()
{
    import std.process : environment;
    auto root = environment.get("AGENT_WORKSPACE_ROOT");
    if (!root.length)
    {
        auto local = environment.get("LOCALAPPDATA");
        if (local.length)
            root = buildPath(local, "AgentWorkspace");
        else
            root = buildPath(dirName("."), "AgentWorkspace");
    }
    return buildPath(root, "coordination", "coordination.db");
}

string diagnosticsText(ref Store store, string dbPath)
{
    return coordinationBanner() ~ "\ndatabase: " ~ dbPath ~ "\nboards: " ~ store.countBoards().to!string
        ~ "\nnodes: " ~ store.countNodes().to!string ~ "\nwaits: " ~ store.countWaits().to!string
        ~ "\nbind: 127.0.0.1:17359\n";
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.uuid : randomUUID;

    auto dir = buildPath(tempDir(), "coordination-test-" ~ randomUUID().toString());
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto store = Store.open(buildPath(dir, "t.db"));
    scope (exit)
        store.close();

    store.ensureBoard("chat-1", "A chat", "chat");
    assert(store.ensureNode("chat-1", "parent", "Original ask"));
    assert(store.ensureNode("chat-1", "child", "Prerequisite", "active", "parent", 0));
    assert(!store.ensureNode("chat-1", "parent", "should not replace"));
    auto path = store.pathTo("chat-1", "child");
    assert(path.length == 2);
    assert(path[0] == "Original ask");
    assert(path[1] == "Prerequisite");

    store.mirrorPhase("plan-1", "Session", "cursor", "s1", "ph1", "ph1", "Build the editor", 0, 5000, "waiting", "hub-9", ["view-check"]);
    store.mirrorPhase("plan-1", "Session renamed", "cursor", "s1", "ph1", "ph1", "A different title", 0, 8000, "active", "hub-9", ["other"]);
    auto title = store.db.execute("SELECT title FROM nodes WHERE board_id='plan-1' AND id='ph1'");
    foreach (row; title)
        assert(row.peek!string(0) == "Build the editor");
    auto needs = store.needsOf("plan-1", "ph1");
    assert(needs.length == 1 && needs[0] == "view-check");
    auto waits = store.db.execute("SELECT estimated_wait_ms, wait_status FROM waits WHERE id='ph1'");
    foreach (row; waits)
    {
        assert(row.peek!long(0) == 8000);
        assert(row.peek!string(1) == "active");
    }
    auto cached = store.db.execute("SELECT cached_wait_status, wait_id FROM nodes WHERE board_id='plan-1' AND id='ph1'");
    foreach (row; cached)
    {
        assert(row.peek!string(0) == "active");
        assert(row.peek!string(1) == "ph1");
    }

    auto oldRoot = buildPath(dir, "chat-1");
    auto newRoot = buildPath(dir, "cd1fee1e");
    mkdirRecurse(buildPath(oldRoot, "compaction"));
    mkdirRecurse(newRoot);
    write(buildPath(oldRoot, "compaction", "segment_000.md"), "the original sentence");
    write(buildPath(newRoot, "cd1fee1e.jsonl"), "later turn");
    store.recordMove("chat-1", "chat-1", "cd1fee1e", "old-slug", "new-slug", oldRoot, newRoot, "", "");
    auto miss = store.resolve("chat-1", "", "0", "");
    assert(miss.code == 2);
    assert(miss.reason == "workspace-fragmented");
    auto found = store.resolve("chat-1", "chat-1", "0", "");
    assert(found.code == 0);
    assert(found.reason == "resolved-via-alias");
    assert(found.path.indexOf("segment_000.md") > 0);
    auto unknown = store.resolve("missing-chat", "", "", "");
    assert(unknown.reason == "never-recorded");
}
