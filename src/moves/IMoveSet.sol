// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../IEngine.sol";
import "../Structs.sol";

interface IMoveSet {
    function name() external view returns (string memory);
    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderMonIndex,
        uint16 extraData,
        uint256 rng
    ) external;
    function priority(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex) external view returns (uint32);
    function stamina(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 monIndex)
        external
        view
        returns (uint32);
    function moveType(IEngine engine, bytes32 battleKey) external view returns (Type);
    function isValidTarget(IEngine engine, bytes32 battleKey, uint16 extraData) external view returns (bool);
    function moveClass(IEngine engine, bytes32 battleKey) external view returns (MoveClass);
    function extraDataType() external view returns (ExtraDataType);

    /// @notice Bundled metadata read. Returns moveType / moveClass / priority / stamina /
    ///         basePower / extraDataType in a single staticcall so callers that need several
    ///         metadata fields per decision avoid N separate external calls.
    /// @dev For moves that don't deal damage, return `basePower == 0`. Implementations that
    ///      don't read engine/battleKey/playerIndex/monIndex may ignore those parameters; they
    ///      are passed through so dynamic-metadata moves (e.g., basePower that depends on
    ///      battle state) can use them.
    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory);
}
