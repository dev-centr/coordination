const boardsEl = document.querySelector("#boards");
const titleEl = document.querySelector("#board-title");
const treeEl = document.querySelector("#tree");
const waitsEl = document.querySelector("#waits");
const aliasesEl = document.querySelector("#aliases");
const hintEl = document.querySelector("#hint");

async function loadBoards() {
  const data = await (await fetch("/api/boards")).json();
  boardsEl.replaceChildren();
  for (const board of data.boards) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = board.title || board.id;
    button.addEventListener("click", () => openBoard(board.id));
    li.append(button);
    boardsEl.append(li);
  }
}

function nest(nodes) {
  const byParent = new Map();
  for (const node of nodes) {
    const key = node.parent || "";
    if (!byParent.has(key)) byParent.set(key, []);
    byParent.get(key).push(node);
  }
  function build(parent) {
    const ul = document.createElement("ul");
    for (const node of byParent.get(parent) || []) {
      const li = document.createElement("li");
      li.className = "node";
      const title = document.createElement("strong");
      title.textContent = node.title;
      const meta = document.createElement("span");
      meta.className = "status";
      const bits = [node.status];
      if (node.cachedWaitStatus) bits.push("wait " + node.cachedWaitStatus);
      if (node.needs && node.needs.length) bits.push("needs " + node.needs.join(", "));
      meta.textContent = " " + bits.join(" · ");
      li.append(title, meta);
      const children = build(node.id);
      if (children.childElementCount) li.append(children);
      ul.append(li);
    }
    return ul;
  }
  return build("");
}

async function openBoard(id) {
  const board = await (await fetch("/api/boards/" + encodeURIComponent(id))).json();
  titleEl.textContent = board.title || board.id;
  treeEl.replaceChildren(nest(board.nodes || []));
  waitsEl.replaceChildren();
  for (const wait of board.waits || []) {
    const li = document.createElement("li");
    const node = (board.nodes || []).find((item) => item.id === wait.nodeId);
    const seconds = Math.round((wait.estimatedWaitMs || 0) / 1000);
    li.textContent = (node ? node.title : wait.nodeId) + " · " + wait.status + " · " + seconds + "s";
    if (wait.waitHubId) li.textContent += " · " + wait.waitHubId;
    waitsEl.append(li);
  }
  aliasesEl.replaceChildren();
  for (const alias of board.aliases || []) {
    const li = document.createElement("li");
    li.textContent = alias.kind + " " + (alias.live ? "live" : alias.role) + " " + alias.value;
    aliasesEl.append(li);
  }
  document.querySelector("#resolve [name=chat]").value = board.kind === "chat" ? board.id : "";
}

document.querySelector("#import").addEventListener("click", async () => {
  const result = await (await fetch("/api/import", { method: "POST", body: "{}" })).json();
  hintEl.textContent = "Imported " + result.nodes + " nodes from " + result.sessions;
  await loadBoards();
});

document.querySelector("#resolve").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.target);
  const body = {
    chat: form.get("chat"),
    cursorChat: form.get("cursorChat"),
    segment: form.get("segment"),
    quote: form.get("quote"),
  };
  const response = await fetch("/api/resolve", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await response.json();
  hintEl.textContent = data.hint + (data.path ? "\n" + data.path : "");
});

loadBoards();
