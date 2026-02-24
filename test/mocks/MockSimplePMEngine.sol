// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

contract MockSimplePMEngine {
    mapping(bytes32 => uint256) public turnIds;
    mapping(bytes32 => address) public winners;
    mapping(bytes32 => address[]) public playersList;
    mapping(bytes32 => uint256) public startTimestamps;

    function setTurnId(bytes32 battleKey, uint256 turnId) external {
        turnIds[battleKey] = turnId;
    }

    function setWinner(bytes32 battleKey, address winner) external {
        winners[battleKey] = winner;
    }

    function setPlayers(bytes32 battleKey, address p0, address p1) external {
        playersList[battleKey] = new address[](2);
        playersList[battleKey][0] = p0;
        playersList[battleKey][1] = p1;
    }

    function setStartTimestamp(bytes32 battleKey, uint256 timestamp) external {
        startTimestamps[battleKey] = timestamp;
    }

    function getTurnIdForBattleState(bytes32 battleKey) external view returns (uint256) {
        return turnIds[battleKey];
    }

    function getWinner(bytes32 battleKey) external view returns (address) {
        return winners[battleKey];
    }

    function getPlayersForBattle(bytes32 battleKey) external view returns (address[] memory) {
        return playersList[battleKey];
    }

    function getStartTimestamp(bytes32 battleKey) external view returns (uint256) {
        return startTimestamps[battleKey];
    }
}
