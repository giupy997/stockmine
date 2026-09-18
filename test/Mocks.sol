// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISwapRouter02} from "../src/Interfaces.sol";

/// @dev Stand-in for the Nitro precompile: same range rule as the real one (last 256 blocks, never the future).
contract MockArbSys {
    uint256 public number;

    error InvalidBlockNumber();

    function set(uint256 n) external {
        number = n;
    }

    function roll(uint256 by) external {
        number += by;
    }

    function arbBlockNumber() external view returns (uint256) {
        return number;
    }

    function arbBlockHash(uint256 b) external view returns (bytes32) {
        if (b >= number || b + 256 < number) revert InvalidBlockNumber();
        return keccak256(abi.encode("l2-block", b));
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Sells any MockERC20 at a fixed rate per ETH and honours the minimum out.
contract MockRouter {
    uint256 public rate = 10e18; // stock units per 1 ETH

    function setRate(uint256 r) external {
        rate = r;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(msg.value == p.amountIn, "value");
        out = (p.amountIn * rate) / 1e18;
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}

contract MockEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address account) external payable {
        balanceOf[account] += msg.value;
    }

    function claim() external {
        uint256 amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }
}

contract MockFactory {
    address public lastToken;
    address public lastRecipient;

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        lastToken = token;
        lastRecipient = newRecipient;
    }
}
