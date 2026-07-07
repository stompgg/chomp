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
        SimplePM spm = new SimplePM(IEngine(0xcd424268aCF5547bE7799b92480C40C180a22799));
        deployedContracts.push(DeployData({
            name: "SPM",
            contractAddress: address(spm)
        }));
        return deployedContracts;
    }
}
