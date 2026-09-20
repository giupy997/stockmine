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
  claimStock: $("claim-stock"), controls: $("controls"), clock: document.querySelector(".panel-clock"),
  stakeTag: $("stake-tag"), stakeMine: $("stake-mine"), stakeTotal: $("stake-total"), stakeShare: $("stake-share"),
  stakeUnlock: $("stake-unlock"), stakeBalance: $("stake-balance"), stakeSymbol: $("stake-symbol"),
  stakeAmount: $("stake-amount"), stakeMax: $("stake-max"), stakeBtn: $("stake-btn"), unstakeBtn: $("unstake-btn"),
  stakeEarned: $("stake-earned"), stakeClaim: $("stake-claim"), stakeStatus: $("stake-status"), stakeDelay: $("stake-delay"),
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

const vault = {
  enabled: true,
  symbol: "tokens",
  mine: 0n,
  total: 0n,
  balance: 0n,
  unlockAt: 0, // unix seconds
  earned: Object.values(CONFIG.STOCKS).map((symbol) => ({ symbol, amount: 0n })),
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

/** Token amounts: thousands separators, at most two decimals, none when they are zero. */
function fmtTok(wei) {
  const [whole, frac] = fmt(wei, 2).split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return frac === "00" ? grouped : `${grouped}.${frac}`;
}

/** Returns 0n for anything that is not a plain decimal. "1,500" is refused rather than read as 1.5. */
function toWei(text) {
  const raw = String(text).trim();
  if (/^[1-9]\d*,\d{3}$/.test(raw) || (raw.match(/[.,]/g) || []).length > 1) return 0n;
  const clean = raw.replace(",", ".");
  if (!/^\d*\.?\d*$/.test(clean) || clean === "" || clean === ".") return 0n;
  const [whole, frac = ""] = clean.split(".");
  return BigInt(whole || "0") * ETH + BigInt((frac + "0".repeat(18)).slice(0, 18));
}

/** Plain decimal string for an input field: no separators, no trailing zeros. */
function plain(wei) {
  const whole = wei / ETH;
  const frac = (wei % ETH).toString().padStart(18, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : `${whole}`;
}

function timeLeft(seconds) {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `in ${d}d ${h}h`;
  if (h > 0) return `in ${h}h ${m}m`;
  return m > 0 ? `in ${m}m` : `in ${Math.ceil(seconds)}s`;
}

const coord = (i) => `${COLS[i % 5]}${Math.floor(i / 5) + 1}`;
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

function sayTo(el, text, kind = "") {
  el.textContent = text;
  el.className = `status ${kind}`.trim();
}
const say = (text, kind) => sayTo(ui.status, text, kind);
const sayStake = (text, kind) => sayTo(ui.stakeStatus, text, kind);

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

let onDeploy = null; // set by the simulation or by the live mode
ui.controls.addEventListener("submit", (e) => {
  e.preventDefault();
  onDeploy?.();
});

/** Runs an async click handler once at a time: the button stays disabled and failures reach the status line. */
function guard(button, tell, fn) {
  button.addEventListener("click", async () => {
    if (button.dataset.busy === "1") return;
    button.dataset.busy = "1";
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    try {
      await fn();
    } catch (err) {
      console.error(err);
      tell("Cannot reach the chain right now, try again.", "err");
    } finally {
      delete button.dataset.busy;
      button.removeAttribute("aria-busy");
      button.disabled = false;
      paint();
      paintVault();
    }
  });
}
const isBusy = (button) => button.dataset.busy === "1";

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
  ui.deploy.disabled = view.picked.size === 0 || view.winner !== null || isBusy(ui.deploy);
}

function tickClock() {
  const left = Math.max(0, view.endsAt - Date.now() / 1000);
  ui.countdown.textContent = String(Math.ceil(left)).padStart(2, "0");
  const done = Math.min(1, 1 - left / view.duration);
  ui.bar.style.width = `${done * 100}%`;
  document.documentElement.style.setProperty("--p", done.toFixed(3));
  ui.clock.classList.toggle("urgent", left > 0 && left <= 5);
}

// ------------------------------------------------------------------ staking vault (shared rendering)

function paintVault() {
  ui.stakeMine.textContent = fmtTok(vault.mine);
  ui.stakeTotal.textContent = fmtTok(vault.total);
  const share = vault.total === 0n ? 0n : (vault.mine * 1_000_000n) / vault.total;
  ui.stakeShare.textContent = `${(Number(share) / 10_000).toFixed(2)} %`;
  ui.stakeUnlock.textContent = vault.mine === 0n ? "—" : timeLeft(vault.unlockAt - Date.now() / 1000);
  ui.stakeBalance.textContent = fmtTok(vault.balance);
  ui.stakeSymbol.textContent = vault.symbol;

  ui.stakeEarned.replaceChildren(
    ...vault.earned.map(({ symbol, amount }) => {
      const li = document.createElement("li");
      const name = document.createElement("b");
      name.textContent = symbol;
      const value = document.createElement("span");
      value.textContent = fmt(amount, 4);
      li.append(name, value);
      return li;
    })
  );
  const anyEarned = vault.earned.some((e) => e.amount > 0n);
  ui.stakeClaim.disabled = !vault.enabled || !anyEarned || isBusy(ui.stakeClaim);
  ui.stakeBtn.disabled = !vault.enabled || isBusy(ui.stakeBtn);
  ui.unstakeBtn.disabled = !vault.enabled || vault.mine === 0n || isBusy(ui.unstakeBtn);
  ui.stakeAmount.disabled = !vault.enabled;
  ui.stakeMax.disabled = !vault.enabled;
}

function unstakeAmount() {
  const raw = ui.stakeAmount.value.trim();
  const amount = raw === "" ? vault.mine : toWei(raw);
  if (amount === 0n) return sayStake("Type a valid amount (use a dot for decimals).", "err"), null;
  if (amount > vault.mine) return sayStake("That is more than your stake.", "err"), null;
  return amount;
}

ui.stakeMax.addEventListener("click", () => {
  // Max fills whatever the next click can use: the wallet balance, or the stake when the wallet is empty
  ui.stakeAmount.value = plain(vault.balance > 0n ? vault.balance : vault.mine);
});

// ------------------------------------------------------------------ simulation (no contract configured)

function startSimulation() {
  ui.tag.textContent = "SIMULATION";
  ui.connect.addEventListener("click", () => say("The wallet connects once the contract is live. This grid is a simulation.", ""));
  const CUT = 700n;
  const STOCKS = Object.values(CONFIG.STOCKS);
  // rough stock units per ETH, only to make the simulated numbers look plausible
  const UNITS_PER_ETH_X10 = { NVDA: 117n, TSLA: 72n, SPY: 34n, AAPL: 78n };
  const SIM_LOCK_S = 60;
  const BURN = 2000n; // bps of every pot
  const DEMO_TOKENS_PER_ETH = 5_000_000n;
  let simBurned = 0n;
  const sim = { genesis: Date.now() / 1000, revealing: false };
  view.duration = 20;
  view.round = 1;
  view.endsAt = sim.genesis + view.duration;
  $("fact-round").textContent = "60 s";
  say("Simulation: no real ETH. Pick squares and deploy to see how a round plays out.");

  // vault: play tokens for you, a crowd already staked
  vault.symbol = "demo tokens";
  vault.balance = 1_000_000n * ETH;
  vault.total = 42_000_000n * ETH;
  sayStake(`Simulation: play tokens, and the lock lasts ${SIM_LOCK_S} seconds instead of 3 days.`);

  ui.stakeBtn.addEventListener("click", () => {
    const amount = toWei(ui.stakeAmount.value);
    if (amount === 0n) return sayStake("Type a valid amount (use a dot for decimals).", "err");
    if (amount > vault.balance) return sayStake("That is more than your wallet balance.", "err");
    vault.balance -= amount;
    vault.mine += amount;
    vault.total += amount;
    vault.unlockAt = Date.now() / 1000 + SIM_LOCK_S;
    ui.stakeAmount.value = "";
    sayStake(`Staked ${fmtTok(amount)} (simulated). You now earn a share of every stock purchase.`, "ok");
    paintVault();
  });
  ui.unstakeBtn.addEventListener("click", () => {
    const amount = unstakeAmount();
    if (amount === null) return;
    const left = vault.unlockAt - Date.now() / 1000;
    if (left > 0) return sayStake(`Still locked: unlocks ${timeLeft(left)}.`, "err");
    vault.mine -= amount;
    vault.total -= amount;
    vault.balance += amount;
    ui.stakeAmount.value = "";
    sayStake(`Unstaked ${fmtTok(amount)} (simulated).`, "ok");
    paintVault();
  });
  ui.stakeClaim.addEventListener("click", () => {
    const got = vault.earned.filter((e) => e.amount > 0n).map((e) => `${fmt(e.amount, 4)} ${e.symbol}`);
    vault.earned.forEach((e) => (e.amount = 0n));
    sayStake(`Claimed ${got.join(", ")} (simulated).`, "ok");
    paintVault();
  });

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

  onDeploy = () => {
    const total = toWei(ui.amount.value);
    const count = BigInt(view.picked.size);
    if (count === 0n || total / count < ETH / 10000n) return say("At least 0.0001 ETH per square.", "err");
    const per = total / count;
    for (const i of view.picked) {
      view.totals[i] += per;
      view.mine[i] += per;
    }
    log(`<b>deploy</b> <span>you</span> ${fmt(per * count, 4)} ETH on ${count} sq`);
    say(`Deployed ${fmt(per * count, 4)} ETH on ${count} squares (simulated).`, "ok");
    view.picked.clear();
    paint();
  };

  function closeEpoch() {
    const symbol = STOCKS[Math.floor(Math.random() * STOCKS.length)];
    const toBurn = (view.pot * BURN) / 10000n;
    const bought = ((view.pot - toBurn) * (UNITS_PER_ETH_X10[symbol] ?? 50n)) / 10n;
    simBurned += toBurn * DEMO_TOKENS_PER_ETH;
    log(`<b>buyback</b> ${fmt(toBurn)} ETH → <span>${fmtTok(toBurn * DEMO_TOKENS_PER_ETH)} tokens burned</span>`);
    log(`<b>epoch ${view.epoch}</b> pot ${fmt(view.pot)} ETH → <span>${fmt(bought, 2)} ${symbol}</span> · 40% miners · 40% stakers · 20% burn`);
    $("burn-stats").textContent = `Burned so far: ${fmtTok(simBurned)} demo tokens (simulated).`;
    if (vault.mine > 0n) {
      const mineShare = (bought / 2n) * vault.mine / vault.total;
      vault.earned.find((e) => e.symbol === symbol).amount += mineShare;
      paintVault();
    }
    view.pot = 0n;
    view.epoch += 1;
  }

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
    else if (mineTotal > 0n && winStake === 0n) say(`${coord(winner)} was empty: nobody won, the round's ETH rolls over to the next prize (simulated).`, "err");
    else if (mineTotal > 0n) say(`${coord(winner)} won. Your ${fmt(mineTotal)} ETH went to the winners (simulated).`, "err");
    else say(`${coord(winner)} won round #${view.round}.`);
    paint();

    setTimeout(() => {
      try {
        if (view.round % 3 === 0 && view.pot > 0n) closeEpoch();
      } catch (err) {
        console.error(err); // the round reset below must always run
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
  setInterval(paintVault, 1000); // keeps the unlock countdown moving
  for (let i = 0; i < 6; i++) botMove();
  paint();
  paintVault();
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
    "function totalStaked() view returns (uint256)",
    "function unstakeDelay() view returns (uint256)",
    "function staked(address) view returns (uint256)",
    "function stakedAt(address) view returns (uint256)",
    "function pendingStaking(address) view returns (address[] list, uint256[] amounts)",
    "function deploy(uint32 mask) payable",
    "function close(uint256 round)",
    "function settle(uint256 round)",
    "function claim(uint256[] roundIds)",
    "function claimStock(uint256[] epochIds)",
    "function stake(uint256 amount)",
    "function unstake(uint256 amount)",
    "function claimStaking()",
    "function minersShareBps() view returns (uint256)",
    "function burnBps() view returns (uint256)",
    "function burnEth() view returns (uint256)",
    "function totalBurned() view returns (uint256)",
    "function ponsCurve() view returns (address)",
    "event RoundSettled(uint256 indexed round, uint8 winner, uint256 total, uint256 winnersStake, uint256 prize, uint256 cut)",
    ...["NotOwner", "NotKeeper", "Reentrancy", "Paused", "BadMask", "BadAmount", "BadParam", "RoundNotOver", "RoundEmpty",
      "RoundNotOpen", "RoundNotClosed", "RoundNotSettled", "TargetNotReached", "TargetStillValid", "TargetExpired",
      "StockNotAllowed", "NothingToDistribute", "TokenAlreadySet", "TokenNotSet", "StakeLocked", "TransferFailed"].map((n) => `error ${n}()`),
    "event EpochClosed(uint256 indexed epoch, address indexed stock, uint256 ethSpent, uint256 bought, uint256 toMiners, uint256 toStakers)",
    "event BurnFunded(uint256 indexed epoch, uint256 eth)",
    "event BoughtBackAndBurned(uint256 ethSpent, uint256 tokensBurned, bool onCurve)",
  ]);
  const erc20 = parseAbi([
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
  ]);

  const chain = defineChain({
    id: CONFIG.CHAIN_ID,
    name: CONFIG.CHAIN_NAME,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [CONFIG.RPC] } },
    blockExplorers: { default: { name: "Blockscout", url: CONFIG.EXPLORER } },
  });
  const address = CONFIG.CONTRACT;
  // blocks are ~0.1 s and a draw stays readable for ~25 s: poll receipts fast
  const pub = createPublicClient({ chain, pollingInterval: 500, transport: http(CONFIG.RPC, { batch: true }) });

  const revertName = (err) => err?.walk?.((e) => e?.name === "ContractFunctionRevertedError")?.data?.errorName ?? null;
  const FRIENDLY = {
    Paused: "new deployments are paused right now.",
    BadAmount: "that amount is not valid.",
    BadMask: "pick at least one square.",
    RoundNotOver: "the round is still open.",
    RoundEmpty: "that round has no ETH in it.",
    TargetNotReached: "the draw block has not arrived yet, try again in a second.",
    TargetStillValid: "the draw is already scheduled, try again in a second.",
    TargetExpired: "the draw window expired, the round has to be closed again.",
    StakeLocked: "your stake is still locked.",
    TokenNotSet: "the token is not live yet.",
    TransferFailed: "a transfer failed, nothing was moved.",
  };
  const explain = (err) => FRIENDLY[revertName(err)] || err?.shortMessage || err?.message || "failed";
  const read = (functionName, args = []) => pub.readContract({ address, abi, functionName, args });

  ui.tag.textContent = "LIVE";
  ui.tag.classList.add("live");
  ui.actions.hidden = false;
  const link = $("contract-link");
  link.href = `${CONFIG.EXPLORER}/address/${address}`;
  link.hidden = false;

  const [genesis, duration, minPerSquare, cutBps, token, unstakeDelay, minersBps, burnBps] = await Promise.all([
    read("genesis"), read("roundDuration"), read("minPerSquare"), read("cutBps"), read("token"), read("unstakeDelay"), read("minersShareBps"), read("burnBps"),
  ]);
  view.duration = Number(duration);
  $("fact-round").textContent = `${view.duration} s`;
  $("fact-cut").textContent = `${Number(cutBps) / 100} %`;
  $("stat-cut").textContent = `${Number(cutBps) / 100}%`;
  $("tile-cut").textContent = `${Number(cutBps) / 100} %`;
  // the burn slice comes off the pot first, the rest is split between miners and stakers
  const hasCurve = !/^0x0{40}$/.test(await read("ponsCurve"));
  const burnPct = hasCurve ? Number(burnBps) / 100 : 0;
  const pct = (n) => String(Math.round(n * 10) / 10);
  const minersPct = ((100 - burnPct) * Number(minersBps)) / 10000;
  const stakersPct = 100 - burnPct - minersPct;
  $("stat-split").textContent = `${pct(minersPct)} / ${pct(stakersPct)} / ${pct(burnPct)}`;
  $("split-miners").textContent = `${pct(minersPct)} %`;
  $("split-stakers").textContent = `${pct(stakersPct)} %`;
  // before the token is bound nothing is set aside: say so instead of showing a slice that is not taken yet
  $("split-burn").textContent = hasCurve ? `${pct(burnPct)} %` : `0 % now · ${pct(Number(burnBps) / 100)} % once the token is live`;
  $("stake-share-of-pot").textContent = `${pct(stakersPct)} %`;
  async function refreshBurn() {
    if (!hasCurve) return;
    const [burned, waiting] = await Promise.all([read("totalBurned"), read("burnEth")]);
    $("burn-stats").textContent = `Burned so far: ${fmtTok(burned)} tokens · waiting for the next buyback: ${fmt(waiting)} ETH`;
  }
  ui.stakeDelay.textContent = timeLeft(Number(unstakeDelay)).replace(/^in /, "") || "0s";
  const hasToken = !/^0x0{40}$/.test(token);
  if (hasToken) {
    $("token-address").textContent = `token: ${token}`;
    $("token-title").textContent = "Token: live";
    $("token-note").textContent = "Fixed supply, launched on Pons. Stake it above to earn a share of every stock purchase. The only real token is the address printed below: check it before you buy.";
  }

  let account = null;
  let wallet = null;
  let reveal = null; // { round, until } while a finished round stays on screen
  let claimRounds = [];
  let claimEpochs = [];
  let pendingRound = null; // oldest round with ETH in it that nobody has drawn yet
  const seenSettled = new Set();
  const WINDOW = 40;

  // rounds this wallet played, kept in the browser so old winnings stay claimable from here
  const storeKey = () => `stockmine:${address.toLowerCase()}:${account.toLowerCase()}`;
  function playedRounds() {
    try { return JSON.parse(localStorage.getItem(storeKey()) || "[]").filter(Number.isInteger); } catch { return []; }
  }
  function savePlayed(ids) {
    try { localStorage.setItem(storeKey(), JSON.stringify([...new Set(ids)].slice(-500))); } catch { /* private mode */ }
  }

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

  async function refreshPending() {
    const current = roundNow();
    const ids = [];
    for (let r = Math.max(0, current - WINDOW); r < current; r++) ids.push(r);
    const states = await Promise.all(ids.map((r) => read("rounds", [BigInt(r)])));
    const waiting = ids.filter((_, i) => states[i][0] !== 2 && states[i][4] > 0n);
    pendingRound = waiting.length ? waiting[0] : null;
    ui.draw.hidden = pendingRound === null;
    if (pendingRound !== null) ui.draw.textContent = waiting.length > 1 ? `Draw round #${pendingRound} (${waiting.length} waiting)` : `Draw round #${pendingRound}`;
  }

  async function refreshClaims() {
    if (!account) return;
    const current = roundNow();
    const recent = [];
    for (let r = current - 1; r >= 0 && r >= current - WINDOW; r--) recent.push(r);
    const ids = [...new Set([...recent, ...playedRounds().filter((r) => r < current)])];
    const [owed, states] = await Promise.all([
      Promise.all(ids.map((r) => read("claimable", [BigInt(r), account]))),
      Promise.all(ids.map((r) => read("rounds", [BigInt(r)]))),
    ]);
    // at most 50 rounds per transaction; the rest shows up again after this claim
    claimRounds = ids.filter((_, i) => owed[i] > 0n).slice(0, 50);
    const totalOwed = ids.reduce((sum, r, i) => (claimRounds.includes(r) ? sum + owed[i] : sum), 0n);
    ui.claim.hidden = claimRounds.length === 0;
    ui.claim.textContent = `Claim ${fmt(totalOwed, 4)} ETH`;
    // forget played rounds that are settled with nothing left to collect
    savePlayed(playedRounds().filter((r) => { const i = ids.indexOf(r); return i === -1 || states[i][0] !== 2 || owed[i] > 0n; }));

    const epochs = [];
    for (let e = view.epoch - 1; e >= 0 && e > view.epoch - 61; e--) epochs.push(e);
    const stock = await Promise.all(epochs.map((e) => read("claimableStock", [BigInt(e), account])));
    claimEpochs = epochs.filter((_, i) => stock[i][1] > 0n);
    ui.claimStock.hidden = claimEpochs.length === 0;
    if (claimEpochs.length) {
      const names = [...new Set(stock.filter((s) => s[1] > 0n).map((s) => CONFIG.STOCKS[s[0].toLowerCase()] || short(s[0])))];
      ui.claimStock.textContent = "Claim stocks";
      ui.claimStock.title = names.join(", ");
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
      refreshVault().catch(() => {});
    } catch (err) {
      say(err?.shortMessage || err?.message || "Wallet connection refused.", "err");
    }
  }

  /** Simulate, send and wait. `target` defaults to the game contract; `tell` is the status line to write to. */
  async function send(label, functionName, args, { value, target = { address, abi }, tell = say } = {}) {
    if (!wallet) {
      await connect();
      if (!wallet) return null;
    }
    try {
      tell(`${label}: confirm in your wallet…`);
      const { request } = await pub.simulateContract({ ...target, functionName, args, value, account });
      const hash = await wallet.writeContract(request);
      tell(`${label}: waiting for the chain…`);
      const receipt = await pub.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("transaction reverted");
      tell(`${label}: done.`, "ok");
      return receipt;
    } catch (err) {
      tell(`${label}: ${explain(err)}`, "err");
      return null;
    }
  }

  ui.connect.addEventListener("click", connect);
  window.ethereum?.on?.("accountsChanged", (accounts) => {
    if (account && (accounts[0] || "").toLowerCase() !== account.toLowerCase()) location.reload();
  });

  let deploying = false;
  onDeploy = async () => {
    if (deploying) return;
    const total = toWei(ui.amount.value);
    const count = BigInt(view.picked.size);
    if (count === 0n) return;
    if (total / count < minPerSquare) return say(`At least ${fmt(minPerSquare, 4)} ETH per square.`, "err");
    let mask = 0;
    for (const i of view.picked) mask |= 1 << i;
    deploying = true;
    ui.deploy.dataset.busy = "1";
    paint();
    try {
      const before = roundNow();
      const ok = await send("Deploy", "deploy", [mask >>> 0], { value: total });
      if (ok) {
        // the transaction landed in one of these two rounds; both are harmless to remember
        savePlayed([...playedRounds(), before, roundNow()]);
        view.picked.clear();
        refresh();
      }
    } finally {
      deploying = false;
      delete ui.deploy.dataset.busy;
      paint();
    }
  };

  guard(ui.draw, say, async () => {
    if (pendingRound === null) return;
    const id = BigInt(pendingRound);
    const round = await read("rounds", [id]);
    if (round[0] === 2) return refreshPending();
    let needsClose = round[0] === 0;
    if (!needsClose) {
      // closed already: settle if the target block is still readable, otherwise close again
      try {
        await pub.simulateContract({ address, abi, functionName: "settle", args: [id], account: account ?? undefined });
      } catch (err) {
        const name = revertName(err);
        needsClose = name === "TargetExpired";
        if (!needsClose && name !== "TargetNotReached") return say(`Draw: ${explain(err)}`, "err");
      }
    }
    if (needsClose && !(await send(`Close round #${id}`, "close", [id]))) return;
    await new Promise((r) => setTimeout(r, 1500));
    await send(`Draw round #${id}`, "settle", [id]);
    await Promise.all([refresh(), refreshPending(), refreshClaims()]);
  });

  guard(ui.claim, say, async () => {
    if (await send("Claim", "claim", [claimRounds.map(BigInt)])) await refreshClaims();
  });
  guard(ui.claimStock, say, async () => {
    if (await send("Claim stocks", "claimStock", [claimEpochs.map(BigInt)])) await refreshClaims();
  });

  // ---------------------------------------------------------------- vault

  const tokenTarget = { address: token, abi: erc20 };
  ui.stakeTag.textContent = hasToken ? "LIVE" : "OPENS AT TOKEN LAUNCH";
  ui.stakeTag.classList.toggle("live", hasToken);
  vault.enabled = hasToken;
  if (!hasToken) sayStake("Staking opens once the token is launched and bound to the contract.");
  else {
    const [symbol, decimals] = await Promise.all([
      pub.readContract({ ...tokenTarget, functionName: "symbol" }).catch(() => "tokens"),
      pub.readContract({ ...tokenTarget, functionName: "decimals" }).catch(() => 18),
    ]);
    vault.symbol = String(symbol).replace(/[^\x21-\x7e]/g, "").slice(0, 12) || "tokens";
    if (Number(decimals) !== 18) {
      vault.enabled = false;
      sayStake("This token does not use 18 decimals: staking from this page is disabled.", "err");
    } else sayStake("Connect your wallet to stake.");
  }

  async function refreshVault() {
    vault.total = await read("totalStaked");
    if (account && hasToken) {
      const [mine, at, balance, pending] = await Promise.all([
        read("staked", [account]),
        read("stakedAt", [account]),
        pub.readContract({ ...tokenTarget, functionName: "balanceOf", args: [account] }),
        read("pendingStaking", [account]),
      ]);
      vault.mine = mine;
      vault.unlockAt = Number(at) + Number(unstakeDelay);
      vault.balance = balance;
      const [list, amounts] = pending;
      vault.earned = list.map((stock, i) => ({ symbol: CONFIG.STOCKS[stock.toLowerCase()] || short(stock), amount: amounts[i] }));
    }
    paintVault();
  }

  const tellStake = { tell: sayStake };
  guard(ui.stakeBtn, sayStake, async () => {
    const amount = toWei(ui.stakeAmount.value);
    if (amount === 0n) return sayStake("Type a valid amount (use a dot for decimals).", "err");
    if (!account) {
      await connect();
      if (!account) return;
      await refreshVault();
    }
    if (amount > vault.balance) return sayStake("That is more than your wallet balance.", "err");
    const allowance = await pub.readContract({ ...tokenTarget, functionName: "allowance", args: [account, address] });
    if (allowance < amount && !(await send("Approve", "approve", [address, amount], { target: tokenTarget, ...tellStake }))) return;
    if (await send(`Stake ${fmtTok(amount)}`, "stake", [amount], tellStake)) {
      ui.stakeAmount.value = "";
      await refreshVault();
    }
  });
  guard(ui.unstakeBtn, sayStake, async () => {
    const amount = unstakeAmount();
    if (amount === null) return;
    const left = vault.unlockAt - Date.now() / 1000;
    if (left > 0) return sayStake(`Still locked: unlocks ${timeLeft(left)}.`, "err");
    if (await send(`Unstake ${fmtTok(amount)}`, "unstake", [amount], tellStake)) {
      ui.stakeAmount.value = "";
      await refreshVault();
    }
  });
  guard(ui.stakeClaim, sayStake, async () => {
    if (await send("Claim shares", "claimStaking", [], tellStake)) await refreshVault();
  });

  pub.watchContractEvent({
    address, abi, eventName: "EpochClosed", pollingInterval: 8000,
    onLogs: (logs) => {
      logs.forEach((l) => log(`<b>epoch ${l.args.epoch}</b> ${fmt(l.args.ethSpent)} ETH spent on <span>${CONFIG.STOCKS[l.args.stock.toLowerCase()] || short(l.args.stock)}</span>`));
      refreshVault().catch(() => {});
    },
  });
  pub.watchContractEvent({
    address, abi, eventName: "BurnFunded", pollingInterval: 8000,
    onLogs: (logs) => {
      logs.forEach((l) => log(`<b>epoch ${l.args.epoch}</b> ${fmt(l.args.eth)} ETH set aside for <span>buyback and burn</span>`));
      refreshBurn().catch(() => {});
    },
  });
  pub.watchContractEvent({
    address, abi, eventName: "BoughtBackAndBurned", pollingInterval: 8000,
    onLogs: (logs) => {
      logs.forEach((l) => log(`<b>buyback</b> ${fmt(l.args.ethSpent)} ETH → <span>${fmtTok(l.args.tokensBurned)} tokens burned</span>`));
      refreshBurn().catch(() => {});
    },
  });

  say("Pick squares, set an amount, deploy.");
  setInterval(tickClock, 200);
  const loop = async () => {
    try { await refresh(); } catch { say("Cannot reach the chain right now, retrying…", "err"); }
    setTimeout(loop, 1500);
  };
  loop();
  refreshVault().catch(() => {});
  refreshPending().catch(() => {});
  refreshBurn().catch(() => {});
  setInterval(() => refreshPending().catch(() => {}), 5000);
  setInterval(() => refreshBurn().catch(() => {}), 20000);
  setInterval(() => refreshClaims().catch(() => {}), 10000);
  setInterval(() => refreshVault().catch(() => {}), 12000);
}

// ------------------------------------------------------------------ page chrome

// glass surfaces light up under the pointer
document.querySelectorAll(".panel, .vault").forEach((el) =>
  el.addEventListener("pointermove", (e) => {
    const box = el.getBoundingClientRect();
    el.style.setProperty("--mx", `${e.clientX - box.left}px`);
    el.style.setProperty("--my", `${e.clientY - box.top}px`);
  })
);

// cards rise into place the first time they scroll into view
const revealables = [...document.querySelectorAll(".reveal")];
if ("IntersectionObserver" in window) {
  // what is already on screen never hides; only then switch the hiding rule on
  revealables.forEach((el) => { if (el.getBoundingClientRect().top < innerHeight) el.classList.add("in"); });
  document.documentElement.classList.add("js");
  const seen = new IntersectionObserver(
    (entries) => entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("in");
      seen.unobserve(entry.target);
    }),
    { threshold: 0, rootMargin: "0px 0px -40px 0px" }
  );
  revealables.forEach((el) => {
    const siblings = [...el.parentElement.children].filter((c) => c.classList.contains("reveal"));
    el.style.setProperty("--d", `${siblings.indexOf(el) * 70}ms`);
    seen.observe(el);
  });
} else revealables.forEach((el) => el.classList.add("in"));

// ------------------------------------------------------------------ boot

$("repo-link").href = CONFIG.REPO;
paint();
paintVault();
if (/^0x[0-9a-fA-F]{40}$/.test(CONFIG.CONTRACT)) {
  startLive().catch((err) => {
    console.error(err);
    say("Could not load the live contract. Showing the page without data.", "err");
  });
} else {
  startSimulation();
}
