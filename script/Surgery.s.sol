// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {IEngine} from "../src/IEngine.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";
import {ICPURNG} from "../src/rng/ICPURNG.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract Surgery is Script {
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        // Whitelist okay/better cpu
        // Do this automatically in the future for SetupCPU

        return deployedContracts;
    }
}
