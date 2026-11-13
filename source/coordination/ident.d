module coordination.ident;

enum coordinationVersion = "0.1.0";
enum coordinationBuild = "dev";

string coordinationBanner()
{
    return "coordination " ~ coordinationVersion ~ " (" ~ coordinationBuild ~ ")";
}
