module coordination.listen;

import coordination.supervisor : dispatchServe;

int runListen(string[] args, bool asJson = false, string dbPath = "")
{
    return dispatchServe(args, asJson, dbPath);
}
