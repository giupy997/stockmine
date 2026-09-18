// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StockMine} from "../src/StockMine.sol";

/// @dev PRIVATE_KEY comes from the environment, never from a file or the chat.
///      forge script script/Deploy.s.sol --rpc-url robinhood --broadcast
contract Deploy is Script {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant PONS_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    function run() external {
        uint256 roundDuration = vm.envOr("ROUND_DURATION", uint256(60));
        uint256 minPerSquare = vm.envOr("MIN_PER_SQUARE", uint256(0.0001 ether));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        StockMine game = new StockMine(roundDuration, minPerSquare, WETH, ROUTER, PONS_ESCROW, PONS_FACTORY);
        game.setStock(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, true); // NVDA
        game.setStock(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, true); // TSLA
        game.setStock(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, true); // SPY
        game.setStock(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, true); // AAPL
        vm.stopBroadcast();

        console2.log("StockMine:", address(game));
        console2.log("Use this address as creatorFeeRecipient in the Pons launch, then call setToken(token).");
    }
}
