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
    mapping(address => uint256) public openBattleOfferNonce;

    error NotP1();
    error InvalidSignature();
    error InvalidNonce();
    error InvalidOpenBattleOfferNonce();

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
        If p1 is set to address(0), anyone can fill, and we update the nonce
        B signs proposed battle with actual team index (with same pair hash nonce), submits to SignedMatchmaker along with A's signature.
        Battle starts, SignedMatchmaker validates the signatures, validates pair hash nonce
    */
    function startGame(BattleOffer memory offer, bytes memory p0Signature) external {
        uint96 actualP1TeamIndex = offer.battle.p1TeamIndex;

        // Set to 0 (assume p0 signs with default team index of 0) for p0 signature validation
        offer.battle.p1TeamIndex = 0;

        // Validate that p0's signature is valid
        bytes32 structHash = BattleOfferLib.hashBattleOffer(offer);
        bytes32 digest = _hashTypedData(structHash);
        address signer = ECDSA.recover(digest, p0Signature);
        if (signer != offer.battle.p0) {
            revert InvalidSignature();
        }

        // Set back actual team index
        offer.battle.p1TeamIndex = actualP1TeamIndex;

        // Validate that caller is p1 or fills an open offer
        address caller = msg.sender;
        if (offer.battle.p1 == address(0)) {
            // Check if nonce is used, and update nonce / set correct caller for battle
            // We are abusing notation a bit here, it's actually the open offer nonce here
            if (openBattleOfferNonce[offer.battle.p0] != offer.pairHashNonce) {
                revert InvalidOpenBattleOfferNonce();
            }
            openBattleOfferNonce[offer.battle.p0] += 1;
            offer.battle.p1 = caller;
        }
        else if (offer.battle.p1 != caller) {
            revert NotP1();
        }
        else {
            // Validate that the pair hash nonce is correct
            (, bytes32 pairHash) = ENGINE.computeBattleKey(offer.battle.p0, offer.battle.p1);
            if (ENGINE.pairHashNonces(pairHash) != offer.pairHashNonce) {
                revert InvalidNonce();
            }
        }

        // Start the battle via the engine
        ENGINE.startBattle(offer.battle);
    }

    function validateMatch(bytes32, address) external pure returns (bool) {
        return true;
    }
}