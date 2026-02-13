// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {DefaultTeamRegistry} from "../src/teams/DefaultTeamRegistry.sol";

import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {EffectAbility} from "./mocks/EffectAbility.sol";
import {EffectAttack} from "./mocks/EffectAttack.sol";

import {IAbility} from "../src/abilities/IAbility.sol";
import {IEffect} from "../src/effects/IEffect.sol";

import {IEngine} from "../src/IEngine.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";

contract TeamsTest is Test {
    address constant ALICE = address(1);
    address constant BOB = address(2);

    DefaultMonRegistry monRegistry;
    DefaultTeamRegistry teamRegistry;

    function setUp() public {
        monRegistry = new DefaultMonRegistry();
        teamRegistry = new DefaultTeamRegistry(
            DefaultTeamRegistry.Args({REGISTRY: monRegistry, MONS_PER_TEAM: 1, MOVES_PER_MON: 1})
        );
        // Make Alice the mon registry owner
        monRegistry.transferOwnership(ALICE);
    }

    function test_monRegistryFlow() public {
        IAbility ability = new EffectAbility(IEngine(address(0)), IEffect(address(0)));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = ability;

        IMoveSet move = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = move;

        MonStats memory stats = MonStats({
            hp: 1,
            stamina: 1,
            speed: 1,
            attack: 1,
            defense: 1,
            specialAttack: 1,
            specialDefense: 1,
            type1: Type.Fire,
            type2: Type.None
        });

        bytes32[] memory nameKey = new bytes32[](1);
        nameKey[0] = bytes32("name");
        bytes32[] memory nameValue = new bytes32[](1);
        nameValue[0] = bytes32("sus");

        // Create a mon in the mon registry
        vm.startPrank(ALICE);
        monRegistry.createMon(0, stats, moves, abilities, nameKey, nameValue);

        // Assert that the metadata exists
        bytes32 monName = monRegistry.getMonMetadata(0, bytes32("name"));
        assertEq(monName, bytes32("sus"));

        // Assert that Bob cannot create a mon
        vm.startPrank(BOB);
        vm.expectRevert();
        monRegistry.createMon(1, stats, moves, abilities, nameKey, nameValue);

        MonStats memory newStats = MonStats({
            hp: 2,
            stamina: 2,
            speed: 2,
            attack: 2,
            defense: 2,
            specialAttack: 2,
            specialDefense: 2,
            type1: Type.Fire,
            type2: Type.None
        });

        IMoveSet newMove = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 2, PRIORITY: 2})
        );
        IMoveSet[] memory newMoves = new IMoveSet[](1);
        newMoves[0] = newMove;

        IAbility newAbility = new EffectAbility(IEngine(address(0)), IEffect(address(0)));
        IAbility[] memory newAbilities = new IAbility[](1);
        newAbilities[0] = newAbility;

        // Assert that Alice can edit a mon
        vm.startPrank(ALICE);
        monRegistry.modifyMon(0, newStats, newMoves, moves, newAbilities, abilities);

        // Assert that the old move is no longer valid from the mon registry
        // and that the new move is
        assertEq(monRegistry.isValidMove(0, move), false);
        assertEq(monRegistry.isValidMove(0, newMove), true);

        // Assert that the old ability is no longer valid from the mon registry
        // and that the new ability is
        assertEq(monRegistry.isValidAbility(0, ability), false);
        assertEq(monRegistry.isValidAbility(0, newAbility), true);

        // Assert that Bob cannot edit a mon
        vm.startPrank(BOB);
        vm.expectRevert();
        monRegistry.modifyMon(0, newStats, newMoves, moves, newAbilities, abilities);

        // Assert that only Alice can set additional metadata
        vm.startPrank(ALICE);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = "test";
        bytes32[] memory values = new bytes32[](1);
        values[0] = bytes32("test");
        monRegistry.modifyMonMetadata(0, keys, values);

        // Assert that Bob cannot set additional metadata
        vm.startPrank(BOB);
        vm.expectRevert();
        monRegistry.modifyMonMetadata(0, keys, values);
    }

    function test_teamRegistryFlow() public {
        IAbility ability = new EffectAbility(IEngine(address(0)), IEffect(address(0)));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = ability;

        IMoveSet move1 = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );

        IMoveSet move2 = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = move1;
        moves[1] = move2;

        MonStats memory stats = MonStats({
            hp: 1,
            stamina: 1,
            speed: 1,
            attack: 1,
            defense: 1,
            specialAttack: 1,
            specialDefense: 1,
            type1: Type.Fire,
            type2: Type.None
        });

        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);

        vm.startPrank(ALICE);
        monRegistry.createMon(0, stats, moves, abilities, keys, values);

        uint256[] memory monIndices = new uint256[](1);
        monIndices[0] = 0;
        IMoveSet[4][] memory movesToUse = new IMoveSet[4][](1);
        movesToUse[0][0] = move1;
        IAbility[] memory abilitiesToUse = new IAbility[](1);
        abilitiesToUse[0] = ability;
        teamRegistry.createTeam(monIndices, movesToUse, abilitiesToUse);

        // Assert the team for Alice exists
        assertEq(teamRegistry.getTeamCount(ALICE), 1);
        Mon[] memory aliceTeam0 = teamRegistry.getTeam(ALICE, 0);
        assertEq(aliceTeam0.length, 1);
        assertEq(uint256(aliceTeam0[0].stats.type1), uint256(Type.Fire));
        uint256[] memory teamIndices = teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0);
        assertEq(teamIndices.length, 1);
        assertEq(teamIndices[0], 0);
    }

    function test_realTeamFlow() public {
        // Make the same mon 6 times
        IAbility ability = new EffectAbility(IEngine(address(0)), IEffect(address(0)));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = ability;
        IMoveSet move1 = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet move2 = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = move1;
        moves[1] = move2;
        MonStats memory stats = MonStats({
            hp: 1,
            stamina: 1,
            speed: 1,
            attack: 1,
            defense: 1,
            specialAttack: 1,
            specialDefense: 1,
            type1: Type.Fire,
            type2: Type.None
        });
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);

        // Ids 0 to 5 are all the mon
        vm.startPrank(ALICE);
        monRegistry.createMon(0, stats, moves, abilities, keys, values);
        monRegistry.createMon(1, stats, moves, abilities, keys, values);
        monRegistry.createMon(2, stats, moves, abilities, keys, values);
        monRegistry.createMon(3, stats, moves, abilities, keys, values);
        monRegistry.createMon(4, stats, moves, abilities, keys, values);
        monRegistry.createMon(5, stats, moves, abilities, keys, values);

        // Create new team registry with team size of 6 and move size of 0
        DefaultTeamRegistry teamRegistry2 = new DefaultTeamRegistry(
            DefaultTeamRegistry.Args({REGISTRY: monRegistry, MONS_PER_TEAM: 6, MOVES_PER_MON: 0})
        );

        // Register the team for Alice
        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](6);
        monIndices[0] = 0;
        monIndices[1] = 1;
        monIndices[2] = 2;
        monIndices[3] = 3;
        monIndices[4] = 4;
        monIndices[5] = 5;
        IAbility[] memory abilitiesToUse = new IAbility[](6);
        abilitiesToUse[0] = ability;
        abilitiesToUse[1] = ability;
        abilitiesToUse[2] = ability;
        abilitiesToUse[3] = ability;
        abilitiesToUse[4] = ability;
        abilitiesToUse[5] = ability;
        teamRegistry2.createTeam(monIndices, new IMoveSet[4][](6), abilitiesToUse);

        // Assert the team for Alice exists
        assertEq(teamRegistry2.getTeamCount(ALICE), 1);
        Mon[] memory aliceTeam0 = teamRegistry2.getTeam(ALICE, 0);
        assertEq(aliceTeam0.length, 6);

        // Check the team indices are as expected
        uint256[] memory teamIndices = teamRegistry2.getMonRegistryIndicesForTeam(ALICE, 0);
        assertEq(teamIndices.length, 6);
        assertEq(teamIndices[0], 0);
        assertEq(teamIndices[1], 1);
        assertEq(teamIndices[2], 2);
        assertEq(teamIndices[3], 3);
        assertEq(teamIndices[4], 4);
        assertEq(teamIndices[5], 5);

        // Prank as Bob and copy the team
        vm.startPrank(BOB);
        teamRegistry2.copyTeam(ALICE, 0);

        // Assert the team for Bob exists and is the same
        assertEq(teamRegistry2.getTeamCount(BOB), 1);
        Mon[] memory bobTeam0 = teamRegistry2.getTeam(BOB, 0);
        assertEq(bobTeam0.length, 6);
        assertEq(uint256(bobTeam0[0].stats.type1), uint256(Type.Fire));
        teamIndices = teamRegistry2.getMonRegistryIndicesForTeam(BOB, 0);
        assertEq(teamIndices.length, 6);
        assertEq(teamIndices[0], 0);
        assertEq(teamIndices[1], 1);
        assertEq(teamIndices[2], 2);
        assertEq(teamIndices[3], 3);
        assertEq(teamIndices[4], 4);
        assertEq(teamIndices[5], 5);
    }

    function test_duplicateTeamFails() public {
        // Make the same mon 6 times
        IAbility ability = new EffectAbility(IEngine(address(0)), IEffect(address(0)));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = ability;
        IMoveSet move1 = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet move2 = new EffectAttack(
            IEngine(address(0)), IEffect(address(0)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = move1;
        moves[1] = move2;
        MonStats memory stats = MonStats({
            hp: 1,
            stamina: 1,
            speed: 1,
            attack: 1,
            defense: 1,
            specialAttack: 1,
            specialDefense: 1,
            type1: Type.Fire,
            type2: Type.None
        });
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);

        // Team IDs 0 to 5 are all the mon
        vm.startPrank(ALICE);
        monRegistry.createMon(0, stats, moves, abilities, keys, values);

        uint256[] memory monIndices = new uint256[](2);
        monIndices[0] = 0;
        monIndices[1] = 0;
        IAbility[] memory abilitiesToUse = new IAbility[](2);
        abilitiesToUse[0] = ability;
        abilitiesToUse[1] = ability;

        DefaultTeamRegistry teamRegistry2 = new DefaultTeamRegistry(
            DefaultTeamRegistry.Args({REGISTRY: monRegistry, MONS_PER_TEAM: 2, MOVES_PER_MON: 0})
        );

        vm.expectRevert(DefaultTeamRegistry.DuplicateMonId.selector);
        teamRegistry2.createTeam(monIndices, new IMoveSet[4][](2), abilitiesToUse);
    }

    function test_createUniqueTeam() public {
        IAbility ability = new EffectAbility(IEngine(address(0)), IEffect(address(0)));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = ability;

        StandardAttackFactory attackFactory =
            new StandardAttackFactory(IEngine(address(0)), ITypeCalculator(address(0)));

        IMoveSet[] memory moves0 = new IMoveSet[](4);

        moves0[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 0,
                PRIORITY: 0,
                MOVE_TYPE: Type.Air,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m00",
                EFFECT: IEffect(address(0))
            })
        );
        moves0[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 1,
                PRIORITY: 1,
                MOVE_TYPE: Type.Air,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m01",
                EFFECT: IEffect(address(0))
            })
        );
        moves0[2] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 2,
                STAMINA_COST: 2,
                ACCURACY: 2,
                PRIORITY: 2,
                MOVE_TYPE: Type.Air,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m02",
                EFFECT: IEffect(address(0))
            })
        );
        moves0[3] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3,
                STAMINA_COST: 3,
                ACCURACY: 3,
                PRIORITY: 3,
                MOVE_TYPE: Type.Air,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m03",
                EFFECT: IEffect(address(0))
            })
        );
        MonStats memory stats = MonStats({
            hp: 0,
            stamina: 0,
            speed: 0,
            attack: 0,
            defense: 0,
            specialAttack: 0,
            specialDefense: 0,
            type1: Type.Air,
            type2: Type.None
        });
        bytes32[] memory keys = new bytes32[](1);
        bytes32[] memory values = new bytes32[](1);
        keys[0] = bytes32("name");
        values[0] = bytes32("m0");

        vm.startPrank(ALICE);
        monRegistry.createMon(0, stats, moves0, abilities, keys, values);

        IMoveSet[] memory moves1 = new IMoveSet[](4);
        moves1[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 0,
                PRIORITY: 0,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m10",
                EFFECT: IEffect(address(0))
            })
        );
        moves1[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 1,
                PRIORITY: 1,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m11",
                EFFECT: IEffect(address(0))
            })
        );
        moves1[2] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 2,
                STAMINA_COST: 2,
                ACCURACY: 2,
                PRIORITY: 2,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m12",
                EFFECT: IEffect(address(0))
            })
        );
        moves1[3] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3,
                STAMINA_COST: 3,
                ACCURACY: 3,
                PRIORITY: 3,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m13",
                EFFECT: IEffect(address(0))
            })
        );
        stats = MonStats({
            hp: 0,
            stamina: 0,
            speed: 0,
            attack: 0,
            defense: 0,
            specialAttack: 0,
            specialDefense: 0,
            type1: Type.Cosmic,
            type2: Type.None
        });
        values[0] = bytes32("m1");
        monRegistry.createMon(1, stats, moves1, abilities, keys, values);

        IMoveSet[] memory moves2 = new IMoveSet[](4);
        moves2[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 0,
                PRIORITY: 0,
                MOVE_TYPE: Type.Cyber,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m20",
                EFFECT: IEffect(address(0))
            })
        );
        moves2[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 1,
                PRIORITY: 1,
                MOVE_TYPE: Type.Cyber,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m21",
                EFFECT: IEffect(address(0))
            })
        );
        moves2[2] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 2,
                STAMINA_COST: 2,
                ACCURACY: 2,
                PRIORITY: 2,
                MOVE_TYPE: Type.Cyber,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m22",
                EFFECT: IEffect(address(0))
            })
        );
        moves2[3] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3,
                STAMINA_COST: 3,
                ACCURACY: 3,
                PRIORITY: 3,
                MOVE_TYPE: Type.Cyber,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m23",
                EFFECT: IEffect(address(0))
            })
        );
        stats = MonStats({
            hp: 0,
            stamina: 0,
            speed: 0,
            attack: 0,
            defense: 0,
            specialAttack: 0,
            specialDefense: 0,
            type1: Type.Cyber,
            type2: Type.None
        });
        values[0] = bytes32("m2");
        monRegistry.createMon(2, stats, moves2, abilities, keys, values);

        IMoveSet[] memory moves3 = new IMoveSet[](4);
        moves3[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 0,
                PRIORITY: 0,
                MOVE_TYPE: Type.Earth,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m30",
                EFFECT: IEffect(address(0))
            })
        );
        moves3[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 1,
                PRIORITY: 1,
                MOVE_TYPE: Type.Earth,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m31",
                EFFECT: IEffect(address(0))
            })
        );
        moves3[2] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 2,
                STAMINA_COST: 2,
                ACCURACY: 2,
                PRIORITY: 2,
                MOVE_TYPE: Type.Earth,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m32",
                EFFECT: IEffect(address(0))
            })
        );
        moves3[3] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3,
                STAMINA_COST: 3,
                ACCURACY: 3,
                PRIORITY: 3,
                MOVE_TYPE: Type.Earth,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m33",
                EFFECT: IEffect(address(0))
            })
        );
        stats = MonStats({
            hp: 0,
            stamina: 0,
            speed: 0,
            attack: 0,
            defense: 0,
            specialAttack: 0,
            specialDefense: 0,
            type1: Type.Earth,
            type2: Type.None
        });
        values[0] = bytes32("m3");
        monRegistry.createMon(3, stats, moves3, abilities, keys, values);

        IMoveSet[] memory moves4 = new IMoveSet[](4);
        moves4[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 0,
                PRIORITY: 0,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m40",
                EFFECT: IEffect(address(0))
            })
        );
        moves4[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 1,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m41",
                EFFECT: IEffect(address(0))
            })
        );
        moves4[2] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 2,
                STAMINA_COST: 2,
                ACCURACY: 2,
                PRIORITY: 2,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m42",
                EFFECT: IEffect(address(0))
            })
        );
        moves4[3] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3,
                STAMINA_COST: 3,
                ACCURACY: 3,
                PRIORITY: 3,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m43",
                EFFECT: IEffect(address(0))
            })
        );
        stats = MonStats({
            hp: 0,
            stamina: 0,
            speed: 0,
            attack: 0,
            defense: 0,
            specialAttack: 0,
            specialDefense: 0,
            type1: Type.Fire,
            type2: Type.None
        });
        values[0] = bytes32("m4");
        monRegistry.createMon(4, stats, moves4, abilities, keys, values);

        IMoveSet[] memory moves5 = new IMoveSet[](4);
        moves5[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 0,
                PRIORITY: 0,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m50",
                EFFECT: IEffect(address(0))
            })
        );
        moves5[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 1,
                PRIORITY: 1,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m51",
                EFFECT: IEffect(address(0))
            })
        );
        moves5[2] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 2,
                STAMINA_COST: 2,
                ACCURACY: 2,
                PRIORITY: 2,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m52",
                EFFECT: IEffect(address(0))
            })
        );
        moves5[3] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3,
                STAMINA_COST: 3,
                ACCURACY: 3,
                PRIORITY: 3,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m53",
                EFFECT: IEffect(address(0))
            })
        );
        stats = MonStats({
            hp: 0,
            stamina: 0,
            speed: 0,
            attack: 0,
            defense: 0,
            specialAttack: 0,
            specialDefense: 0,
            type1: Type.Ice,
            type2: Type.None
        });
        values[0] = bytes32("m5");
        monRegistry.createMon(5, stats, moves5, abilities, keys, values);

        DefaultTeamRegistry teamRegistry2 = new DefaultTeamRegistry(
            DefaultTeamRegistry.Args({REGISTRY: monRegistry, MONS_PER_TEAM: 6, MOVES_PER_MON: 4})
        );
        uint256[] memory monIndices = new uint256[](6);
        monIndices[0] = 0;
        monIndices[1] = 1;
        monIndices[2] = 2;
        monIndices[3] = 3;
        monIndices[4] = 4;
        monIndices[5] = 5;
        IMoveSet[4][] memory moves = new IMoveSet[4][](6);
        for (uint256 j = 0; j < 4; j++) {
            moves[0][j] = moves0[j];
            moves[1][j] = moves1[j];
            moves[2][j] = moves2[j];
            moves[3][j] = moves3[j];
            moves[4][j] = moves4[j];
            moves[5][j] = moves5[j];
        }
        IAbility[] memory allAbilities = new IAbility[](6);
        allAbilities[0] = ability;
        allAbilities[1] = ability;
        allAbilities[2] = ability;
        allAbilities[3] = ability;
        allAbilities[4] = ability;
        allAbilities[5] = ability;
        teamRegistry2.createTeam(monIndices, moves, allAbilities);
    }
}
