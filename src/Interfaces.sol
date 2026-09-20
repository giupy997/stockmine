// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Arbitrum Nitro precompile at address(100). On Robinhood Chain `block.number` is an L1 estimate and
///      `blockhash` follows it, so L2 block numbers and hashes have to come from here.
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 blockNumber) external view returns (bytes32);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Uniswap SwapRouter02 (no deadline in the params). Sending ETH as value wraps it when tokenIn is WETH.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev Pons v2 fee escrow: creator fees of ETH-paired launches accrue here and are pulled by the recipient.
interface IPonsEscrow {
    function balanceOf(address account) external view returns (uint256);
    function claim() external;
}

/// @dev `getLaunchedToken(address)` is read with a raw call in StockMine: only the head of its record is
///      needed (token, curve, deployer, fee recipient, pair token, threshold, pool fee, tick spacing, ...).
interface IPonsFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    /// @dev Open to anyone once a curve has sold out: creates the Uniswap v4 pool if the automatic step failed.
    function createGraduatedPool(address token) external;
}

/// @dev Pons v2 bonding curve of one launch. Buys are paid in ETH until the launch graduates.
interface IPonsCurve {
    function buy(uint256 amountIn, uint256 minAmountOut, address to) external payable returns (uint256);
    function token() external view returns (address);
    function graduated() external view returns (bool);
}

/// @dev Pons router for graduated launches (Uniswap v4 pool behind the Pons hook). ETH is address(0); with
///      recipient address(0) the output goes to the caller.
interface IPonsRouter {
    struct Step {
        uint8 kind;
        address tokenIn;
        address tokenOut;
        address pool;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
        address manager;
        bytes32 poolId;
    }

    function swap(Step[] calldata steps, address recipient, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        payable;
}
