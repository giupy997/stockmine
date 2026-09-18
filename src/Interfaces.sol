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

interface IPonsFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}
