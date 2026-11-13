module coordination.prohelp_gate;

import prohelp.config : InterceptConfig;
import prohelp.intercept : intercept;

enum helpSchema = import("agent-coordinator.sdl");

bool showProhelp(string[] args)
{
    auto cfg = InterceptConfig.fromContent(helpSchema, "agent-coordinator.sdl");
    auto shown = args;
    if (shown.length >= 2 && (shown[1] == "-help" || shown[1] == "--help"))
    {
        shown = shown.dup;
        shown[1] = "?";
    }
    if (shown.length < 2)
        return intercept(["agent-coordinator", "?"], cfg);
    return intercept(shown, cfg);
}

bool showProhelpPath(string section)
{
    auto cfg = InterceptConfig.fromContent(helpSchema, "agent-coordinator.sdl");
    return intercept(["agent-coordinator", "?", section], cfg);
}
