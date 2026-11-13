module coordination.kdl;

import std.file : dirEntries, exists, isFile, readText, SpanMode;
import std.path : baseName, buildPath, dirName;
import std.string : indexOf, splitLines, startsWith, strip;

import coordination.store : Store;

struct ImportCount
{
    long boards;
    long nodes;
}

ImportCount importSessions(ref Store store, string sessionsRoot)
{
    ImportCount count;
    if (!sessionsRoot.length || !exists(sessionsRoot))
        return count;
    foreach (entry; dirEntries(sessionsRoot, SpanMode.shallow))
    {
        if (isFile(entry.name))
            continue;
        auto plan = buildPath(entry.name, "plan-stack.kdl");
        auto locations = buildPath(entry.name, "locations.kdl");
        auto board = baseName(entry.name);
        if (exists(locations))
        {
            auto parsed = parseLocations(readText(locations));
            if (parsed.chat.length)
                board = parsed.chat;
            store.ensureBoard(board, "", "chat");
            foreach (row; parsed.rows)
            {
                store.putAlias(board, row.kind, row.value, row.role, row.live, row.status, row.reason);
            }
            count.boards++;
        }
        if (exists(plan))
        {
            store.ensureBoard(board, "", "chat");
            long position;
            foreach (item; parsePlan(readText(plan)))
            {
                auto created = store.ensureNode(board, item.id, item.title, item.status, "", position);
                if (created)
                    store.setNeeds(board, item.id, item.needs);
                else
                    store.upsertNode(board, item.id, item.title, item.status, "", position, "", item.plan, item.repo, "", "", 0, 0, false, false);
                position++;
                count.nodes++;
            }
            count.boards++;
        }
    }
    return count;
}

private struct AliasRow
{
    string kind;
    string value;
    string role;
    bool live;
    string status;
    string reason;
}

private struct LocationDoc
{
    string chat;
    AliasRow[] rows;
}

private struct PlanItem
{
    string id;
    string title;
    string status = "open";
    string plan;
    string repo;
    string[] needs;
}

private LocationDoc parseLocations(string text)
{
    LocationDoc doc;
    foreach (raw; text.splitLines())
    {
        auto line = raw.strip();
        if (!line.length || line.startsWith("//"))
            continue;
        if (line.startsWith("chat "))
        {
            doc.chat = firstQuote(line);
            continue;
        }
        foreach (kind; ["cursor-chat", "project-key", "workspace-uri", "root"])
        {
            if (!line.startsWith(kind ~ " "))
                continue;
            AliasRow row;
            row.kind = kind;
            row.value = firstQuote(line);
            row.role = prop(line, "role");
            if (!row.role.length)
                row.role = "alias";
            row.live = prop(line, "live") == "true";
            row.status = prop(line, "status");
            row.reason = prop(line, "reason");
            doc.rows ~= row;
        }
    }
    return doc;
}

private PlanItem[] parsePlan(string text)
{
    PlanItem[] items;
    PlanItem current;
    bool inItem;
    foreach (raw; text.splitLines())
    {
        auto line = raw.strip();
        if (!line.length || line.startsWith("//"))
            continue;
        if (line.startsWith("item "))
        {
            if (inItem)
                items ~= current;
            current = PlanItem.init;
            current.id = firstQuote(line);
            current.title = prop(line, "title");
            auto status = prop(line, "status");
            if (status.length)
                current.status = status;
            inItem = true;
            continue;
        }
        if (!inItem)
            continue;
        if (line.startsWith("needs "))
        {
            current.needs = allQuotes(line);
            continue;
        }
        if (line.startsWith("plan "))
            current.plan = prop(line, "plan").length ? prop(line, "plan") : firstQuote(line);
        else if (line.startsWith("repo "))
            current.repo = prop(line, "repo").length ? prop(line, "repo") : firstQuote(line);
        else if (line == "}" && current.id.length)
        {
            items ~= current;
            current = PlanItem.init;
            inItem = false;
        }
    }
    if (inItem && current.id.length)
        items ~= current;
    return items;
}

private string firstQuote(string line)
{
    auto quotes = allQuotes(line);
    return quotes.length ? quotes[0] : "";
}

private string[] allQuotes(string line)
{
    string[] values;
    bool inQuote;
    string current;
    bool escape;
    foreach (ch; line)
    {
        if (escape)
        {
            current ~= ch;
            escape = false;
            continue;
        }
        if (ch == '\\')
        {
            if (inQuote)
                escape = true;
            continue;
        }
        if (ch == '"')
        {
            if (inQuote)
            {
                values ~= current;
                current = "";
            }
            inQuote = !inQuote;
            continue;
        }
        if (inQuote)
            current ~= ch;
    }
    return values;
}

private string prop(string line, string key)
{
    auto token = key ~ "=";
    auto i = line.indexOf(token);
    if (i < 0)
        return "";
    auto rest = line[i + token.length .. $];
    if (rest.length && rest[0] == '"')
    {
        auto quotes = allQuotes(rest);
        return quotes.length ? quotes[0] : "";
    }
    auto end = rest.indexOf(' ');
    return end < 0 ? rest : rest[0 .. end];
}

