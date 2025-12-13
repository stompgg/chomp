// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Structs.sol";

interface ICommitManager {
    function commitMove(bytes32 battleKey, bytes32 moveHash) external;
    function revealMove(bytes32 battleKey, uint8 moveIndex, bytes32 salt, uint240 extraData, bool autoExecute)
        external;
    function getCommitment(bytes32 battleKey, address player) external view returns (bytes32 moveHash, uint256 turnId);
    function getMoveCountForBattleState(bytes32 battleKey, address player) external view returns (uint256);
    function getLastMoveTimestampForPlayer(bytes32 battleKey, address player) external view returns (uint256);
}
