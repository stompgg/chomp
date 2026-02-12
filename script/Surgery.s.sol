// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {IEngine} from "../src/IEngine.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract Surgery is Script {
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        SignedCommitManager m = new SignedCommitManager(IEngine(0x4F198ba502572c3C8d43c246E610d2B64b089fA1));
        deployedContracts.push(DeployData({name: "SIGNED COMMIT MANAGER", contractAddress: address(m)}));

        vm.stopBroadcast();
        return deployedContracts;
    }
}
