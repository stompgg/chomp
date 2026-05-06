// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import "./ITeamRegistry.sol";

import {GACHA_ROLL_COST, GACHA_POINTS_PER_WIN, GACHA_POINTS_PER_LOSS} from "../Constants.sol";
import {EngineHookStep} from "../Enums.sol";
import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";
import {IEngine} from "../IEngine.sol";
import {IEngineHook} from "../IEngineHook.sol";
import {IGachaRNG} from "../rng/IGachaRNG.sol";
import {Ownable} from "../lib/Ownable.sol";

contract GachaTeamRegistry is ITeamRegistry, IEngineHook, IGachaRNG, Ownable {
    using EnumerableSetLib for *;

    // ----- Team layout -----
    uint32 constant BITS_PER_MON_INDEX = 32;
    uint256 constant ONES_MASK = (2 ** BITS_PER_MON_INDEX) - 1;

    // ----- Gacha constants -----
    uint256 public constant INITIAL_ROLLS = 4;
    uint256 public constant ROLL_COST = GACHA_ROLL_COST;
    uint256 public constant POINTS_PER_WIN = GACHA_POINTS_PER_WIN;
    uint256 public constant POINTS_PER_LOSS = GACHA_POINTS_PER_LOSS;
    uint16 public constant STEPS_BITMAP = uint16(1) << uint8(EngineHookStep.OnBattleEnd);
    uint256 private constant BONUS_AWARDED_BIT = 1 << 255;

    // ----- Errors -----
    error InvalidTeamSize();
    error DuplicateMonId();
    error InvalidTeamIndex();
    error NotOwner();
    error NotWhitelistedOpponent();
    error MonAlreadyCreated();
    error MonNotyetCreated();
    error AlreadyFirstRolled();
    error NoMoreStock();
    error NotEngine();

    // ----- Events -----
    event MonRoll(address indexed player, uint256[] monIds);
    event PointsAwarded(address indexed player, uint256 points);
    event PointsSpent(address indexed player, uint256 points);

    // ----- Immutables -----
    uint256 immutable MONS_PER_TEAM;
    uint256 immutable MOVES_PER_MON;
    IEngine public immutable ENGINE;
    IGachaRNG immutable RNG;

    // ----- Team state -----
    mapping(address => mapping(uint256 => uint256)) public monRegistryIndicesForTeamPacked;
    mapping(address => uint256) public numTeams;
    mapping(address => bool) public isWhitelistedOpponent;

    // ----- Mon registry state -----
    EnumerableSetLib.Uint256Set private monIds;
    mapping(uint256 monId => MonStats) public monStats;
    mapping(uint256 monId => EnumerableSetLib.Uint256Set) private monMoves;
    mapping(uint256 monId => EnumerableSetLib.Uint256Set) private monAbilities;
    mapping(uint256 monId => mapping(bytes32 => bytes32)) private monMetadata;

    // ----- Gacha state -----
    mapping(address => EnumerableSetLib.Uint256Set) private monsOwned;
    // Packed: bit 255 = firstGameBonusAwarded, bits 0-127 = pointsBalance
    mapping(address => uint256) private playerData;

    constructor(uint256 _MONS_PER_TEAM, uint256 _MOVES_PER_MON, IEngine _ENGINE, IGachaRNG _RNG) {
        MONS_PER_TEAM = _MONS_PER_TEAM;
        MOVES_PER_MON = _MOVES_PER_MON;
        ENGINE = _ENGINE;
        RNG = address(_RNG) == address(0) ? IGachaRNG(address(this)) : _RNG;
        _initializeOwner(msg.sender);
    }

    // =====================================================================
    // Team management
    // =====================================================================

    function _validateOwnership(uint256[] memory monIndices) internal view {
        if (!_isOwnerBatch(msg.sender, monIndices)) revert NotOwner();
    }

    function createTeam(uint256[] memory monIndices) external {
        _validateOwnership(monIndices);
        _createTeamForUser(msg.sender, monIndices);
    }

    function createTeamForUser(address user, uint256[] memory monIndices) external onlyOwner {
        _createTeamForUser(user, monIndices);
    }

    function setWhitelistedOpponents(address[] memory toAllow, address[] memory toDisallow) external onlyOwner {
        for (uint256 i; i < toAllow.length;) {
            isWhitelistedOpponent[toAllow[i]] = true;
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < toDisallow.length;) {
            isWhitelistedOpponent[toDisallow[i]] = false;
            unchecked {
                ++i;
            }
        }
    }

    // Phantom teams allow duplicate mon ids; the regular createTeam path enforces uniqueness via _packTeam.
    function setOpponentTeam(address opponent, uint256[] memory monIndices) external {
        if (!isWhitelistedOpponent[opponent]) revert NotWhitelistedOpponent();
        monRegistryIndicesForTeamPacked[opponent][uint256(uint160(msg.sender))] = _packIndices(monIndices);
    }

    function _createTeamForUser(address user, uint256[] memory monIndices) internal {
        uint256 packed = _packTeam(monIndices);

        uint256 teamId = numTeams[user];
        monRegistryIndicesForTeamPacked[user][teamId] = packed;

        // Update the team index
        numTeams[user] = teamId + 1;
    }

    function _packTeam(uint256[] memory monIndices) internal view returns (uint256 packed) {
        packed = _packIndices(monIndices);
        _checkForDuplicates(monIndices);
    }

    function _packIndices(uint256[] memory monIndices) internal view returns (uint256 packed) {
        if (monIndices.length != MONS_PER_TEAM) {
            revert InvalidTeamSize();
        }
        for (uint256 i; i < MONS_PER_TEAM;) {
            packed |= uint256(uint32(monIndices[i])) << (i * BITS_PER_MON_INDEX);
            unchecked {
                ++i;
            }
        }
    }

    function _unpackTeam(uint256 packed) internal view returns (uint256[] memory ids) {
        ids = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = uint32(packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }
    }

    function updateTeam(uint256 teamIndex, uint256[] memory teamMonIndicesToOverride, uint256[] memory newMonIndices)
        external
    {
        _validateOwnership(newMonIndices);

        uint256 numMonsToOverride = teamMonIndicesToOverride.length;

        // Check for duplicate mon indices
        _checkForDuplicates(newMonIndices);

        // Update the team
        for (uint256 i; i < numMonsToOverride; i++) {
            uint256 monIndexToOverride = teamMonIndicesToOverride[i];
            _setMonRegistryIndices(teamIndex, uint32(newMonIndices[i]), monIndexToOverride, msg.sender);
        }
    }

    function _checkForDuplicates(uint256[] memory monIndices) internal view {
        for (uint256 i; i < MONS_PER_TEAM - 1; i++) {
            for (uint256 j = i + 1; j < MONS_PER_TEAM; j++) {
                if (monIndices[i] == monIndices[j]) {
                    revert DuplicateMonId();
                }
            }
        }
    }

    // Layout: | Nothing | Nothing | Mon5 | Mon4 | Mon3 | Mon2 | Mon1 | Mon 0 <-- rightmost bits
    function _setMonRegistryIndices(uint256 teamIndex, uint32 monId, uint256 position, address caller) internal {
        // Create a bitmask to clear the bits we want to modify
        uint256 clearBitmask = ~(ONES_MASK << (position * BITS_PER_MON_INDEX));

        // Get the existing packed value
        uint256 existingPackedValue = monRegistryIndicesForTeamPacked[caller][teamIndex];

        // Clear the bits we want to modify
        uint256 clearedValue = existingPackedValue & clearBitmask;

        // Create the value bitmask with the new monId
        uint256 valueBitmask = uint256(monId) << (position * BITS_PER_MON_INDEX);

        // Combine the cleared value with the new value
        monRegistryIndicesForTeamPacked[caller][teamIndex] = clearedValue | valueBitmask;
    }

    function _getMonRegistryIndex(address player, uint256 teamIndex, uint256 position) internal view returns (uint256) {
        return uint32(monRegistryIndicesForTeamPacked[player][teamIndex] >> (position * BITS_PER_MON_INDEX));
    }

    function getMonRegistryIndicesForTeam(address player, uint256 teamIndex) public view returns (uint256[] memory) {
        if (!isWhitelistedOpponent[player] && teamIndex >= numTeams[player]) {
            revert InvalidTeamIndex();
        }
        return _unpackTeam(monRegistryIndicesForTeamPacked[player][teamIndex]);
    }

    function getTeam(address player, uint256 teamIndex) external view returns (Mon[] memory) {
        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        uint256[] memory ids = _unpackTeam(monRegistryIndicesForTeamPacked[player][teamIndex]);

        (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities) = _getMonDataBatch(ids);

        // Unpack into team
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256[] memory movesToUse = new uint256[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                movesToUse[j] = moves[i][j];
                unchecked {
                    ++j;
                }
            }
            team[i] = Mon({stats: stats[i], ability: abilities[i][0], moves: movesToUse});
            unchecked {
                ++i;
            }
        }
        return team;
    }

    function getTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex) external view returns (Mon[] memory, Mon[] memory) {
        Mon[] memory p0Team = new Mon[](MONS_PER_TEAM);
        Mon[] memory p1Team = new Mon[](MONS_PER_TEAM);

        uint256 p0Packed = monRegistryIndicesForTeamPacked[p0][p0TeamIndex];
        uint256 p1Packed = monRegistryIndicesForTeamPacked[p1][p1TeamIndex];

        // Build all monIds for batch call
        uint256 totalMons = MONS_PER_TEAM * 2;
        uint256[] memory ids = new uint256[](totalMons);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = uint32(p0Packed >> (i * BITS_PER_MON_INDEX));
            ids[i + MONS_PER_TEAM] = uint32(p1Packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }

        (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities) = _getMonDataBatch(ids);

        // Unpack into teams
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256[] memory p0MovesToUse = new uint256[](MOVES_PER_MON);
            uint256[] memory p1MovesToUse = new uint256[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                p0MovesToUse[j] = moves[i][j];
                p1MovesToUse[j] = moves[i + MONS_PER_TEAM][j];
                unchecked {
                    ++j;
                }
            }
            p0Team[i] = Mon({stats: stats[i], ability: abilities[i][0], moves: p0MovesToUse});
            p1Team[i] = Mon({stats: stats[i + MONS_PER_TEAM], ability: abilities[i + MONS_PER_TEAM][0], moves: p1MovesToUse});
            unchecked {
                ++i;
            }
        }

        return (p0Team, p1Team);
    }

    function getTeamCount(address player) external view returns (uint256) {
        return numTeams[player];
    }

    // =====================================================================
    // Mon registry
    // =====================================================================

    function createMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory allowedMoves,
        uint256[] memory allowedAbilities,
        bytes32[] memory keys,
        bytes32[] memory values
    ) external onlyOwner {
        MonStats storage existingMon = monStats[monId];
        // No mon has 0 hp and 0 stamina
        if (existingMon.hp != 0 && existingMon.stamina != 0) {
            revert MonAlreadyCreated();
        }
        monIds.add(monId);
        monStats[monId] = _monStats;
        EnumerableSetLib.Uint256Set storage moves = monMoves[monId];
        uint256 numMoves = allowedMoves.length;
        for (uint256 i; i < numMoves; ++i) {
            moves.add(allowedMoves[i]);
        }
        EnumerableSetLib.Uint256Set storage abilities = monAbilities[monId];
        uint256 numAbilities = allowedAbilities.length;
        for (uint256 i; i < numAbilities; ++i) {
            abilities.add(allowedAbilities[i]);
        }
        _modifyMonMetadata(monId, keys, values);
    }

    function modifyMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory movesToAdd,
        uint256[] memory movesToRemove,
        uint256[] memory abilitiesToAdd,
        uint256[] memory abilitiesToRemove
    ) external onlyOwner {
        MonStats storage existingMon = monStats[monId];
        if (existingMon.hp == 0 && existingMon.stamina == 0) {
            revert MonNotyetCreated();
        }
        monStats[monId] = _monStats;
        EnumerableSetLib.Uint256Set storage moves = monMoves[monId];
        {
            uint256 numMovesToAdd = movesToAdd.length;
            for (uint256 i; i < numMovesToAdd; ++i) {
                moves.add(movesToAdd[i]);
            }
        }
        {
            uint256 numMovesToRemove = movesToRemove.length;
            for (uint256 i; i < numMovesToRemove; ++i) {
                moves.remove(movesToRemove[i]);
            }
        }
        EnumerableSetLib.Uint256Set storage abilities = monAbilities[monId];
        {
            uint256 numAbilitiesToAdd = abilitiesToAdd.length;
            for (uint256 i; i < numAbilitiesToAdd; ++i) {
                abilities.add(abilitiesToAdd[i]);
            }
        }
        {
            uint256 numAbilitiesToRemove = abilitiesToRemove.length;
            for (uint256 i; i < numAbilitiesToRemove; ++i) {
                abilities.remove(abilitiesToRemove[i]);
            }
        }
    }

    function modifyMonMetadata(uint256 monId, bytes32[] memory keys, bytes32[] memory values) external onlyOwner {
        _modifyMonMetadata(monId, keys, values);
    }

    function _modifyMonMetadata(uint256 monId, bytes32[] memory keys, bytes32[] memory values) internal {
        mapping(bytes32 => bytes32) storage metadata = monMetadata[monId];
        for (uint256 i; i < keys.length; ++i) {
            metadata[keys[i]] = values[i];
        }
    }

    function getMonMetadata(uint256 monId, bytes32 key) external view returns (bytes32) {
        return monMetadata[monId][key];
    }

    function validateMon(Mon memory m, uint256 monId) public view returns (bool) {
        // Check that the mon's stats match the current mon ID's stats
        if (
            m.stats.attack != monStats[monId].attack || m.stats.defense != monStats[monId].defense
                || m.stats.specialAttack != monStats[monId].specialAttack
                || m.stats.specialDefense != monStats[monId].specialDefense || m.stats.speed != monStats[monId].speed
                || m.stats.hp != monStats[monId].hp || m.stats.stamina != monStats[monId].stamina
        ) {
            return false;
        }
        // Check that the mon's moves are valid for the current mon ID
        for (uint256 i; i < m.moves.length; ++i) {
            if (!monMoves[monId].contains(m.moves[i])) {
                return false;
            }
        }
        // Check that the mon's ability is valid for the current mon ID
        if (!monAbilities[monId].contains(m.ability)) {
            return false;
        }
        return true;
    }

    function validateMonBatch(Mon[] calldata mons, uint256[] calldata ids) external view returns (bool) {
        uint256 len = mons.length;
        for (uint256 i; i < len;) {
            if (!validateMon(mons[i], ids[i])) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function getMonData(uint256 monId)
        external
        view
        returns (MonStats memory _monStats, uint256[] memory moves, uint256[] memory abilities)
    {
        _monStats = monStats[monId];
        moves = monMoves[monId].values();
        abilities = monAbilities[monId].values();
    }

    function getMonDataBatch(uint256[] calldata ids)
        external
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        return _getMonDataBatch(ids);
    }

    function _getMonDataBatch(uint256[] memory ids)
        internal
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        uint256 len = ids.length;
        stats = new MonStats[](len);
        moves = new uint256[][](len);
        abilities = new uint256[][](len);
        for (uint256 i; i < len;) {
            uint256 monId = ids[i];
            stats[i] = monStats[monId];
            moves[i] = monMoves[monId].values();
            abilities[i] = monAbilities[monId].values();
            unchecked {
                ++i;
            }
        }
    }

    function getMonIds(uint256 start, uint256 end) external view returns (uint256[] memory) {
        if (start == end) {
            uint256[] memory allIds = new uint256[](monIds.length());
            for (uint256 i; i < monIds.length(); ++i) {
                allIds[i] = monIds.at(i);
            }
            return allIds;
        }
        uint256[] memory ids = new uint256[](end - start);
        for (uint256 i; i < end - start; ++i) {
            ids[i] = monIds.at(start + i);
        }
        return ids;
    }

    function getMonStats(uint256 monId) external view returns (MonStats memory) {
        return monStats[monId];
    }

    function isValidMove(uint256 monId, uint256 moveSlot) external view returns (bool) {
        return monMoves[monId].contains(moveSlot);
    }

    function isValidAbility(uint256 monId, uint256 ability) external view returns (bool) {
        return monAbilities[monId].contains(ability);
    }

    function getMonCount() external view returns (uint256) {
        return monIds.length();
    }

    // =====================================================================
    // Gacha
    // =====================================================================

    function pointsBalance(address player) public view returns (uint256) {
        return uint128(playerData[player]);
    }

    function firstRoll() external returns (uint256[] memory) {
        if (monsOwned[msg.sender].length() > 0) {
            revert AlreadyFirstRolled();
        }
        return _roll(INITIAL_ROLLS);
    }

    function roll(uint256 numRolls) external returns (uint256[] memory) {
        if (monsOwned[msg.sender].length() == monIds.length()) {
            revert NoMoreStock();
        } else {
            uint256 cost = numRolls * ROLL_COST;
            uint256 data = playerData[msg.sender];
            uint256 currentPoints = uint128(data);
            playerData[msg.sender] = (data & BONUS_AWARDED_BIT) | (currentPoints - cost);
            emit PointsSpent(msg.sender, cost);
        }
        return _roll(numRolls);
    }

    function _roll(uint256 numRolls) internal returns (uint256[] memory rolledIds) {
        rolledIds = new uint256[](numRolls);
        uint256 numMons = monIds.length();
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender));
        uint256 prng = RNG.getRNG(seed);
        for (uint256 i; i < numRolls; ++i) {
            uint256 monId = prng % numMons;
            // Linear probing to solve for duplicate mons
            while (monsOwned[msg.sender].contains(monId)) {
                monId = (monId + 1) % numMons;
            }
            rolledIds[i] = monId;
            monsOwned[msg.sender].add(monId);
            seed = keccak256(abi.encodePacked(seed));
            prng = RNG.getRNG(seed);
        }
        emit MonRoll(msg.sender, rolledIds);
    }

    // Default RNG implementation (used when constructed with address(0) RNG)
    function getRNG(bytes32 seed) public view returns (uint256) {
        return uint256(keccak256(abi.encode(blockhash(block.number - 1), seed)));
    }

    // ----- Ownership -----
    function isOwner(address player, uint256 monId) external view returns (bool) {
        return monsOwned[player].contains(monId);
    }

    function isOwnerBatch(address player, uint256[] calldata ids) external view returns (bool) {
        return _isOwnerBatch(player, ids);
    }

    function _isOwnerBatch(address player, uint256[] memory ids) internal view returns (bool) {
        EnumerableSetLib.Uint256Set storage owned = monsOwned[player];
        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            if (!owned.contains(ids[i])) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function balanceOf(address player) external view returns (uint256) {
        return monsOwned[player].length();
    }

    function getOwned(address player) external view returns (uint256[] memory) {
        return monsOwned[player].values();
    }

    // ----- IEngineHook -----
    function getStepsBitmap() external pure override returns (uint16) {
        return STEPS_BITMAP;
    }

    function onBattleStart(bytes32) external override {}

    function onRoundStart(bytes32) external override {}

    function onRoundEnd(bytes32) external override {}

    function onBattleEnd(bytes32 battleKey) external override {
        if (msg.sender != address(ENGINE)) {
            revert NotEngine();
        }
        address[] memory players = ENGINE.getPlayersForBattle(battleKey);
        address winner = ENGINE.getWinner(battleKey);
        if (winner == address(0)) {
            return;
        }
        uint256 p0Points;
        uint256 p1Points;
        if (winner == players[0]) {
            p0Points = POINTS_PER_WIN;
            p1Points = POINTS_PER_LOSS;
        } else {
            p0Points = POINTS_PER_LOSS;
            p1Points = POINTS_PER_WIN;
        }
        _awardPoints(players[0], p0Points);
        _awardPoints(players[1], p1Points);
    }

    function _awardPoints(address player, uint256 battlePoints) internal {
        uint256 data = playerData[player];
        uint256 points = uint128(data);
        bool bonusAwarded = data & BONUS_AWARDED_BIT != 0;

        if (!bonusAwarded) {
            points += ROLL_COST;
            emit PointsAwarded(player, ROLL_COST);
        }

        points += battlePoints;
        emit PointsAwarded(player, battlePoints);

        playerData[player] = BONUS_AWARDED_BIT | points;
    }
}
