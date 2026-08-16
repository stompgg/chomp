// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveMeta} from "../../Structs.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

/// @notice Sheds half of Glob's current HP to bless itself. Free the first time, then a stamina
///         costlier on each subsequent cast until it caps.
contract HolyMolt is IMoveSet {
    int32 public constant HP_DENOM = 2;
    uint32 public constant MAX_STAMINA_COST = 3;

    IEffect immutable BLESSED_STATUS;

    constructor(IEffect _BLESSED_STATUS) {
        BLESSED_STATUS = _BLESSED_STATUS;
    }

    function _moltKey(uint256 playerIndex, uint256 monIndex) internal view returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, address(this)))));
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint256,
        uint16,
        uint256
    ) external {
        // HP loss, not damage: routing through dealDamage would let the blessing this very move
        // applies absorb its own cost.
        int32 currentHp =
            engine.getMonCurrentValue(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp, -(currentHp / HP_DENOM));
        engine.addEffect(attackerPlayerIndex, attackerMonIndex, BLESSED_STATUS, bytes32(0));

        uint64 moltKey = _moltKey(attackerPlayerIndex, attackerMonIndex);
        uint256 casts = uint256(engine.getGlobalKV(battleKey, moltKey));
        if (casts < MAX_STAMINA_COST) {
            engine.setGlobalKV(moltKey, uint192(casts + 1));
        }
    }

    /// @dev Read before the engine deducts it, so it reflects the count from prior casts only.
    function stamina(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        public
        view
        returns (uint32)
    {
        return uint32(uint256(engine.getGlobalKV(battleKey, _moltKey(playerIndex, monIndex))));
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY + 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Faith;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
