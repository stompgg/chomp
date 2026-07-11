// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {TARGET_BITS_SHIFT} from "../../src/Constants.sol";
import {IEngineHook} from "../../src/IEngineHook.sol";
import {IRuleset} from "../../src/IRuleset.sol";
import {Battle, BattleOffer} from "../../src/Structs.sol";
import {ITeamRegistry} from "../../src/game-layer/ITeamRegistry.sol";
import {BattleOfferLib} from "../../src/matchmaker/BattleOfferLib.sol";
import {IMatchmaker} from "../../src/matchmaker/IMatchmaker.sol";
import {SignedMatchmaker} from "../../src/matchmaker/SignedMatchmaker.sol";
import {IRandomnessOracle} from "../../src/rng/IRandomnessOracle.sol";
import {Vm} from "forge-std/Vm.sol";

// Shared 2-slot test plumbing — the executeWithSlotMoves wire layout, the default Battle
// shape, and BattleOffer signing. Free functions so any test base can import them.

Vm constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// Wire word per side: [m0 8 | e0 16 | m1 8 | e1 16 | salt 80] (128 bits — a staged turn's
/// pair shares one buffer slot). The salt param stays uint104 for call-site compatibility
/// and is masked to the 80-bit wire width here.
function sideWord(uint8 m0, uint16 e0, uint8 m1, uint16 e1, uint104 salt) pure returns (uint256) {
    return uint256(m0) | (uint256(e0) << 8) | (uint256(m1) << 24) | (uint256(e1) << 32)
        | ((uint256(salt) & ((uint256(1) << 80) - 1)) << 48);
}

/// extraData target nibble: one bit per absolute slot.
function targetBits(uint256 absSlot) pure returns (uint16) {
    return uint16(uint256(1) << (TARGET_BITS_SHIFT + absSlot));
}

/// A 2-seat Battle with the test defaults (no oracle/ruleset/hooks, empty Multi seats);
/// callers overwrite the fields they vary.
function defaultBattle(address p0, address p1, ITeamRegistry registry, address moveManager, IMatchmaker matchmaker)
    pure
    returns (Battle memory)
{
    return Battle({
        p0: p0,
        p0TeamIndex: 0,
        p1: p1,
        p1TeamIndex: 0,
        p2: address(0),
        p2TeamIndex: 0,
        p3: address(0),
        p3TeamIndex: 0,
        teamRegistry: registry,
        rngOracle: IRandomnessOracle(address(0)),
        ruleset: IRuleset(address(0)),
        moveManager: moveManager,
        matchmaker: matchmaker,
        engineHooks: new IEngineHook[](0)
    });
}

/// Signs the offer form with `openSeatsMask` seats blinded (the shared open digest).
function signOffer(SignedMatchmaker matchmaker, uint256 pk, BattleOffer memory offer, uint8 openSeatsMask)
    view
    returns (bytes memory)
{
    bytes32 digest = matchmaker.hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, openSeatsMask));
    (uint8 v, bytes32 r, bytes32 s) = _VM.sign(pk, digest);
    return abi.encodePacked(r, s, v);
}

/// Signs a joiner's SeatFill over the open digest for canonical seat `seatIndex`.
function signSeatFill(
    SignedMatchmaker matchmaker,
    uint256 pk,
    BattleOffer memory offer,
    uint8 openSeatsMask,
    uint8 seatIndex
) view returns (bytes memory) {
    bytes32 openDigest = matchmaker.hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, openSeatsMask));
    bytes32 digest = matchmaker.hashTypedData(BattleOfferLib.hashSeatFill(openDigest, seatIndex));
    (uint8 v, bytes32 r, bytes32 s) = _VM.sign(pk, digest);
    return abi.encodePacked(r, s, v);
}
