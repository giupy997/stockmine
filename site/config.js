// Fill CONTRACT once StockMine is deployed: the page then leaves the simulation and reads the chain.
export const CONFIG = {
  CONTRACT: "",
  CHAIN_ID: 4663,
  CHAIN_NAME: "Robinhood Chain",
  RPC: "https://rpc.mainnet.chain.robinhood.com",
  EXPLORER: "https://robinhoodchain.blockscout.com",
  REPO: "https://github.com/giupy997/stockmine",
  STOCKS: {
    "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec": "NVDA",
    "0x322f0929c4625ed5bad873c95208d54e1c003b2d": "TSLA",
    "0x117cc2133c37b721f49de2a7a74833232b3b4c0c": "SPY",
    "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9": "AAPL",
  },
};
