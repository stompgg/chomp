// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {SimplePM} from "../src/hooks/SimplePM.sol";
import {IEngine} from "../src/IEngine.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract Surgery is Script {
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();
        SimplePM spm = new SimplePM(IEngine(0x16650f8c5e8F0C488e8773f765f2946F08cF8b69));
        deployedContracts.push(DeployData({
            name: "SPM",
            contractAddress: address(spm)
        }));
        return deployedContracts;
    }
}
