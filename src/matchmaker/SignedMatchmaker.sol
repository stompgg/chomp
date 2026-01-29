// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {BattleOffer} from "../Structs.sol";
import {IMatchmaker} from "./IMatchmaker.sol";
import {BattleOfferLib} from "./BattleOfferLib.sol";
import {EIP712} from "../lib/EIP712.sol";
import {ECDSA} from "../lib/ECDSA.sol";

contract SignedMatchmaker is IMatchmaker, EIP712 {

    IEngine public immutable ENGINE;

    error NotP1();
    error InvalidSignature();
    error InvalidNonce();

    constructor(IEngine engine) {
        ENGINE = engine;
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedMatchmaker";
        version = "1";
    }

    /// @notice Computes the EIP-712 digest for a struct hash
    /// @dev Exposed publicly so tests and clients can compute the same digest
    function hashTypedData(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedData(structHash);
    }

    /*
        A signs proposed battle (with pair hash nonce), sends to B, assuming default team index (0) for B.
        B signs proposed battle with actual team index (with same pair hash nonce), submits to SignedMatchmaker along with A's signature.
        Battle starts, SignedMatchmaker validates the signatures, validates pair hash nonce
    */
    function startGame(BattleOffer memory offer, bytes memory p0Signature) external {
        uint96 actualP1TeamIndex = offer.battle.p1TeamIndex;

        // Set to 0 (assume p0 signs with default team index of 0)
        offer.battle.p1TeamIndex = 0;

        // Validate that caller is p1
        if (msg.sender != offer.battle.p1) {
            revert NotP1();
        }

        // Validate that the pair hash nonce is correct
        (, bytes32 pairHash) = ENGINE.computeBattleKey(offer.battle.p0, offer.battle.p1);
        if (ENGINE.pairHashNonces(pairHash) != offer.pairHashNonce) {
            revert InvalidNonce();
        }

        // Validate that p0's signature is valid
        bytes32 structHash = BattleOfferLib.hashBattleOffer(offer);
        bytes32 digest = _hashTypedData(structHash);
        address signer = ECDSA.recover(digest, p0Signature);
        if (signer != offer.battle.p0) {
            revert InvalidSignature();
        }

        // Start the battle via the engine
        offer.battle.p1TeamIndex = actualP1TeamIndex;
        ENGINE.startBattle(offer.battle);
    }

    function validateMatch(bytes32, address) external pure returns (bool) {
        return true;
    }
}