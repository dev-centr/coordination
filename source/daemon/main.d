module coordination.daemon;

import coordination.listen : runListen;

int main(string[] args)
{
    return runListen(args[1 .. $]);
}
