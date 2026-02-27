// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";

import {MonStats, Mon} from "../Structs.sol";
import {IEngine} from "../IEngine.sol";
import {IEngineHook} from "../IEngineHook.sol";
import {IGachaRNG} from "../rng/IGachaRNG.sol";
import {IMonRegistry} from "../teams/IMonRegistry.sol";
import {IOwnableMon} from "./IOwnableMon.sol";
import {IAbility} from "../abilities/IAbility.sol";
import {IMoveSet} from "../moves/IMoveSet.sol";

contract GachaRegistry is IMonRegistry, IEngineHook, IOwnableMon, IGachaRNG {
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

    // Only runs at OnBattleEnd (bit 3 = 0x08)
    uint16 public constant STEPS_BITMAP = 0x08;

    uint256 public constant INITIAL_ROLLS = 4;
    uint256 public constant ROLL_COST = 7;
    uint256 public constant POINTS_PER_WIN = 2;
    uint256 public constant POINTS_PER_LOSS = 1;

    uint256 public immutable BATTLE_COOLDOWN;

    IMonRegistry public immutable MON_REGISTRY;
    IEngine public immutable ENGINE;
    IGachaRNG immutable RNG;

    mapping(address => EnumerableSetLib.Uint256Set) private monsOwned;
    // Packed: bit 255 = firstGameBonusAwarded, bits 128-254 = lastBattleTimestamp, bits 0-127 = pointsBalance
    mapping(address => uint256) private playerData;

    uint256 private constant BONUS_AWARDED_BIT = 1 << 255;
    uint256 private constant TIMESTAMP_MASK = ((1 << 127) - 1) << 128;

    error AlreadyFirstRolled();
    error NoMoreStock();
    error NotEngine();

    event MonRoll(address indexed player, uint256[] monIds);
    event PointsAwarded(address indexed player, uint256 points);
    event PointsSpent(address indexed player, uint256 points);

    constructor(IMonRegistry _MON_REGISTRY, IEngine _ENGINE, IGachaRNG _RNG, uint256 _BATTLE_COOLDOWN) {
        MON_REGISTRY = _MON_REGISTRY;
        ENGINE = _ENGINE;
        if (address(_RNG) == address(0)) {
            RNG = IGachaRNG(address(this));
        } else {
            RNG = _RNG;
        }
        BATTLE_COOLDOWN = _BATTLE_COOLDOWN;
    }

    function pointsBalance(address player) public view returns (uint256) {
        return uint128(playerData[player]);
    }

    function lastBattleTimestamp(address player) public view returns (uint256) {
        return (playerData[player] & TIMESTAMP_MASK) >> 128;
    }

    function firstRoll() external returns (uint256[] memory monIds) {
        if (monsOwned[msg.sender].length() > 0) {
            revert AlreadyFirstRolled();
        }
        return _roll(INITIAL_ROLLS);
    }

    function roll(uint256 numRolls) external returns (uint256[] memory monIds) {
        if (monsOwned[msg.sender].length() == MON_REGISTRY.getMonCount()) {
            revert NoMoreStock();
        } else {
            uint256 cost = numRolls * ROLL_COST;
            uint256 data = playerData[msg.sender];
            uint256 currentPoints = uint128(data);
            playerData[msg.sender] = (data & (type(uint128).max << 128)) | (currentPoints - cost);
            emit PointsSpent(msg.sender, cost);
        }
        return _roll(numRolls);
    }

    function _roll(uint256 numRolls) internal returns (uint256[] memory monIds) {
        monIds = new uint256[](numRolls);
        uint256 numMons = MON_REGISTRY.getMonCount();
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender));
        uint256 prng = RNG.getRNG(seed);
        for (uint256 i; i < numRolls; ++i) {
            uint256 monId = prng % numMons;
            // Linear probing to solve for duplicate mons
            while (monsOwned[msg.sender].contains(monId)) {
                monId = (monId + 1) % numMons;
            }
            monIds[i] = monId;
            monsOwned[msg.sender].add(monId);
            seed = keccak256(abi.encodePacked(seed));
            prng = RNG.getRNG(seed);
        }
        emit MonRoll(msg.sender, monIds);
    }

    // Default RNG implementation
    function getRNG(bytes32 seed) public view returns (uint256) {
        return uint256(keccak256(abi.encode(blockhash(block.number - 1), seed)));
    }

    // IOwnableMons implementation
    function isOwner(address player, uint256 monId) external view returns (bool) {
        return monsOwned[player].contains(monId);
    }

    function isOwnerBatch(address player, uint256[] calldata monIds) external view returns (bool) {
        EnumerableSetLib.Uint256Set storage owned = monsOwned[player];
        uint256 len = monIds.length;
        for (uint256 i; i < len;) {
            if (!owned.contains(monIds[i])) {
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

    // IEngineHook implementation
    function getStepsBitmap() external pure override returns (uint16) {
        return STEPS_BITMAP;
    }

    function onBattleStart(bytes32 battleKey) external override {}

    function onRoundStart(bytes32 battleKey) external override {}

    function onRoundEnd(bytes32 battleKey) external override {}

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
        uint256 lastTimestamp = (data & TIMESTAMP_MASK) >> 128;

        // Award first-game bonus if not already awarded
        if (!bonusAwarded) {
            points += ROLL_COST;
            emit PointsAwarded(player, ROLL_COST);
        }

        // Award battle points if cooldown has passed
        if (lastTimestamp + BATTLE_COOLDOWN < block.timestamp) {
            points += battlePoints;
            playerData[player] = BONUS_AWARDED_BIT | (block.timestamp << 128) | points;
            emit PointsAwarded(player, battlePoints);
        } else if (!bonusAwarded) {
            // Only first-game bonus was awarded, write it back without updating timestamp
            playerData[player] = BONUS_AWARDED_BIT | (lastTimestamp << 128) | points;
        }
    }

    // All IMonRegistry functions are just pass throughs
    function getMonData(uint256 monId)
        external
        view
        returns (MonStats memory mon, address[] memory moves, address[] memory abilities)
    {
        return MON_REGISTRY.getMonData(monId);
    }

    function getMonDataBatch(uint256[] calldata monIds)
        external
        view
        returns (MonStats[] memory stats, address[][] memory moves, address[][] memory abilities)
    {
        return MON_REGISTRY.getMonDataBatch(monIds);
    }

    function getMonStats(uint256 monId) external view returns (MonStats memory) {
        return MON_REGISTRY.getMonStats(monId);
    }

    function getMonMetadata(uint256 monId, bytes32 key) external view returns (bytes32) {
        return MON_REGISTRY.getMonMetadata(monId, key);
    }

    function getMonCount() external view returns (uint256) {
        return MON_REGISTRY.getMonCount();
    }

    function getMonIds(uint256 start, uint256 end) external view returns (uint256[] memory) {
        return MON_REGISTRY.getMonIds(start, end);
    }

    function isValidMove(uint256 monId, IMoveSet move) external view returns (bool) {
        return MON_REGISTRY.isValidMove(monId, move);
    }

    function isValidAbility(uint256 monId, IAbility ability) external view returns (bool) {
        return MON_REGISTRY.isValidAbility(monId, ability);
    }

    function validateMon(Mon memory m, uint256 monId) external view returns (bool) {
        return MON_REGISTRY.validateMon(m, monId);
    }

    function validateMonBatch(Mon[] calldata mons, uint256[] calldata monIds) external view returns (bool) {
        return MON_REGISTRY.validateMonBatch(mons, monIds);
    }
}
