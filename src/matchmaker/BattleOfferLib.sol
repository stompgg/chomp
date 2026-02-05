// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Battle, BattleOffer} from "../Structs.sol";

/// @notice Library for hashing Battle and BattleOffer structs according to EIP-712
library BattleOfferLib {
    // Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address teamRegistry,address validator,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant BATTLE_TYPEHASH = 0x67b719ddf5bc2f9339bff0bf873e815c9aa3fa902552552152af65fb2f065a44;
    // BattleOffer(Battle battle,uint256 pairHashNonce)Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address teamRegistry,address validator,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant BATTLE_OFFER_TYPEHASH = 0xaec0ec193a3a179409bec797fb74abf352da6595e663719692c868673b4d806b;

    // OpenBattleOffer(Battle battle,uint256 nonce)Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address teamRegistry,address validator,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant OPEN_BATTLE_OFFER_TYPEHASH = 0xd4d9579b6cdb437b6d1415a71957f5b7aa4bf4ebce922ecee51e870b973d80fd;

    /// @dev Hashes a Battle struct according to EIP-712
    function hashBattle(Battle memory battle) internal pure returns (bytes32) {
        // Convert IEngineHook[] to address[] for hashing
        address[] memory hookAddresses = new address[](battle.engineHooks.length);
        for (uint256 i = 0; i < battle.engineHooks.length; i++) {
            hookAddresses[i] = address(battle.engineHooks[i]);
        }

        return keccak256(abi.encode(
            BATTLE_TYPEHASH,
            battle.p0,
            battle.p0TeamIndex,
            battle.p1,
            battle.p1TeamIndex,
            address(battle.teamRegistry),
            address(battle.validator),
            address(battle.rngOracle),
            address(battle.ruleset),
            battle.moveManager,
            address(battle.matchmaker),
            keccak256(abi.encodePacked(hookAddresses))
        ));
    }

    /// @dev Hashes a BattleOffer struct according to EIP-712
    function hashBattleOffer(BattleOffer memory offer) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            BATTLE_OFFER_TYPEHASH,
            hashBattle(offer.battle),
            offer.pairHashNonce
        ));
    }
}

