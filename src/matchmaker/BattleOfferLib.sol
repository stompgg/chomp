// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Battle, BattleOffer} from "../Structs.sol";

/// @notice EIP-712 hashing for battle offers. Signatures always cover the SIGNING FORM of an
///         offer: every team index blinded to 0 (D31 — the submitter supplies the real ones)
///         and open seats as address(0). Open-seat joiners sign a SeatFill over that digest.
library BattleOfferLib {
    // Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address p2,uint96 p2TeamIndex,address p3,uint96 p3TeamIndex,address teamRegistry,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant BATTLE_TYPEHASH = 0xdf0031fd9cbf0d756cd8f6b99864409022693748ce3c5f2b65124630ebcdf8a2;
    // BattleOffer(Battle battle,uint256 pairHashNonce,uint8 battleMode)Battle(address p0,uint96 p0TeamIndex,address p1,uint96 p1TeamIndex,address p2,uint96 p2TeamIndex,address p3,uint96 p3TeamIndex,address teamRegistry,address rngOracle,address ruleset,address moveManager,address matchmaker,address[] engineHooks)
    bytes32 public constant BATTLE_OFFER_TYPEHASH = 0x2b0b083ae850c27f3b772d2110980336a1eb2f3498090fabceeb92f429c1d2f9;
    // SeatFill(bytes32 offerDigest,uint8 seatIndex)
    bytes32 public constant SEAT_FILL_TYPEHASH = 0x89bafd036f6be8d20c1d689e07ddd24ce79caf6e2995ceccb4f272833776b1f5;

    /// @dev Canonical seat order [p0, p2, p1, p3] (side-major) — matches the engine's rotation.
    function seatAt(Battle memory battle, uint256 canonicalIndex) internal pure returns (address) {
        if (canonicalIndex == 0) return battle.p0;
        if (canonicalIndex == 1) return battle.p2;
        if (canonicalIndex == 2) return battle.p1;
        return battle.p3;
    }

    /// @dev Hashes the SIGNING FORM: team indices zeroed, seats marked open in
    ///      `openSeatsMask` (canonical-order bits) zeroed.
    function hashBattleOfferForSigning(BattleOffer memory offer, uint8 openSeatsMask) internal pure returns (bytes32) {
        Battle memory b = offer.battle;
        address[] memory hookAddresses = new address[](b.engineHooks.length);
        for (uint256 i = 0; i < b.engineHooks.length; i++) {
            hookAddresses[i] = address(b.engineHooks[i]);
        }
        bytes32 battleHash = keccak256(
            abi.encode(
                BATTLE_TYPEHASH,
                (openSeatsMask & 1) != 0 ? address(0) : b.p0,
                uint96(0),
                (openSeatsMask & 4) != 0 ? address(0) : b.p1,
                uint96(0),
                (openSeatsMask & 2) != 0 ? address(0) : b.p2,
                uint96(0),
                (openSeatsMask & 8) != 0 ? address(0) : b.p3,
                uint96(0),
                address(b.teamRegistry),
                address(b.rngOracle),
                address(b.ruleset),
                b.moveManager,
                address(b.matchmaker),
                keccak256(abi.encodePacked(hookAddresses))
            )
        );
        return keccak256(abi.encode(BATTLE_OFFER_TYPEHASH, battleHash, offer.pairHashNonce, offer.battleMode));
    }

    function hashSeatFill(bytes32 offerDigest, uint8 seatIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(SEAT_FILL_TYPEHASH, offerDigest, seatIndex));
    }
}
