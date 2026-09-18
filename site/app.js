import { CONFIG } from "./config.js";

const $ = (id) => document.getElementById(id);
const COLS = "ABCDE";
const ETH = 10n ** 18n;
const REVEAL_MS = 4200;

const ui = {
  board: $("board"), round: $("round-id"), countdown: $("countdown"), bar: $("progress-bar"),
  total: $("hud-total"), pot: $("hud-pot"), rollover: $("hud-rollover"), epoch: $("hud-epoch"),
  amount: $("amount"), deploy: $("deploy"), picked: $("picked"), status: $("status"), feed: $("feed"),
  tag: $("mode-tag"), connect: $("connect"), actions: $("actions"), draw: $("draw"), claim: $("claim"),
  claimStock: $("claim-stock"), controls: $("controls"),
};

const view = {
  picked: new Set(),
  round: 0,
  endsAt: 0,
  duration: 60,
  totals: Array(25).fill(0n),
  mine: Array(25).fill(0n),
  winner: null, // square index while a result is on screen
  pot: 0n,
  rollover: 0n,
  epoch: 0,
};

// ------------------------------------------------------------------ formatting

function fmt(wei, digits = 3) {
  const neg = wei < 0n;
  if (neg) wei = -wei;
  const scale = 10n ** BigInt(digits);
  const scaled = (wei * scale + ETH / 2n) / ETH;
  const whole = scaled / scale;
  const frac = (scaled % scale).toString().padStart(digits, "0");
  return `${neg ? "-" : ""}${whole}.${frac}`;
}

function toWei(text) {
  const clean = String(text).trim().replace(",", ".");
  if (!/^\d*\.?\d*$/.test(clean) || clean === "" || clean === ".") return 0n;
  const [whole, frac = ""] = clean.split(".");
  return BigInt(whole || "0") * ETH + BigInt((frac + "0".repeat(18)).slice(0, 18));
}

const coord = (i) => `${COLS[i % 5]}${Math.floor(i / 5) + 1}`;
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

function say(text, kind = "") {
  ui.status.textContent = text;
  ui.status.className = `status ${kind}`.trim();
}

function log(html) {
  const li = document.createElement("li");
  li.innerHTML = html;
  ui.feed.prepend(li);
  while (ui.feed.children.length > 6) ui.feed.lastChild.remove();
}

// ------------------------------------------------------------------ board

const cells = [];
for (let i = 0; i < 25; i++) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "cell";
  b.setAttribute("aria-pressed", "false");
  b.innerHTML = `<span class="coord">${coord(i)}</span><span class="mine"></span><span class="eth">0.000</span><span class="fill"></span>`;
  b.addEventListener("click", () => togglePick(i));
  ui.board.append(b);
  cells.push({ el: b, eth: b.querySelector(".eth"), fill: b.querySelector(".fill") });
}

function togglePick(i) {
  if (view.winner !== null) return;
  view.picked.has(i) ? view.picked.delete(i) : view.picked.add(i);
  paint();
}

document.querySelectorAll("[data-pick]").forEach((btn) =>
  btn.addEventListener("click", () => {
    const kind = btn.dataset.pick;
    view.picked.clear();
    if (kind === "all") for (let i = 0; i < 25; i++) view.picked.add(i);
    if (kind === "random") while (view.picked.size < 5) view.picked.add(Math.floor(Math.random() * 25));
    paint();
  })
);

function paint() {
  const max = view.totals.reduce((m, v) => (v > m ? v : m), 0n);
  let sum = 0n;
  cells.forEach((c, i) => {
    const t = view.totals[i];
    sum += t;
    c.eth.textContent = fmt(t);
    c.fill.style.height = max === 0n ? "0%" : `${Number((t * 100n) / max)}%`;
    c.el.classList.toggle("picked", view.picked.has(i) && view.winner === null);
    c.el.classList.toggle("has-mine", view.mine[i] > 0n);
    c.el.classList.toggle("winner", view.winner === i);
    c.el.classList.toggle("loser", view.winner !== null && view.winner !== i);
    c.el.setAttribute("aria-pressed", String(view.picked.has(i)));
    c.el.setAttribute("aria-label", `${coord(i)}, ${fmt(t)} ETH${view.mine[i] > 0n ? `, yours ${fmt(view.mine[i])}` : ""}`);
  });
  ui.round.textContent = `#${view.round}`;
  ui.total.textContent = fmt(sum);
  ui.pot.textContent = fmt(view.pot);
  ui.rollover.textContent = fmt(view.rollover);
  ui.epoch.textContent = String(view.epoch);
  ui.picked.textContent = String(view.picked.size);
  ui.deploy.disabled = view.picked.size === 0 || view.winner !== null;
}

function tickClock() {
  const left = Math.max(0, view.endsAt - Date.now() / 1000);
  ui.countdown.textContent = String(Math.ceil(left)).padStart(2, "0");
  const done = Math.min(1, 1 - left / view.duration);
  ui.bar.style.width = `${done * 100}%`;
  document.documentElement.style.setProperty("--p", done.toFixed(3));
}

// ------------------------------------------------------------------ simulation (no contract configured)

function startSimulation() {
  ui.tag.textContent = "SIMULATION";
  ui.connect.addEventListener("click", () => say("The wallet connects once the contract is live. This grid is a simulation.", ""));
  const CUT = 1000n;
  const STOCKS = Object.values(CONFIG.STOCKS);
  const sim = { genesis: Date.now() / 1000, revealing: false };
  view.duration = 20;
  view.round = 1;
  view.endsAt = sim.genesis + view.duration;
  $("fact-round").textContent = "60 s";
  say("Simulation: no real ETH. Pick squares and deploy to see how a round plays out.");

  const bots = ["0x7a3f…c21e", "0x19bd…04aa", "0xe0c4…77b9", "0x42d1…9f03", "0xb6e8…5d10", "0x0f27…a8c4"];
  function botMove() {
    if (sim.revealing) return;
    const n = 1 + Math.floor(Math.random() * 4);
    const per = BigInt(2 + Math.floor(Math.random() * 40)) * (ETH / 1000n);
    const hot = Math.floor(Math.random() * 25);
    for (let k = 0; k < n; k++) {
      const sq = Math.random() < 0.35 ? hot : Math.floor(Math.random() * 25);
      view.totals[sq] += per;
    }
    log(`<b>deploy</b> <span>${bots[Math.floor(Math.random() * bots.length)]}</span> ${fmt(per * BigInt(n))} ETH on ${n} sq`);
    paint();
  }

  ui.controls.addEventListener("submit", (e) => {
    e.preventDefault();
    const total = toWei(ui.amount.value);
    const count = BigInt(view.picked.size);
    if (count === 0n || total / count < ETH / 10000n) return say("At least 0.0001 ETH per square.", "err");
    const per = total / count;
    for (const i of view.picked) {
      view.totals[i] += per;
      view.mine[i] += per;
    }
    log(`<b>deploy</b> <span>you</span> ${fmt(per * count)} ETH on ${count} sq`);
    say(`Deployed ${fmt(per * count)} ETH on ${count} squares (simulated).`, "ok");
    view.picked.clear();
    paint();
  });

  function settle() {
    sim.revealing = true;
    const winner = Math.floor(Math.random() * 25);
    const total = view.totals.reduce((s, v) => s + v, 0n);
    const winStake = view.totals[winner];
    const losers = total - winStake;
    const cut = (losers * CUT) / 10000n;
    view.pot += cut;
    let prize = 0n;
    if (winStake === 0n) view.rollover += losers - cut;
    else {
      prize = losers - cut + view.rollover;
      view.rollover = 0n;
    }
    view.winner = winner;
    const myStake = view.mine[winner];
    const mineTotal = view.mine.reduce((s, v) => s + v, 0n);
    log(`<b>round #${view.round}</b> winner <span>${coord(winner)}</span> · prize ${fmt(prize)} ETH · pot +${fmt(cut)}`);
    if (myStake > 0n) say(`${coord(winner)} won. You collect ${fmt(myStake + (prize * myStake) / winStake)} ETH (simulated).`, "ok");
    else if (mineTotal > 0n) say(`${coord(winner)} won. Your ${fmt(mineTotal)} ETH went to the winners (simulated).`, "err");
    else say(`${coord(winner)} won round #${view.round}.`);
    paint();

    setTimeout(() => {
      if (view.round % 4 === 0 && view.pot > 0n) {
        const stock = STOCKS[Math.floor(Math.random() * STOCKS.length)];
        log(`<b>epoch ${view.epoch}</b> pot ${fmt(view.pot)} ETH → <span>${stock}</span> · 50% miners · 50% stakers`);
        view.pot = 0n;
        view.epoch += 1;
      }
      view.round += 1;
      view.totals.fill(0n);
      view.mine.fill(0n);
      view.winner = null;
      sim.revealing = false;
      view.endsAt = Date.now() / 1000 + view.duration;
      paint();
    }, REVEAL_MS);
  }

  setInterval(() => {
    tickClock();
    if (!sim.revealing && Date.now() / 1000 >= view.endsAt) settle();
  }, 200);
  setInterval(botMove, 900);
  for (let i = 0; i < 6; i++) botMove();
  paint();
}

// ------------------------------------------------------------------ live (contract configured)

async function startLive() {
  const { createPublicClient, createWalletClient, http, custom, parseAbi, defineChain } = await import("https://esm.sh/viem@2.21.55");

  const abi = parseAbi([
    "function genesis() view returns (uint256)",
    "function roundDuration() view returns (uint256)",
    "function minPerSquare() view returns (uint256)",
    "function cutBps() view returns (uint256)",
    "function paused() view returns (bool)",
    "function potEth() view returns (uint256)",
    "function rollover() view returns (uint256)",
    "function epoch() view returns (uint256)",
    "function token() view returns (address)",
    "function rounds(uint256) view returns (uint8 state, uint8 winner, uint64 targetBlock, uint64 epoch, uint256 total, uint256 winnersStake, uint256 prize)",
    "function squareTotals(uint256) view returns (uint256[25])",
    "function deployedBy(uint256, address) view returns (uint256[25])",
    "function claimable(uint256, address) view returns (uint256)",
    "function claimableStock(uint256, address) view returns (address stock, uint256 amount)",
    "function deploy(uint32 mask) payable",
    "function close(uint256 round)",
    "function settle(uint256 round)",
    "function claim(uint256[] roundIds)",
    "function claimStock(uint256[] epochIds)",
    "event RoundSettled(uint256 indexed round, uint8 winner, uint256 total, uint256 winnersStake, uint256 prize, uint256 cut)",
    "event EpochClosed(uint256 indexed epoch, address indexed stock, uint256 ethSpent, uint256 bought, uint256 toMiners, uint256 toStakers)",
  ]);

  const chain = defineChain({
    id: CONFIG.CHAIN_ID,
    name: CONFIG.CHAIN_NAME,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [CONFIG.RPC] } },
    blockExplorers: { default: { name: "Blockscout", url: CONFIG.EXPLORER } },
  });
  const address = CONFIG.CONTRACT;
  const pub = createPublicClient({ chain, transport: http(CONFIG.RPC, { batch: true }) });
  const read = (functionName, args = []) => pub.readContract({ address, abi, functionName, args });

  ui.tag.textContent = "LIVE";
  ui.tag.classList.add("live");
  ui.actions.hidden = false;
  const link = $("contract-link");
  link.href = `${CONFIG.EXPLORER}/address/${address}`;
  link.hidden = false;

  const [genesis, duration, minPerSquare, cutBps, token] = await Promise.all([
    read("genesis"), read("roundDuration"), read("minPerSquare"), read("cutBps"), read("token"),
  ]);
  view.duration = Number(duration);
  $("fact-round").textContent = `${view.duration} s`;
  $("fact-cut").textContent = `${Number(cutBps) / 100} %`;
  if (!/^0x0{40}$/.test(token)) $("token-address").textContent = `token: ${token}`;

  let account = null;
  let wallet = null;
  let reveal = null; // { round, until } while a finished round stays on screen
  let claimRounds = [];
  let claimEpochs = [];
  const seenSettled = new Set();

  const roundNow = () => Math.floor((Date.now() / 1000 - Number(genesis)) / view.duration);

  async function refresh() {
    const current = roundNow();
    const shown = reveal && Date.now() < reveal.until ? reveal.round : current;
    if (reveal && Date.now() >= reveal.until) reveal = null;
    const [totals, round, pot, rollover, epoch, mine, prev] = await Promise.all([
      read("squareTotals", [BigInt(shown)]),
      read("rounds", [BigInt(shown)]),
      read("potEth"), read("rollover"), read("epoch"),
      account ? read("deployedBy", [BigInt(shown), account]) : Promise.resolve(Array(25).fill(0n)),
      current > 0 ? read("rounds", [BigInt(current - 1)]) : Promise.resolve(null),
    ]);
    view.round = shown;
    view.endsAt = Number(genesis) + (current + 1) * view.duration;
    view.totals = [...totals];
    view.mine = [...mine];
    view.pot = pot;
    view.rollover = rollover;
    view.epoch = Number(epoch);
    view.winner = round[0] === 2 ? Number(round[1]) : null;

    if (prev) {
      const [state, winner, , , total, , prize] = prev;
      const id = current - 1;
      ui.draw.hidden = !(state !== 2 && total > 0n);
      if (state === 2 && !seenSettled.has(id)) {
        seenSettled.add(id);
        if (seenSettled.size > 1 || total > 0n) {
          log(`<b>round #${id}</b> winner <span>${coord(Number(winner))}</span> · prize ${fmt(prize)} ETH`);
          reveal = { round: id, until: Date.now() + REVEAL_MS };
        }
      }
    }
    paint();
  }

  async function refreshClaims() {
    if (!account) return;
    const current = roundNow();
    const ids = [];
    for (let r = current - 1; r >= 0 && r > current - 41; r--) ids.push(r);
    const owed = await Promise.all(ids.map((r) => read("claimable", [BigInt(r), account])));
    claimRounds = ids.filter((_, i) => owed[i] > 0n);
    const totalOwed = owed.reduce((s, v) => s + v, 0n);
    ui.claim.hidden = claimRounds.length === 0;
    ui.claim.textContent = `Claim ${fmt(totalOwed, 4)} ETH`;

    const epochs = [];
    for (let e = view.epoch - 1; e >= 0 && e > view.epoch - 13; e--) epochs.push(e);
    const stock = await Promise.all(epochs.map((e) => read("claimableStock", [BigInt(e), account])));
    claimEpochs = epochs.filter((_, i) => stock[i][1] > 0n);
    ui.claimStock.hidden = claimEpochs.length === 0;
    if (claimEpochs.length) {
      const names = [...new Set(stock.filter((s) => s[1] > 0n).map((s) => CONFIG.STOCKS[s[0].toLowerCase()] || short(s[0])))];
      ui.claimStock.textContent = `Claim stocks (${names.join(", ")})`;
    }
  }

  async function connect() {
    if (!window.ethereum) return say("No wallet found in this browser.", "err");
    try {
      const [acc] = await window.ethereum.request({ method: "eth_requestAccounts" });
      const hexId = `0x${CONFIG.CHAIN_ID.toString(16)}`;
      try {
        await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
      } catch (err) {
        if (err?.code !== 4902) throw err;
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{ chainId: hexId, chainName: CONFIG.CHAIN_NAME, rpcUrls: [CONFIG.RPC], blockExplorerUrls: [CONFIG.EXPLORER], nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 } }],
        });
      }
      account = acc;
      wallet = createWalletClient({ account, chain, transport: custom(window.ethereum) });
      ui.connect.textContent = short(account);
      say("Wallet connected.", "ok");
      refresh();
      refreshClaims();
    } catch (err) {
      say(err?.shortMessage || err?.message || "Wallet connection refused.", "err");
    }
  }

  async function send(label, functionName, args, value) {
    if (!wallet) {
      await connect();
      if (!wallet) return null;
    }
    try {
      say(`${label}: confirm in your wallet…`);
      const { request } = await pub.simulateContract({ address, abi, functionName, args, value, account });
      const hash = await wallet.writeContract(request);
      say(`${label}: waiting for the chain…`);
      const receipt = await pub.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("transaction reverted");
      say(`${label}: done.`, "ok");
      return receipt;
    } catch (err) {
      say(`${label}: ${err?.shortMessage || err?.message || "failed"}`, "err");
      return null;
    }
  }

  ui.connect.addEventListener("click", connect);
  window.ethereum?.on?.("accountsChanged", () => location.reload());

  ui.controls.addEventListener("submit", async (e) => {
    e.preventDefault();
    const total = toWei(ui.amount.value);
    const count = BigInt(view.picked.size);
    if (count === 0n) return;
    if (total / count < minPerSquare) return say(`At least ${fmt(minPerSquare, 4)} ETH per square.`, "err");
    let mask = 0;
    for (const i of view.picked) mask |= 1 << i;
    const ok = await send("Deploy", "deploy", [mask >>> 0], total);
    if (ok) {
      view.picked.clear();
      refresh();
    }
  });

  ui.draw.addEventListener("click", async () => {
    const id = BigInt(roundNow() - 1);
    const round = await read("rounds", [id]);
    if (round[0] === 2) return refresh();
    let needsClose = round[0] === 0;
    if (!needsClose) {
      // closed already: settle if the target block is still readable, otherwise close again
      try {
        await pub.simulateContract({ address, abi, functionName: "settle", args: [id], account: account ?? undefined });
      } catch (err) {
        needsClose = /TargetExpired/.test(String(err?.message));
        if (!needsClose && !/TargetNotReached/.test(String(err?.message))) return say(err?.shortMessage || "Cannot draw yet.", "err");
      }
    }
    if (needsClose && !(await send("Close round", "close", [id]))) return;
    await new Promise((r) => setTimeout(r, 1500));
    await send("Draw", "settle", [id]);
    refresh();
  });

  ui.claim.addEventListener("click", async () => {
    if (await send("Claim", "claim", [claimRounds.map(BigInt)])) refreshClaims();
  });
  ui.claimStock.addEventListener("click", async () => {
    if (await send("Claim stocks", "claimStock", [claimEpochs.map(BigInt)])) refreshClaims();
  });

  pub.watchContractEvent({
    address, abi, eventName: "EpochClosed", pollingInterval: 8000,
    onLogs: (logs) => logs.forEach((l) => log(`<b>epoch ${l.args.epoch}</b> pot ${fmt(l.args.ethSpent)} ETH → <span>${CONFIG.STOCKS[l.args.stock.toLowerCase()] || short(l.args.stock)}</span>`)),
  });

  say("Pick squares, set an amount, deploy.");
  setInterval(tickClock, 200);
  const loop = async () => {
    try { await refresh(); } catch { say("Cannot reach the chain right now, retrying…", "err"); }
    setTimeout(loop, 1500);
  };
  loop();
  setInterval(() => refreshClaims().catch(() => {}), 10000);
}

// ------------------------------------------------------------------ boot

$("repo-link").href = CONFIG.REPO;
paint();
if (/^0x[0-9a-fA-F]{40}$/.test(CONFIG.CONTRACT)) {
  startLive().catch((err) => {
    console.error(err);
    say("Could not load the live contract. Showing the page without data.", "err");
  });
} else {
  startSimulation();
}
