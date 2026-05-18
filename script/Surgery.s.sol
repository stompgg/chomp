// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {ReturnerGift} from "../src/game-layer/ReturnerGift.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract Surgery is Script {
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        ReturnerGift(0xb948153978F1f95c3481B189cb4656bDf756A247).setMerkleRoot(0x676c3dcca078e2a46cb67865fe30a3e807e4240312cbb923466334406b6e519d);

        return deployedContracts;
    }
}
