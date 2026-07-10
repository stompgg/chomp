// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {BATTLE_MODE_MULTI} from "../Constants.sol";
import {IEngine} from "../IEngine.sol";
import {BattleOffer, SeatPhantomConfig} from "../Structs.sol";
import {IPhantomTeamRegistry} from "../game-layer/IPhantomTeamRegistry.sol";
import {ITeamRegistry} from "../game-layer/ITeamRegistry.sol";
import {ECDSA} from "../lib/ECDSA.sol";
import {EIP712} from "../lib/EIP712.sol";
import {BattleOfferLib} from "./BattleOfferLib.sol";
import {IMatchmaker} from "./IMatchmaker.sol";

/// @notice Signed matchmaking for singles, doubles, and multi.
contract SignedMatchmaker is IMatchmaker, EIP712 {
    IEngine public immutable ENGINE;
    mapping(address => uint256) public openBattleOfferNonce;

    error InvalidSignature();
    error InvalidNonce();
    error InvalidOpenBattleOfferNonce();
    error MissingConsent();
    error CreatorSeatCannotBeOpen();
    error InvalidOpenSeatsMask();

    constructor(IEngine engine) {
        ENGINE = engine;
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedMatchmaker";
        version = "1";
    }

    /// @notice Computes the EIP-712 digest for a struct hash (exposed for tests and clients).
    function hashTypedData(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedData(structHash);
    }

    /// @param openSeatsMask Canonical-order bits ([p0, p2, p1, p3]) marking seats that were
    ///        address(0) in the signed form; bit 0 (the creator) may not be open. The mask byte
    ///        is a signed field of the offer digest, so every signer consents to it as-is.
    /// @param seatSigs Per-seat signatures in canonical order; empty for msg.sender and CPU
    ///        seats. Open-marked seats sign a SeatFill over the open digest; named seats sign
    ///        the open digest itself.
    function startGame(BattleOffer memory offer, uint8 openSeatsMask, bytes[4] calldata seatSigs) external {
        _verifyOfferAndNonce(offer, openSeatsMask, seatSigs);
        ENGINE.startBattleWithMode(offer.battle, offer.battleMode);
    }

    /// @notice startGame variant that bundles CPU-seat phantom team-config writes with the start,
    /// so a mixed CPU-ally party (a CPU on a side that still has a human) can run on the built-in
    /// dual-signed rotation.
    function startGameWithSeatConfigs(
        BattleOffer memory offer,
        uint8 openSeatsMask,
        bytes[4] calldata seatSigs,
        SeatPhantomConfig[3] calldata seatConfigs
    ) external {
        _verifyOfferAndNonce(offer, openSeatsMask, seatSigs);
        // Safe to mutate team indices post-verify: the offer hash blinds every index to 0 (D31),
        // so no seat signature depends on them.
        ITeamRegistry registry = offer.battle.teamRegistry;
        address host = offer.battle.p0;
        offer.battle.p1TeamIndex = _configureSeat(registry, host, offer.battle.p1, seatConfigs[0], offer.battle.p1TeamIndex);
        offer.battle.p2TeamIndex = _configureSeat(registry, host, offer.battle.p2, seatConfigs[1], offer.battle.p2TeamIndex);
        offer.battle.p3TeamIndex = _configureSeat(registry, host, offer.battle.p3, seatConfigs[2], offer.battle.p3TeamIndex);
        ENGINE.startBattleWithMode(offer.battle, offer.battleMode);
    }

    /// @dev Verify seat consent (each occupied non-CPU seat signs or is msg.sender) and pin the
    ///      nonce (open-offer sequential nonce, else the engine's pair/party nonce). Mutates only
    ///      the creator's open-offer nonce; the caller performs the engine start.
    function _verifyOfferAndNonce(BattleOffer memory offer, uint8 openSeatsMask, bytes[4] calldata seatSigs) internal {
        // Only 4 seats exist; non-multi modes forbid p2/p3 (canonical bits 1/3), so opening them is meaningless.
        if (openSeatsMask >= 16 || (offer.battleMode != BATTLE_MODE_MULTI && openSeatsMask & 0xA != 0)) {
            revert InvalidOpenSeatsMask();
        }
        if (openSeatsMask & 1 != 0) {
            revert CreatorSeatCannotBeOpen();
        }
        bytes32 openDigest = _hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, openSeatsMask));

        for (uint256 i; i < 4; ++i) {
            address seat = BattleOfferLib.seatAt(offer.battle, i);
            if (seat == address(0)) {
                continue; // p2/p3 vacancy is validated against the mode by the engine
            }
            if (seat == msg.sender) {
                continue;
            }
            if (offer.battle.teamRegistry.isWhitelistedOpponent(seat)) {
                continue; // CPU seat: consent embedded in every human signature
            }
            bytes calldata sig = seatSigs[i];
            if (sig.length == 0) {
                revert MissingConsent();
            }
            bytes32 digest = (openSeatsMask & (1 << i)) != 0
                ? _hashTypedData(BattleOfferLib.hashSeatFill(openDigest, uint8(i)))
                : openDigest;
            if (ECDSA.recoverCalldata(digest, sig) != seat) {
                revert InvalidSignature();
            }
        }

        if (openSeatsMask != 0) {
            if (openBattleOfferNonce[offer.battle.p0] != offer.pairHashNonce) {
                revert InvalidOpenBattleOfferNonce();
            }
            openBattleOfferNonce[offer.battle.p0] += 1;
        } else {
            bytes32 partyOrPairHash;
            if (offer.battleMode == BATTLE_MODE_MULTI) {
                (, partyOrPairHash) =
                    ENGINE.computePartyKey(offer.battle.p0, offer.battle.p1, offer.battle.p2, offer.battle.p3);
            } else {
                (, partyOrPairHash) = ENGINE.computeBattleKey(offer.battle.p0, offer.battle.p1);
            }
            if (ENGINE.pairHashNonces(partyOrPairHash) != offer.pairHashNonce) {
                revert InvalidNonce();
            }
        }
    }

    /// @dev Human seats pass through untouched. A whitelisted (CPU) seat gets its phantom config
    ///      written for `user` via the peer relay entry (skipped when monIndices is empty) and its
    ///      team index forced to `user`'s phantom key. Mirrors CPU._configureSeat, but the
    ///      matchmaker only ever writes peer seats (it is never the opponent itself).
    function _configureSeat(
        ITeamRegistry registry,
        address user,
        address seat,
        SeatPhantomConfig calldata cfg,
        uint96 suppliedTeamIndex
    ) private returns (uint96) {
        if (!registry.isWhitelistedOpponent(seat)) {
            return suppliedTeamIndex;
        }
        if (cfg.monIndices.length != 0) {
            IPhantomTeamRegistry(address(registry)).setOpponentTeamForPeer(
                user, seat, cfg.monIndices, cfg.facetIds, cfg.moveSelections
            );
        }
        // The seat's phantom team is stored under (seat, uint16(user)); force its index to match.
        return uint96(uint16(uint160(user)));
    }
}
