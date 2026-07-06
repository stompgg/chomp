// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Battle, BattleOffer} from "../Structs.sol";

/// @notice Library for hashing Battle and BattleOffer structs according to EIP-712
library BattleOfferLib {
    // Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address teamRegistry,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant BATTLE_TYPEHASH = 0x76af0d4843dc0428b9f95a0f9c9f771721b90b655d4f16e002d7baea7d5b0cf8;
    // BattleOffer(Battle battle,uint256 pairHashNonce,uint8 battleMode)Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address teamRegistry,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant BATTLE_OFFER_TYPEHASH = 0x172d152e200900b4d00f02e39b09bb0f665fb4dcc24af1741bbaa835f16d3f9d;

    /// @dev Hashes a Battle struct according to EIP-712
    function hashBattle(Battle memory battle) internal pure returns (bytes32) {
        // Convert IEngineHook[] to address[] for hashing
        address[] memory hookAddresses = new address[](battle.engineHooks.length);
        for (uint256 i = 0; i < battle.engineHooks.length; i++) {
            hookAddresses[i] = address(battle.engineHooks[i]);
        }

        return keccak256(
            abi.encode(
                BATTLE_TYPEHASH,
                battle.p0,
                battle.p0TeamIndex,
                battle.p1,
                battle.p1TeamIndex,
                address(battle.teamRegistry),
                address(battle.rngOracle),
                address(battle.ruleset),
                battle.moveManager,
                address(battle.matchmaker),
                keccak256(abi.encodePacked(hookAddresses))
            )
        );
    }

    /// @dev Hashes a BattleOffer struct according to EIP-712
    function hashBattleOffer(BattleOffer memory offer) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(BATTLE_OFFER_TYPEHASH, hashBattle(offer.battle), offer.pairHashNonce, offer.battleMode)
            );
    }
}

