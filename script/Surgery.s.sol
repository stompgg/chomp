// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {IEngine} from "../src/IEngine.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";
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

        BetterCPU cpu = new BetterCPU(4, IEngine(0xaE14d4eFD7F30AFA679CD7e971f7b6CE9C445329), ICPURNG(address(0)), ITypeCalculator(0x65BcF9e5a0A6adedB6BA71b86eb255E9e9aF65dF));
        deployedContracts.push(DeployData({name: "Better CPU", contractAddress: address(cpu)}));

        vm.stopBroadcast();
        return deployedContracts;
    }
}
