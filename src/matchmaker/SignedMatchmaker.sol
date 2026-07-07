// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {BATTLE_MODE_MULTI} from "../Constants.sol";
import {IEngine} from "../IEngine.sol";
import {BattleOffer} from "../Structs.sol";
import {ECDSA} from "../lib/ECDSA.sol";
import {EIP712} from "../lib/EIP712.sol";
import {BattleOfferLib} from "./BattleOfferLib.sol";
import {IMatchmaker} from "./IMatchmaker.sol";

/// @notice Signed matchmaking for singles, doubles, and multi.
///
/// Consent (D32): each occupied seat must either sign or be msg.sender; CPU seats (the
/// registry's whitelisted-opponent flag, D19) are exempt — every human signature covers the
/// full seating including them. Team indices are never signed (D31): the submitter supplies
/// all of them. Open seats (D20): the creator signs with those seats as address(0); a joiner
/// either calls startGame themselves or signs a SeatFill over the open digest. Nonces: open
/// offers consume the creator's sequential openBattleOfferNonce (one live open offer per
/// creator, D35); fully-named offers pin the engine's pair/party nonce.
contract SignedMatchmaker is IMatchmaker, EIP712 {
    IEngine public immutable ENGINE;
    mapping(address => uint256) public openBattleOfferNonce;

    error InvalidSignature();
    error InvalidNonce();
    error InvalidOpenBattleOfferNonce();
    error MissingConsent();
    error CreatorSeatCannotBeOpen();

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
    ///        address(0) in the signed form; bit 0 (the creator) may not be open.
    /// @param seatSigs Per-seat signatures in canonical order; empty for msg.sender and CPU
    ///        seats. Open-marked seats sign a SeatFill over the open digest; named seats sign
    ///        the open digest itself.
    function startGame(BattleOffer memory offer, uint8 openSeatsMask, bytes[4] calldata seatSigs) external {
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
                continue; // CPU seat: consent embedded in every human signature (D19)
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

        ENGINE.startBattleWithMode(offer.battle, offer.battleMode);
    }
}
