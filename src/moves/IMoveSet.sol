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
        uint240 extraData,
        uint256 rng
    ) external;
    function priority(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex) external view returns (uint32);
    function stamina(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 monIndex)
        external
        view
        returns (uint32);
    function moveType(IEngine engine, bytes32 battleKey) external view returns (Type);
    function isValidTarget(IEngine engine, bytes32 battleKey, uint240 extraData) external view returns (bool);
    function moveClass(IEngine engine, bytes32 battleKey) external view returns (MoveClass);
    function extraDataType() external view returns (ExtraDataType);
}
