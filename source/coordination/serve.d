module coordination.serve;

import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketShutdown, TcpSocket;
import std.string : indexOf, lineSplitter, split, strip, toLower;

import coordination.api : Reply, dispatch;
import coordination.store : Store;

void serve(ref Store store, string bindAddr, ushort port, string appDir, bool publicMode)
{
    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    listener.bind(new InternetAddress(bindAddr, port));
    listener.listen(32);
    while (true)
    {
        auto client = listener.accept();
        scope (exit)
            client.close();
        bool loopback = false;
        try
        {
            auto text = client.remoteAddress().toAddrString();
            loopback = text == "127.0.0.1" || text == "::1";
            handle(store, client, appDir, publicMode, loopback);
        }
        catch (Exception e)
        {
            import std.stdio : stderr;
            stderr.writeln(e.msg);
        }
    }
}

private void handle(ref Store store, Socket client, string appDir, bool publicMode, bool loopback)
{
    ubyte[] buf;
    string header;
    while (header.indexOf("\r\n\r\n") < 0)
    {
        ubyte[4096] chunk;
        auto n = client.receive(chunk);
        if (n <= 0)
            return;
        buf ~= chunk[0 .. n];
        header = cast(string) buf;
        if (buf.length > 65_536 && header.indexOf("\r\n\r\n") < 0)
            return;
    }
    auto splitAt = header.indexOf("\r\n\r\n");
    auto head = header[0 .. splitAt];
    auto rest = buf[splitAt + 4 .. $];
    auto lines = head.lineSplitter();
    string request;
    if (!lines.empty)
    {
        request = lines.front;
        lines.popFront();
    }
    auto parts = request.split(" ");
    if (parts.length < 2)
        return;
    auto method = parts[0];
    auto target = parts[1];
    long length;
    string bearer;
    foreach (line; lines)
    {
        auto lower = line.toLower();
        if (lower.startsWith("content-length:"))
            length = to!long(line[line.indexOf(":") + 1 .. $].strip());
        else if (lower.startsWith("authorization:"))
        {
            auto value = line[line.indexOf(":") + 1 .. $].strip();
            if (value.toLower().startsWith("bearer "))
                bearer = value[7 .. $].strip();
        }
    }
    while (rest.length < length)
    {
        ubyte[4096] chunk;
        auto n = client.receive(chunk);
        if (n <= 0)
            break;
        rest ~= chunk[0 .. n];
    }
    string payload;
    if (length > 0 && rest.length >= length)
        payload = cast(string) rest[0 .. cast(size_t) length];
    auto reply = dispatch(store, method, target, payload, publicMode, bearer, loopback, appDir);
    send(client, reply);
}

private void send(Socket client, Reply reply)
{
    import std.format : format;
    auto bytes = cast(ubyte[]) reply.body;
    auto head = format("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
        reply.status, reason(reply.status), reply.contentType, bytes.length);
    client.send(cast(ubyte[]) head);
    if (bytes.length)
        client.send(bytes);
    client.shutdown(SocketShutdown.SEND);
}

private string reason(int status)
{
    switch (status)
    {
    case 200:
        return "OK";
    case 400:
        return "Bad Request";
    case 401:
        return "Unauthorized";
    case 402:
        return "Payment Required";
    case 403:
        return "Forbidden";
    case 404:
        return "Not Found";
    default:
        return "OK";
    }
}

