// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "../lib/Ownable.sol";
import {MerkleProofLib} from "../lib/MerkleProofLib.sol";
import {IGachaPointsAssigner} from "./IGachaPointsAssigner.sol";
import {IExpAssigner} from "./IExpAssigner.sol";
import {ITeamRegistry} from "./ITeamRegistry.sol";

/// @notice Merkle-gated returner gift. The owner publishes a root whose leaves encode
/// `(claimer, tier)` via `abi.encodePacked` (matches `analysis/build_merkle.py`); each
/// eligible address can claim once per root and receives a fixed reward bundle for
/// that tier. Exp recipients are resolved at claim time from the head of the claimer's
/// first live team.
contract ReturnerGift is Ownable {
    IGachaPointsAssigner public immutable POINTS_ASSIGNER;
    IExpAssigner public immutable EXP_ASSIGNER;
    ITeamRegistry public immutable TEAM_REGISTRY;

    bytes32 public merkleRoot;
    // Keyed by (root, claimer) so the owner can rotate roots without redeploying.
    mapping(bytes32 root => mapping(address claimer => bool)) public claimed;

    error AlreadyClaimed();
    error InvalidProof();
    error InvalidTier();
    error NoLiveTeam();

    constructor(address registry) {
        POINTS_ASSIGNER = IGachaPointsAssigner(registry);
        EXP_ASSIGNER = IExpAssigner(registry);
        TEAM_REGISTRY = ITeamRegistry(registry);
        _initializeOwner(msg.sender);
    }

    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
    }

    function claim(bytes32[] calldata proof, uint256 tier) external {
        bytes32 root = merkleRoot;
        if (claimed[root][msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, tier));
        if (!MerkleProofLib.verifyCalldata(proof, root, leaf)) revert InvalidProof();

        claimed[root][msg.sender] = true;

        (uint256 pointsAmount, uint256 monCount, uint256 expPerMon) = _tierRewards(tier);

        POINTS_ASSIGNER.assignPoints(msg.sender, pointsAmount);

        if (monCount > 0) {
            uint256[] memory liveSlots = TEAM_REGISTRY.getOrderedLiveTeams(msg.sender);
            if (liveSlots.length == 0) revert NoLiveTeam();
            uint256[] memory teamMons = TEAM_REGISTRY.getMonRegistryIndicesForTeam(msg.sender, liveSlots[0]);
            uint256[] memory monIds = new uint256[](monCount);
            uint256[] memory expAmounts = new uint256[](monCount);
            for (uint256 i; i < monCount; ++i) {
                monIds[i] = teamMons[i];
                expAmounts[i] = expPerMon;
            }
            EXP_ASSIGNER.assignExp(msg.sender, monIds, expAmounts);
        }
    }

    function _tierRewards(uint256 tier)
        internal
        pure
        returns (uint256 pointsAmount, uint256 monCount, uint256 expPerMon)
    {
        if (tier == 1) return (16, 0, 0);
        if (tier == 2) return (16, 1, 4);
        if (tier == 3) return (16, 2, 4);
        if (tier == 4) return (20, 3, 8);
        if (tier == 5) return (24, 4, 8);
        if (tier == 6) return (31, 4, 8);
        revert InvalidTier();
    }
}
