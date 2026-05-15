// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "../lib/Ownable.sol";
import {MerkleProofLib} from "../lib/MerkleProofLib.sol";
import {IGachaPointsAssigner} from "./IGachaPointsAssigner.sol";
import {IExpAssigner} from "./IExpAssigner.sol";

/// @notice Merkle-gated gift distributor. The owner publishes a root whose leaves encode
/// `(claimer, pointsAmount, monIds, expAmounts)`; each eligible address can claim once per
/// root, and the gift is paid out through the registry's assigner interfaces.
contract ReturnerGift is Ownable {
    IGachaPointsAssigner public immutable POINTS_ASSIGNER;
    IExpAssigner public immutable EXP_ASSIGNER;

    bytes32 public merkleRoot;
    // Keyed by (root, claimer) so the owner can rotate roots without redeploying.
    mapping(bytes32 root => mapping(address claimer => bool)) public claimed;

    error AlreadyClaimed();
    error InvalidProof();

    constructor(IGachaPointsAssigner pointsAssigner, IExpAssigner expAssigner, address owner_) {
        POINTS_ASSIGNER = pointsAssigner;
        EXP_ASSIGNER = expAssigner;
        _initializeOwner(owner_);
    }

    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
    }

    function claim(
        bytes32[] calldata proof,
        uint256 pointsAmount,
        uint256[] calldata monIds,
        uint256[] calldata expAmounts
    ) external {
        bytes32 root = merkleRoot;
        if (claimed[root][msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(abi.encode(msg.sender, pointsAmount, monIds, expAmounts));
        if (!MerkleProofLib.verifyCalldata(proof, root, leaf)) revert InvalidProof();

        claimed[root][msg.sender] = true;

        if (pointsAmount > 0) POINTS_ASSIGNER.assignPoints(msg.sender, pointsAmount);
        if (monIds.length > 0) EXP_ASSIGNER.assignExp(msg.sender, monIds, expAmounts);
    }
}
