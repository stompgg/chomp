// SPDX-License-Identifier: AGPL-3.0
// Created by mon_stats_to_sol.py
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {MonStats} from "../src/Structs.sol";
import {Type} from "../src/Enums.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IAbility} from "../src/abilities/IAbility.sol";

import {IEngine} from "../src/IEngine.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {BullRush} from "../src/mons/aurox/BullRush.sol";
import {GildedRecovery} from "../src/mons/aurox/GildedRecovery.sol";
import {IronWall} from "../src/mons/aurox/IronWall.sol";
import {UpOnly} from "../src/mons/aurox/UpOnly.sol";
import {VolatilePunch} from "../src/mons/aurox/VolatilePunch.sol";
import {BubbleBop} from "../src/mons/ekineki/BubbleBop.sol";
import {NineNineNine} from "../src/mons/ekineki/NineNineNine.sol";
import {Overflow} from "../src/mons/ekineki/Overflow.sol";
import {SaviorComplex} from "../src/mons/ekineki/SaviorComplex.sol";
import {SneakAttack} from "../src/mons/ekineki/SneakAttack.sol";
import {HeatBeacon} from "../src/mons/embursa/HeatBeacon.sol";
import {HoneyBribe} from "../src/mons/embursa/HoneyBribe.sol";
import {Q5} from "../src/mons/embursa/Q5.sol";
import {SetAblaze} from "../src/mons/embursa/SetAblaze.sol";
import {Tinderclaws} from "../src/mons/embursa/Tinderclaws.sol";
import {EternalGrudge} from "../src/mons/ghouliath/EternalGrudge.sol";
import {InfernalFlame} from "../src/mons/ghouliath/InfernalFlame.sol";
import {Osteoporosis} from "../src/mons/ghouliath/Osteoporosis.sol";
import {RiseFromTheGrave} from "../src/mons/ghouliath/RiseFromTheGrave.sol";
import {WitherAway} from "../src/mons/ghouliath/WitherAway.sol";
import {Angery} from "../src/mons/gorillax/Angery.sol";
import {Blow} from "../src/mons/gorillax/Blow.sol";
import {PoundGround} from "../src/mons/gorillax/PoundGround.sol";
import {RockPull} from "../src/mons/gorillax/RockPull.sol";
import {ThrowPebble} from "../src/mons/gorillax/ThrowPebble.sol";
import {Baselight} from "../src/mons/iblivion/Baselight.sol";
import {Brightback} from "../src/mons/iblivion/Brightback.sol";
import {Loop} from "../src/mons/iblivion/Loop.sol";
import {Renormalize} from "../src/mons/iblivion/Renormalize.sol";
import {UnboundedStrike} from "../src/mons/iblivion/UnboundedStrike.sol";
import {BigBite} from "../src/mons/inutia/BigBite.sol";
import {ChainExpansion} from "../src/mons/inutia/ChainExpansion.sol";
import {HitAndDip} from "../src/mons/inutia/HitAndDip.sol";
import {Initialize} from "../src/mons/inutia/Initialize.sol";
import {Interweaving} from "../src/mons/inutia/Interweaving.sol";
import {ActusReus} from "../src/mons/malalien/ActusReus.sol";
import {FederalInvestigation} from "../src/mons/malalien/FederalInvestigation.sol";
import {InfiniteLove} from "../src/mons/malalien/InfiniteLove.sol";
import {NegativeThoughts} from "../src/mons/malalien/NegativeThoughts.sol";
import {TripleThink} from "../src/mons/malalien/TripleThink.sol";
import {ChillOut} from "../src/mons/pengym/ChillOut.sol";
import {Deadlift} from "../src/mons/pengym/Deadlift.sol";
import {DeepFreeze} from "../src/mons/pengym/DeepFreeze.sol";
import {PistolSquat} from "../src/mons/pengym/PistolSquat.sol";
import {PostWorkout} from "../src/mons/pengym/PostWorkout.sol";
import {CarrotHarvest} from "../src/mons/sofabbi/CarrotHarvest.sol";
import {Gachachacha} from "../src/mons/sofabbi/Gachachacha.sol";
import {GuestFeature} from "../src/mons/sofabbi/GuestFeature.sol";
import {SnackBreak} from "../src/mons/sofabbi/SnackBreak.sol";
import {UnexpectedCarrot} from "../src/mons/sofabbi/UnexpectedCarrot.sol";
import {DualShock} from "../src/mons/volthare/DualShock.sol";
import {Electrocute} from "../src/mons/volthare/Electrocute.sol";
import {MegaStarBlast} from "../src/mons/volthare/MegaStarBlast.sol";
import {PreemptiveShock} from "../src/mons/volthare/PreemptiveShock.sol";
import {RoundTrip} from "../src/mons/volthare/RoundTrip.sol";
import {ContagiousSlumber} from "../src/mons/xmon/ContagiousSlumber.sol";
import {Dreamcatcher} from "../src/mons/xmon/Dreamcatcher.sol";
import {NightTerrors} from "../src/mons/xmon/NightTerrors.sol";
import {Somniphobia} from "../src/mons/xmon/Somniphobia.sol";
import {VitalSiphon} from "../src/mons/xmon/VitalSiphon.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

struct DeployData {
    string name;
    address contractAddress;
}
contract SetupMons is Script {
    function run() external returns (DeployData[] memory deployedContracts) {
        vm.startBroadcast();

        // Get the DefaultMonRegistry address
        DefaultMonRegistry registry = DefaultMonRegistry(vm.envAddress("DEFAULT_MON_REGISTRY"));

        // Deploy all mons and collect deployment data
        DeployData[][] memory allDeployData = new DeployData[][](12);

        allDeployData[0] = deployGhouliath(registry);
        allDeployData[1] = deployInutia(registry);
        allDeployData[2] = deployMalalien(registry);
        allDeployData[3] = deployIblivion(registry);
        allDeployData[4] = deployGorillax(registry);
        allDeployData[5] = deploySofabbi(registry);
        allDeployData[6] = deployPengym(registry);
        allDeployData[7] = deployEmbursa(registry);
        allDeployData[8] = deployVolthare(registry);
        allDeployData[9] = deployAurox(registry);
        allDeployData[10] = deployXmon(registry);
        allDeployData[11] = deployEkineki(registry);

        // Calculate total length for flattened array
        uint256 totalLength = 0;
        for (uint256 i = 0; i < allDeployData.length; i++) {
            totalLength += allDeployData[i].length;
        }

        // Create flattened array and copy all entries
        deployedContracts = new DeployData[](totalLength);
        uint256 currentIndex = 0;

        // Copy all deployment data using nested loops
        for (uint256 i = 0; i < allDeployData.length; i++) {
            for (uint256 j = 0; j < allDeployData[i].length; j++) {
                deployedContracts[currentIndex] = allDeployData[i][j];
                currentIndex++;
            }
        }

        vm.stopBroadcast();
    }

    function deployGhouliath(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new EternalGrudge(IEngine(engine), StatBoosts(vm.envAddress("STAT_BOOSTS"))));
            deployedContracts[0] = DeployData({name: "Eternal Grudge", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new InfernalFlame(IEngine(engine), ITypeCalculator(typecalculator), IEffect(vm.envAddress("BURN_STATUS"))));
            deployedContracts[1] = DeployData({name: "Infernal Flame", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new WitherAway(IEngine(engine), ITypeCalculator(typecalculator), IEffect(vm.envAddress("PANIC_STATUS"))));
            deployedContracts[2] = DeployData({name: "Wither Away", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Osteoporosis(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Osteoporosis", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new RiseFromTheGrave(IEngine(engine)));
            deployedContracts[4] = DeployData({name: "Rise From The Grave", contractAddress: addrs[4]});
        }

        _registerGhouliath(registry, addrs);

        return deployedContracts;
    }

    function _registerGhouliath(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 303,
            stamina: 5,
            speed: 181,
            attack: 157,
            defense: 202,
            specialAttack: 151,
            specialDefense: 202,
            type1: Type.Yin,
            type2: Type.Fire
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(0, stats, moves, abilities, keys, values);
    }

    function deployInutia(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address statboosts = vm.envAddress("STAT_BOOSTS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new ChainExpansion(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Chain Expansion", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new Initialize(IEngine(engine), StatBoosts(statboosts)));
            deployedContracts[1] = DeployData({name: "Initialize", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new BigBite(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[2] = DeployData({name: "Big Bite", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new HitAndDip(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Hit And Dip", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Interweaving(IEngine(engine), StatBoosts(statboosts)));
            deployedContracts[4] = DeployData({name: "Interweaving", contractAddress: addrs[4]});
        }

        _registerInutia(registry, addrs);

        return deployedContracts;
    }

    function _registerInutia(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 351,
            stamina: 5,
            speed: 229,
            attack: 171,
            defense: 189,
            specialAttack: 175,
            specialDefense: 192,
            type1: Type.Wild,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(1, stats, moves, abilities, keys, values);
    }

    function deployMalalien(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address statboosts = vm.envAddress("STAT_BOOSTS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new TripleThink(IEngine(engine), StatBoosts(statboosts)));
            deployedContracts[0] = DeployData({name: "Triple Think", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new FederalInvestigation(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Federal Investigation", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new NegativeThoughts(IEngine(engine), ITypeCalculator(typecalculator), IEffect(vm.envAddress("PANIC_STATUS"))));
            deployedContracts[2] = DeployData({name: "Negative Thoughts", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new InfiniteLove(IEngine(engine), ITypeCalculator(typecalculator), IEffect(vm.envAddress("SLEEP_STATUS"))));
            deployedContracts[3] = DeployData({name: "Infinite Love", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new ActusReus(IEngine(engine), StatBoosts(statboosts)));
            deployedContracts[4] = DeployData({name: "Actus Reus", contractAddress: addrs[4]});
        }

        _registerMalalien(registry, addrs);

        return deployedContracts;
    }

    function _registerMalalien(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 258,
            stamina: 5,
            speed: 308,
            attack: 121,
            defense: 125,
            specialAttack: 322,
            specialDefense: 151,
            type1: Type.Cyber,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(2, stats, moves, abilities, keys, values);
    }

    function deployIblivion(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address statboosts = vm.envAddress("STAT_BOOSTS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new Baselight(IEngine(engine)));
            deployedContracts[0] = DeployData({name: "Baselight", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new UnboundedStrike(IEngine(engine), ITypeCalculator(typecalculator), Baselight(addrs[0])));
            deployedContracts[1] = DeployData({name: "Unbounded Strike", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new Loop(IEngine(engine), Baselight(addrs[0]), StatBoosts(statboosts)));
            deployedContracts[2] = DeployData({name: "Loop", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Brightback(IEngine(engine), ITypeCalculator(typecalculator), Baselight(addrs[0])));
            deployedContracts[3] = DeployData({name: "Brightback", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Renormalize(IEngine(engine), Baselight(addrs[0]), StatBoosts(statboosts), Loop(addrs[2])));
            deployedContracts[4] = DeployData({name: "Renormalize", contractAddress: addrs[4]});
        }

        _registerIblivion(registry, addrs);

        return deployedContracts;
    }

    function _registerIblivion(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 277,
            stamina: 5,
            speed: 256,
            attack: 188,
            defense: 164,
            specialAttack: 240,
            specialDefense: 168,
            type1: Type.Yang,
            type2: Type.Air
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[1]);
        moves[1] = IMoveSet(addrs[2]);
        moves[2] = IMoveSet(addrs[3]);
        moves[3] = IMoveSet(addrs[4]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[0]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(3, stats, moves, abilities, keys, values);
    }

    function deployGorillax(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new RockPull(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Rock Pull", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new PoundGround(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Pound Ground", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new Blow(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[2] = DeployData({name: "Blow", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new ThrowPebble(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Throw Pebble", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Angery(IEngine(engine)));
            deployedContracts[4] = DeployData({name: "Angery", contractAddress: addrs[4]});
        }

        _registerGorillax(registry, addrs);

        return deployedContracts;
    }

    function _registerGorillax(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 407,
            stamina: 5,
            speed: 129,
            attack: 302,
            defense: 175,
            specialAttack: 112,
            specialDefense: 176,
            type1: Type.Earth,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(4, stats, moves, abilities, keys, values);
    }

    function deploySofabbi(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new Gachachacha(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Gachachacha", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new GuestFeature(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Guest Feature", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new UnexpectedCarrot(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[2] = DeployData({name: "Unexpected Carrot", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new SnackBreak(IEngine(engine)));
            deployedContracts[3] = DeployData({name: "Snack Break", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new CarrotHarvest(IEngine(engine)));
            deployedContracts[4] = DeployData({name: "Carrot Harvest", contractAddress: addrs[4]});
        }

        _registerSofabbi(registry, addrs);

        return deployedContracts;
    }

    function _registerSofabbi(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 333,
            stamina: 5,
            speed: 175,
            attack: 180,
            defense: 201,
            specialAttack: 120,
            specialDefense: 269,
            type1: Type.Nature,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(5, stats, moves, abilities, keys, values);
    }

    function deployPengym(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address frostbitestatus = vm.envAddress("FROSTBITE_STATUS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new ChillOut(IEngine(engine), ITypeCalculator(typecalculator), IEffect(frostbitestatus)));
            deployedContracts[0] = DeployData({name: "Chill Out", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new Deadlift(IEngine(engine), StatBoosts(vm.envAddress("STAT_BOOSTS"))));
            deployedContracts[1] = DeployData({name: "Deadlift", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new DeepFreeze(IEngine(engine), ITypeCalculator(typecalculator), IEffect(frostbitestatus)));
            deployedContracts[2] = DeployData({name: "Deep Freeze", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new PistolSquat(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Pistol Squat", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new PostWorkout(IEngine(engine)));
            deployedContracts[4] = DeployData({name: "Post-Workout", contractAddress: addrs[4]});
        }

        _registerPengym(registry, addrs);

        return deployedContracts;
    }

    function _registerPengym(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 371,
            stamina: 5,
            speed: 149,
            attack: 212,
            defense: 191,
            specialAttack: 233,
            specialDefense: 172,
            type1: Type.Ice,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(6, stats, moves, abilities, keys, values);
    }

    function deployEmbursa(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address burnstatus = vm.envAddress("BURN_STATUS");
        address engine = vm.envAddress("ENGINE");
        address statboosts = vm.envAddress("STAT_BOOSTS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new HoneyBribe(IEngine(engine), StatBoosts(statboosts)));
            deployedContracts[0] = DeployData({name: "Honey Bribe", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new SetAblaze(IEngine(engine), ITypeCalculator(typecalculator), IEffect(burnstatus)));
            deployedContracts[1] = DeployData({name: "Set Ablaze", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new HeatBeacon(IEngine(engine), IEffect(burnstatus)));
            deployedContracts[2] = DeployData({name: "Heat Beacon", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Q5(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Q5", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Tinderclaws(IEngine(engine), IEffect(burnstatus), StatBoosts(statboosts)));
            deployedContracts[4] = DeployData({name: "Tinderclaws", contractAddress: addrs[4]});
        }

        _registerEmbursa(registry, addrs);

        return deployedContracts;
    }

    function _registerEmbursa(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 420,
            stamina: 5,
            speed: 111,
            attack: 141,
            defense: 220,
            specialAttack: 190,
            specialDefense: 161,
            type1: Type.Fire,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(7, stats, moves, abilities, keys, values);
    }

    function deployVolthare(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");
        address zapstatus = vm.envAddress("ZAP_STATUS");

        address[5] memory addrs;

        {
            addrs[0] = address(new Electrocute(IEngine(engine), ITypeCalculator(typecalculator), IEffect(zapstatus)));
            deployedContracts[0] = DeployData({name: "Electrocute", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new RoundTrip(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Round Trip", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new MegaStarBlast(IEngine(engine), ITypeCalculator(typecalculator), IEffect(zapstatus), IEffect(vm.envAddress("OVERCLOCK"))));
            deployedContracts[2] = DeployData({name: "Mega Star Blast", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new DualShock(IEngine(engine), ITypeCalculator(typecalculator), IEffect(zapstatus), Overclock(vm.envAddress("OVERCLOCK"))));
            deployedContracts[3] = DeployData({name: "Dual Shock", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new PreemptiveShock(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[4] = DeployData({name: "Preemptive Shock", contractAddress: addrs[4]});
        }

        _registerVolthare(registry, addrs);

        return deployedContracts;
    }

    function _registerVolthare(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 310,
            stamina: 5,
            speed: 311,
            attack: 120,
            defense: 184,
            specialAttack: 255,
            specialDefense: 176,
            type1: Type.Lightning,
            type2: Type.Cyber
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(8, stats, moves, abilities, keys, values);
    }

    function deployAurox(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new VolatilePunch(IEngine(engine), ITypeCalculator(typecalculator), IEffect(vm.envAddress("BURN_STATUS")), IEffect(vm.envAddress("FROSTBITE_STATUS"))));
            deployedContracts[0] = DeployData({name: "Volatile Punch", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new GildedRecovery(IEngine(engine)));
            deployedContracts[1] = DeployData({name: "Gilded Recovery", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new IronWall(IEngine(engine)));
            deployedContracts[2] = DeployData({name: "Iron Wall", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new BullRush(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Bull Rush", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new UpOnly(IEngine(engine), StatBoosts(vm.envAddress("STAT_BOOSTS"))));
            deployedContracts[4] = DeployData({name: "Up Only", contractAddress: addrs[4]});
        }

        _registerAurox(registry, addrs);

        return deployedContracts;
    }

    function _registerAurox(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 400,
            stamina: 5,
            speed: 100,
            attack: 150,
            defense: 230,
            specialAttack: 100,
            specialDefense: 220,
            type1: Type.Metal,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(9, stats, moves, abilities, keys, values);
    }

    function deployXmon(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address sleepstatus = vm.envAddress("SLEEP_STATUS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new ContagiousSlumber(IEngine(engine), IEffect(sleepstatus)));
            deployedContracts[0] = DeployData({name: "Contagious Slumber", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new VitalSiphon(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Vital Siphon", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new Somniphobia(IEngine(engine)));
            deployedContracts[2] = DeployData({name: "Somniphobia", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new NightTerrors(IEngine(engine), ITypeCalculator(typecalculator), IEffect(sleepstatus)));
            deployedContracts[3] = DeployData({name: "Night Terrors", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Dreamcatcher(IEngine(engine)));
            deployedContracts[4] = DeployData({name: "Dreamcatcher", contractAddress: addrs[4]});
        }

        _registerXmon(registry, addrs);

        return deployedContracts;
    }

    function _registerXmon(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 311,
            stamina: 5,
            speed: 285,
            attack: 123,
            defense: 179,
            specialAttack: 222,
            specialDefense: 185,
            type1: Type.Cosmic,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(10, stats, moves, abilities, keys, values);
    }

    function deployEkineki(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address engine = vm.envAddress("ENGINE");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new BubbleBop(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Bubble Bop", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new SneakAttack(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Sneak Attack", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new NineNineNine(IEngine(engine)));
            deployedContracts[2] = DeployData({name: "Nine Nine Nine", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Overflow(IEngine(engine), ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Overflow", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new SaviorComplex(IEngine(engine), StatBoosts(vm.envAddress("STAT_BOOSTS"))));
            deployedContracts[4] = DeployData({name: "Savior Complex", contractAddress: addrs[4]});
        }

        _registerEkineki(registry, addrs);

        return deployedContracts;
    }

    function _registerEkineki(DefaultMonRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 299,
            stamina: 5,
            speed: 266,
            attack: 130,
            defense: 180,
            specialAttack: 280,
            specialDefense: 175,
            type1: Type.Liquid,
            type2: Type.None
        });
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = IMoveSet(addrs[0]);
        moves[1] = IMoveSet(addrs[1]);
        moves[2] = IMoveSet(addrs[2]);
        moves[3] = IMoveSet(addrs[3]);
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(addrs[4]);
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(11, stats, moves, abilities, keys, values);
    }

}