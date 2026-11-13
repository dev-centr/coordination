<div align="center">

<a href="https://github.com/dev-centr/coordination/graphs/contributors"><img src="https://img.shields.io/github/contributors/dev-centr/coordination.svg?style=for-the-badge" alt="Contributors"></a>
<a href="https://github.com/dev-centr/coordination/network/members"><img src="https://img.shields.io/github/forks/dev-centr/coordination.svg?style=for-the-badge" alt="Forks"></a>
<a href="https://github.com/dev-centr/coordination/stargazers"><img src="https://img.shields.io/github/stars/dev-centr/coordination.svg?style=for-the-badge" alt="Stargazers"></a>
<a href="https://github.com/dev-centr/coordination/issues"><img src="https://img.shields.io/github/issues/dev-centr/coordination.svg?style=for-the-badge" alt="Issues"></a>
<a href="https://github.com/dev-centr/coordination/blob/main/LICENSE"><img src="https://img.shields.io/github/license/dev-centr/coordination.svg?style=for-the-badge" alt="MIT License"></a>

# coordination

The command is `agent-coordinator`. It keeps the plan an agent opens, and the schedule row on each step of that plan.

[Changelog](CHANGELOG.adoc)

</div>

<details>
<summary>Table of contents</summary>

- [About](#about)
- [Getting started](#getting-started)
- [Command](#command)
- [Local app and API](#local-app-and-api)
- [Hosted database](#hosted-database)
- [Wait queue](#wait-queue)
- [Built with](#built-with)
- [License](#license)
- [Contact](#contact)

</details>

## About

`agent-coordinator plan` is the plan tree. A node is a piece of work: its title, what it needs, and a link back to the transcript sentence it came from. `agent-coordinator schedule` writes the wait on that node: the estimate, the status, and the wait-hub id to check. The wait is not a second copy of the plan.

The same database is the fast copy on this machine and, with a hosted token, the copy Dev-Centr serves for other machines. The git routine ledger remains the record for when no database is up.

<p align="right">(<a href="#coordination">back to top</a>)</p>

## Getting started

LDC and dub. The library's registry is the [DUB registry](https://code.dlang.org/). This repository is the package. Publish it there when you want `dub add coordination` instead of a checkout.

```powershell
git clone https://github.com/dev-centr/coordination.git "$env:code\github.com\dev-centr\coordination"
cd "$env:code\github.com\dev-centr\coordination"
dub build -c cli --compiler=ldc2
dub test --compiler=ldc2
```

The database file is `%LOCALAPPDATA%\AgentWorkspace\coordination\coordination.db`.

<p align="right">(<a href="#coordination">back to top</a>)</p>

## Command

`agent-coordinator` with no arguments lists `plan` and `schedule`. `agent-coordinator doctor` prints the version, the database path, and the counts. `agent-coordinator plan resolve` exits 2 when a link does not open and prints a hint: the chat was never recorded, the workspace split the transcript, or the folder is gone.

```powershell
dub run -c cli --compiler=ldc2 -- serve
dub run -c cli --compiler=ldc2 -- plan import
dub run -c cli --compiler=ldc2 -- plan tree --board <chat-id>
```

<p align="right">(<a href="#coordination">back to top</a>)</p>

## Local app and API

`agent-coordinator serve` starts that listener in the background on `http://127.0.0.1:17359` and prints `serve stop 1`. `serve -listen` keeps the lines in this window. `serve status` lists each instance and the terminal that started it. The front page is the local browser: boards, the plan tree, the waits under those nodes, transcript folders, and a resolve box.

`GET /health` returns the version and build id. `GET /api/diagnostics` is the debug dump: paths and counts, no tokens.

<p align="right">(<a href="#coordination">back to top</a>)</p>

## Hosted database

`agent-coordinator serve --public` binds a reachable address and refuses calls that do not carry a hosted token. Issue tokens on the machine itself:

```powershell
dub run -c cli --compiler=ldc2 -- account issue --token <secret> --plan hosted --label "dev-centr"
```

A workstation token is for this computer. On the public port it gets HTTP 402 and a hint that the online database is the Dev-Centr hosted plan. This build does not charge a card. Dev-Centr issues the hosted token after it sells the plan.

If the server is unhealthy, `GET /health` fails and `agent-coordinator doctor` still reads the local file. Start it again with `agent-coordinator serve`. The column view on port 17358 keeps reading its JSON files when this database is down. Those files are that view's copy of the schedule. They are not the routine ledger. The routine ledger is recurring work stored in git.

<p align="right">(<a href="#coordination">back to top</a>)</p>

## Wait queue

[plan-stack](https://github.com/dev-centr/plan-stack) draws the schedule as session columns, with each cell sized by the estimate. The command for the plan and the wait row is `agent-coordinator`. When that column view saves a phase it sends the plan body into this database once, then updates only the wait row. A later save does not replace a title the plan tree already has. The phase keeps `planNodeId` so the column points at the node.

[wait-hub](https://github.com/dev-centr/wait-hub) remains the completion signal a wait row can name.

<p align="right">(<a href="#coordination">back to top</a>)</p>

## Built with

| Role | Piece |
| --- | --- |
| Runtime | LDC |
| Database | SQLite through [d2sqlite3](https://code.dlang.org/packages/d2sqlite3) |
| Local app | HTML page served by the daemon |

<p align="right">(<a href="#coordination">back to top</a>)</p>

## License

MIT. See [LICENSE](LICENSE).

## Contact

Dev-Centr — [github.com/dev-centr](https://github.com/dev-centr)
