// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {IEngine} from "../src/IEngine.sol";
// import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
// import {OkayCPU} from "../src/cpu/OkayCPU.sol";
// import {ICPURNG} from "../src/rng/ICPURNG.sol";

import {Multicall3} from "../src/lib/Multicall3.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract Surgery is Script {
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        DefaultMatchmaker m = new DefaultMatchmaker(IEngine(0x4F198ba502572c3C8d43c246E610d2B64b089fA1));
        deployedContracts.push(DeployData({name: "DEFAULT MATCHMAKER", contractAddress: address(m)}));

        vm.stopBroadcast();
        return deployedContracts;
    }
}
