// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {ProposedBattle, Battle} from "../Structs.sol";
import {IMatchmaker} from "./IMatchmaker.sol";
import {MappingAllocator} from "../lib/MappingAllocator.sol";

/// @notice DEPRECATED — production matchmaking runs through SignedMatchmaker; this contract is
///         kept for the test suite only.
/// @dev KNOWN BUGS (won't-fix while deprecated — do NOT promote back to production without
///      addressing these; see GAS_AUDIT.md BUG-4):
///      1. Re-proposing the same battle double-allocates its storage key: proposeBattle calls
///         _initializeStorageKey unconditionally, which never checks for an existing battleKey
///         mapping. With a non-empty free pool the re-propose pops a second key and permanently
///         leaks the first; with an empty pool the new terms are written to the raw-key row while
///         _getStorageKey still resolves to the old mapped row, so accepts against the NEW terms
///         revert BattleChangedBeforeAcceptance while the OLD terms remain acceptable.
///      2. _cleanUpBattleProposal frees the storage key (deleting the battleKey mapping) BEFORE
///         resolving the proposal row, so on recycled keys the UNSET_P0_TEAM_INDEX marker lands
///         on the wrong (raw-key) row — a wasted fresh SSTORE and a row left looking active.
///      3. Open-proposal cycles free the post-fill alias key instead of the key owning the
///         proposal row (and the fast+open path never deletes its preP1FillBattleKey entry).
///         The (p0, address(0)) pair nonce never bumps, so EVERY open-proposal cycle strands the
///         row's real key and pushes a junk key into the pool.
///      Fix sketch if ever revived: route proposeBattle through a get-or-reuse storage-key helper
///      (reuse battleKeyToStorageKey[battleKey] when set), and in _cleanUpBattleProposal resolve
///      the preP1FillBattleKey override and mark the row consumed BEFORE freeing the owning key
///      (with acceptBattle's fast path passing the post-fill key when one exists).
contract DefaultMatchmaker is IMatchmaker, MappingAllocator {

    bytes32 constant public FAST_BATTLE_SENTINAL_HASH = 0x1000000000000000000000000000000000000000000000000000000000000000; // Used to skip the confirmBattle step
    uint96 constant UNSET_P0_TEAM_INDEX = type(uint96).max - 1; // Used to tell if a battle has been accepted by p1 or not
    uint96 constant UNSET_P1_TEAM_INDEX = type(uint96).max - 2; // Used to tell if a battle has been accepted by p1 or not

    IEngine public immutable ENGINE;

    event BattleProposal(bytes32 indexed battleKey, address indexed p0, address indexed p1, bool isFastBattle, bytes32 p0TeamHash);
    event BattleAcceptance(bytes32 indexed battleKey, address indexed p1, bytes32 indexed updatedBattleKey);

    error P0P1Same();
    error ProposerNotP0();
    error AcceptorNotP1();
    error ConfirmerNotP0();
    error AlreadyAccepted();
    error BattleChangedBeforeAcceptance();
    error InvalidP0TeamHash();
    error BattleNotAccepted();

    mapping(bytes32 battleKey => ProposedBattle) public proposals;
    mapping(bytes32 newBattleKey => bytes32 oldBattleKey) public preP1FillBattleKey;

    constructor(IEngine engine) {
        ENGINE = engine;
    }

    function getBattleProposalIntegrityHash(ProposedBattle memory proposal) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                proposal.p0TeamHash,
                proposal.validator,
                proposal.rngOracle,
                proposal.ruleset,
                proposal.teamRegistry,
                proposal.engineHooks,
                proposal.moveManager,
                proposal.matchmaker
            )
        );
    }
    
    /*
     P0 can bypass the final acceptBattle call by setting p0TeamIndex in the initial call and bytes32(0) for the p0TeamHash
     In this case, a different event is emitted, and calling acceptBattle will immediately start the battle
    */
    function proposeBattle(ProposedBattle memory proposal) external returns (bytes32 battleKey) {
        if (proposal.p0 != msg.sender) {
            revert ProposerNotP0();
        }
        if (proposal.p0 == proposal.p1) {
            revert P0P1Same();
        }
        (battleKey,) = ENGINE.computeBattleKey(proposal.p0, proposal.p1);
        bytes32 storageKey = _initializeStorageKey(battleKey);
        ProposedBattle storage existingBattle = proposals[storageKey];
        if (existingBattle.p0 != proposal.p0) {
            existingBattle.p0 = proposal.p0;
        }
        if (existingBattle.p0TeamIndex != proposal.p0TeamIndex) {
            existingBattle.p0TeamIndex = proposal.p0TeamIndex;
        }
        if (existingBattle.p0TeamHash != proposal.p0TeamHash) {
            existingBattle.p0TeamHash = proposal.p0TeamHash;
        }
        if (existingBattle.p1 != proposal.p1) {
            existingBattle.p1 = proposal.p1;
        }
        if (address(existingBattle.teamRegistry) != address(proposal.teamRegistry)) {
            existingBattle.teamRegistry = proposal.teamRegistry;
        }
        if (address(existingBattle.validator) != address(proposal.validator)) {
            existingBattle.validator = proposal.validator;
        }
        if (address(existingBattle.rngOracle) != address(proposal.rngOracle)) {
            existingBattle.rngOracle = proposal.rngOracle;
        }
        if (address(existingBattle.ruleset) != address(proposal.ruleset)) {
            existingBattle.ruleset = proposal.ruleset;
        }
        if (existingBattle.moveManager != proposal.moveManager) {
            existingBattle.moveManager = proposal.moveManager;
        }
        if (address(existingBattle.matchmaker) != address(proposal.matchmaker)) {
            existingBattle.matchmaker = proposal.matchmaker;
        }
        if (existingBattle.engineHooks.length != proposal.engineHooks.length && proposal.engineHooks.length != 0) {
            existingBattle.engineHooks = proposal.engineHooks;
        }
        proposals[storageKey].p1TeamIndex = UNSET_P1_TEAM_INDEX;
        emit BattleProposal(battleKey, proposal.p0, proposal.p1, proposal.p0TeamHash == FAST_BATTLE_SENTINAL_HASH, proposal.p0TeamHash);
        return battleKey;
    }

    function acceptBattle(bytes32 battleKey, uint96 p1TeamIndex, bytes32 battleIntegrityHash)
        external
        returns (bytes32 updatedBattleKey)
    {
        ProposedBattle storage proposal = proposals[_getStorageKey(battleKey)];
        // Override battle key if p1 is accepting an open battle proposal
        if (proposal.p1 == address(0)) {
            proposal.p1 = msg.sender;
            (bytes32 newBattleKey,) = ENGINE.computeBattleKey(proposal.p0, proposal.p1);
            preP1FillBattleKey[newBattleKey] = battleKey;
            updatedBattleKey = newBattleKey;
        } else if (proposal.p1 != msg.sender) {
            revert AcceptorNotP1();
        }
        if (getBattleProposalIntegrityHash(proposal) != battleIntegrityHash) {
            revert BattleChangedBeforeAcceptance();
        }
        if (proposal.p0TeamIndex == UNSET_P0_TEAM_INDEX) {
            revert AlreadyAccepted();
        }
        proposal.p1TeamIndex = p1TeamIndex;
        emit BattleAcceptance(battleKey, msg.sender, updatedBattleKey);
        if (proposal.p0TeamHash == FAST_BATTLE_SENTINAL_HASH) {
            ENGINE.startBattle(
                Battle({
                    p0: proposal.p0,
                    p0TeamIndex: proposal.p0TeamIndex,
                    p1: proposal.p1,
                    p1TeamIndex: proposal.p1TeamIndex,
                    teamRegistry: proposal.teamRegistry,
                    validator: proposal.validator,
                    rngOracle: proposal.rngOracle,
                    ruleset: proposal.ruleset,
                    engineHooks: proposal.engineHooks,
                    moveManager: proposal.moveManager,
                    matchmaker: proposal.matchmaker
                })
            );
            _cleanUpBattleProposal(battleKey);
        }
    }

    function confirmBattle(bytes32 battleKey, bytes32 salt, uint96 p0TeamIndex) external {
        bytes32 battleKeyToUse = battleKey;
        bytes32 battleKeyOverride = preP1FillBattleKey[battleKey];
        if (battleKeyOverride != bytes32(0)) {
            battleKeyToUse = battleKeyOverride;
        }
        ProposedBattle storage proposal = proposals[_getStorageKey(battleKeyToUse)];
        if (proposal.p1TeamIndex == UNSET_P1_TEAM_INDEX) {
            revert BattleNotAccepted();
        }
        if (proposal.p0 != msg.sender) {
            revert ConfirmerNotP0();
        }
        uint256[] memory p0TeamIndices = proposal.teamRegistry.getMonRegistryIndicesForTeam(msg.sender, p0TeamIndex);
        bytes32 revealedP0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));
        if (revealedP0TeamHash != proposal.p0TeamHash) {
            revert InvalidP0TeamHash();
        }
        ENGINE.startBattle(
            Battle({
                p0: proposal.p0,
                p0TeamIndex: p0TeamIndex,
                p1: proposal.p1,
                p1TeamIndex: proposal.p1TeamIndex,
                teamRegistry: proposal.teamRegistry,
                validator: proposal.validator,
                rngOracle: proposal.rngOracle,
                ruleset: proposal.ruleset,
                engineHooks: proposal.engineHooks,
                moveManager: proposal.moveManager,
                matchmaker: proposal.matchmaker
            })
        );
        _cleanUpBattleProposal(battleKey);
    }

    function _cleanUpBattleProposal(bytes32 battleKey) internal {
        _freeStorageKey(battleKey);
        bytes32 battleKeyToUse = battleKey;
        bytes32 battleKeyOverride = preP1FillBattleKey[battleKey];
        if (battleKeyOverride != bytes32(0)) {
            battleKeyToUse = battleKeyOverride;
        }
        ProposedBattle storage proposal = proposals[_getStorageKey(battleKeyToUse)];
        proposal.p0TeamIndex = UNSET_P0_TEAM_INDEX;
        delete preP1FillBattleKey[battleKey];
    }

    function validateMatch(bytes32 battleKey, address p0, address p1) external view returns (bool) {
        bytes32 battleKeyToUse = battleKey;
        bytes32 battleKeyOverride = preP1FillBattleKey[battleKey];
        if (battleKeyOverride != bytes32(0)) {
            battleKeyToUse = battleKeyOverride;
        }
        // This line will fail if we haven't called `proposeBattle()` beforehand (e.g. if someone tries to accept an already accepted battle where p1 = address(0))
        // We won't get the right storage key
        ProposedBattle storage proposal = proposals[_getStorageKey(battleKeyToUse)];
        // Read the proposal pair once and validate both players (batched: was two calls + two reads).
        address pp0 = proposal.p0;
        address pp1 = proposal.p1;
        return (p0 == pp0 || p0 == pp1) && (p1 == pp0 || p1 == pp1);
    }
}
