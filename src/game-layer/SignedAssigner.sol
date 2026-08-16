// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ECDSA} from "../lib/ECDSA.sol";
import {EIP712} from "../lib/EIP712.sol";
import {IGachaPointsAssigner} from "./IGachaPointsAssigner.sol";

contract SignedAssigner is EIP712 {
    address public immutable SIGNER;
    IGachaPointsAssigner public immutable GACHA;

    mapping(uint256 word => uint256 bits) public claimBitmap;

    error ClaimAlreadySpent();

    event Claimed(address indexed recipient, uint256 amount, uint256 indexed claimId);

    constructor(address _SIGNER, address _GACHA) {
        SIGNER = _SIGNER;
        GACHA = IGachaPointsAssigner(_GACHA);
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedAssigner";
        version = "1";
    }

    /// @notice Redeem a signed grant. Callable by anyone; `recipient` is paid either way.
    function claim(address recipient, uint256 amount, uint256 claimId, bytes calldata signature) external {
        bytes32 digest = _hashTypedData(
            keccak256(
                abi.encode(
                    keccak256("Claim(address recipient,uint256 amount,uint256 claimId)"), recipient, amount, claimId
                )
            )
        );
        // Reverts InvalidSignature() itself on a malformed signature.
        if (ECDSA.recoverCalldata(digest, signature) != SIGNER) {
            revert ECDSA.InvalidSignature();
        }
        uint256 word = claimId >> 8;
        uint256 bit = 1 << (claimId & 0xFF);
        uint256 bits = claimBitmap[word];
        if (bits & bit != 0) {
            revert ClaimAlreadySpent();
        }
        claimBitmap[word] = bits | bit;

        GACHA.assignPoints(recipient, amount);
        emit Claimed(recipient, amount, claimId);
    }

    function isSpent(uint256 claimId) external view returns (bool) {
        return claimBitmap[claimId >> 8] & (1 << (claimId & 0xFF)) != 0;
    }
}
