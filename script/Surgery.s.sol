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

        OkayCPU cpu2 = new OkayCPU(4, IEngine(0x0db7f5f66fFFCA63Ef92D7A57Ad84bbdAf646b70), ICPURNG(address(0)), ITypeCalculator(0xbe585139aB24aE96794f65a33205EE931fbb6A42));

        BetterCPU cpu = new BetterCPU(4, IEngine(0x0db7f5f66fFFCA63Ef92D7A57Ad84bbdAf646b70), ICPURNG(address(0)), ITypeCalculator(0xbe585139aB24aE96794f65a33205EE931fbb6A42));
        deployedContracts.push(DeployData({name: "Better CPU", contractAddress: address(cpu)}));

        vm.stopBroadcast();
        return deployedContracts;
    }
}
