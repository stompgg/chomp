// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

interface IEngineHook {
    // Returns pre-computed bitmap of steps this hook runs at (set at deploy time)
    // Bit layout: OnBattleStart=0x01, OnRoundStart=0x02, OnRoundEnd=0x04, OnBattleEnd=0x08
    function getStepsBitmap() external view returns (uint16);

    function onBattleStart(bytes32 battleKey) external;
    function onRoundStart(bytes32 battleKey) external;
    function onRoundEnd(bytes32 battleKey) external;
    function onBattleEnd(bytes32 battleKey) external;
}
