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
import {NineNineNine} from "../src/mons/ekineki/NineNineNine.sol";
import {BubbleBop} from "../src/mons/ekineki/BubbleBop.sol";
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
        uint256 contractIndex = 0;

        EternalGrudge eternalgrudge = new EternalGrudge(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Eternal Grudge",
            contractAddress: address(eternalgrudge)
        });
        contractIndex++;

        InfernalFlame infernalflame = new InfernalFlame(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("BURN_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Infernal Flame",
            contractAddress: address(infernalflame)
        });
        contractIndex++;

        WitherAway witheraway = new WitherAway(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("PANIC_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Wither Away",
            contractAddress: address(witheraway)
        });
        contractIndex++;

        Osteoporosis osteoporosis = new Osteoporosis(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Osteoporosis",
            contractAddress: address(osteoporosis)
        });
        contractIndex++;

        RiseFromTheGrave risefromthegrave = new RiseFromTheGrave(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Rise From The Grave",
            contractAddress: address(risefromthegrave)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(eternalgrudge));
        moves[1] = IMoveSet(address(infernalflame));
        moves[2] = IMoveSet(address(witheraway));
        moves[3] = IMoveSet(address(osteoporosis));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(risefromthegrave));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(0, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployInutia(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        ChainExpansion chainexpansion = new ChainExpansion(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Chain Expansion",
            contractAddress: address(chainexpansion)
        });
        contractIndex++;

        Initialize initialize = new Initialize(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Initialize",
            contractAddress: address(initialize)
        });
        contractIndex++;

        BigBite bigbite = new BigBite(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Big Bite",
            contractAddress: address(bigbite)
        });
        contractIndex++;

        HitAndDip hitanddip = new HitAndDip(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Hit And Dip",
            contractAddress: address(hitanddip)
        });
        contractIndex++;

        Interweaving interweaving = new Interweaving(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Interweaving",
            contractAddress: address(interweaving)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(chainexpansion));
        moves[1] = IMoveSet(address(initialize));
        moves[2] = IMoveSet(address(bigbite));
        moves[3] = IMoveSet(address(hitanddip));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(interweaving));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(1, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployMalalien(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        TripleThink triplethink = new TripleThink(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Triple Think",
            contractAddress: address(triplethink)
        });
        contractIndex++;

        FederalInvestigation federalinvestigation = new FederalInvestigation(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Federal Investigation",
            contractAddress: address(federalinvestigation)
        });
        contractIndex++;

        NegativeThoughts negativethoughts = new NegativeThoughts(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("PANIC_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Negative Thoughts",
            contractAddress: address(negativethoughts)
        });
        contractIndex++;

        InfiniteLove infinitelove = new InfiniteLove(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("SLEEP_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Infinite Love",
            contractAddress: address(infinitelove)
        });
        contractIndex++;

        ActusReus actusreus = new ActusReus(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Actus Reus",
            contractAddress: address(actusreus)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(triplethink));
        moves[1] = IMoveSet(address(federalinvestigation));
        moves[2] = IMoveSet(address(negativethoughts));
        moves[3] = IMoveSet(address(infinitelove));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(actusreus));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(2, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployIblivion(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        Baselight baselight = new Baselight(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Baselight",
            contractAddress: address(baselight)
        });
        contractIndex++;

        UnboundedStrike unboundedstrike = new UnboundedStrike(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), Baselight(address(baselight)));
        deployedContracts[contractIndex] = DeployData({
            name: "Unbounded Strike",
            contractAddress: address(unboundedstrike)
        });
        contractIndex++;

        Loop loop = new Loop(IEngine(vm.envAddress("ENGINE")), Baselight(address(baselight)), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Loop",
            contractAddress: address(loop)
        });
        contractIndex++;

        Brightback brightback = new Brightback(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), Baselight(address(baselight)));
        deployedContracts[contractIndex] = DeployData({
            name: "Brightback",
            contractAddress: address(brightback)
        });
        contractIndex++;

        Renormalize renormalize = new Renormalize(IEngine(vm.envAddress("ENGINE")), Baselight(address(baselight)), StatBoosts(vm.envAddress("STAT_BOOSTS")), Loop(address(loop)));
        deployedContracts[contractIndex] = DeployData({
            name: "Renormalize",
            contractAddress: address(renormalize)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(unboundedstrike));
        moves[1] = IMoveSet(address(loop));
        moves[2] = IMoveSet(address(brightback));
        moves[3] = IMoveSet(address(renormalize));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(baselight));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(3, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployGorillax(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        RockPull rockpull = new RockPull(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Rock Pull",
            contractAddress: address(rockpull)
        });
        contractIndex++;

        PoundGround poundground = new PoundGround(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Pound Ground",
            contractAddress: address(poundground)
        });
        contractIndex++;

        Blow blow = new Blow(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Blow",
            contractAddress: address(blow)
        });
        contractIndex++;

        ThrowPebble throwpebble = new ThrowPebble(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Throw Pebble",
            contractAddress: address(throwpebble)
        });
        contractIndex++;

        Angery angery = new Angery(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Angery",
            contractAddress: address(angery)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(rockpull));
        moves[1] = IMoveSet(address(poundground));
        moves[2] = IMoveSet(address(blow));
        moves[3] = IMoveSet(address(throwpebble));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(angery));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(4, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deploySofabbi(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        Gachachacha gachachacha = new Gachachacha(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Gachachacha",
            contractAddress: address(gachachacha)
        });
        contractIndex++;

        GuestFeature guestfeature = new GuestFeature(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Guest Feature",
            contractAddress: address(guestfeature)
        });
        contractIndex++;

        UnexpectedCarrot unexpectedcarrot = new UnexpectedCarrot(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Unexpected Carrot",
            contractAddress: address(unexpectedcarrot)
        });
        contractIndex++;

        SnackBreak snackbreak = new SnackBreak(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Snack Break",
            contractAddress: address(snackbreak)
        });
        contractIndex++;

        CarrotHarvest carrotharvest = new CarrotHarvest(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Carrot Harvest",
            contractAddress: address(carrotharvest)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(gachachacha));
        moves[1] = IMoveSet(address(guestfeature));
        moves[2] = IMoveSet(address(unexpectedcarrot));
        moves[3] = IMoveSet(address(snackbreak));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(carrotharvest));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(5, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployPengym(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        ChillOut chillout = new ChillOut(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("FROSTBITE_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Chill Out",
            contractAddress: address(chillout)
        });
        contractIndex++;

        Deadlift deadlift = new Deadlift(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Deadlift",
            contractAddress: address(deadlift)
        });
        contractIndex++;

        DeepFreeze deepfreeze = new DeepFreeze(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("FROSTBITE_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Deep Freeze",
            contractAddress: address(deepfreeze)
        });
        contractIndex++;

        PistolSquat pistolsquat = new PistolSquat(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Pistol Squat",
            contractAddress: address(pistolsquat)
        });
        contractIndex++;

        PostWorkout postworkout = new PostWorkout(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Post-Workout",
            contractAddress: address(postworkout)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(chillout));
        moves[1] = IMoveSet(address(deadlift));
        moves[2] = IMoveSet(address(deepfreeze));
        moves[3] = IMoveSet(address(pistolsquat));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(postworkout));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(6, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployEmbursa(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        HoneyBribe honeybribe = new HoneyBribe(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Honey Bribe",
            contractAddress: address(honeybribe)
        });
        contractIndex++;

        SetAblaze setablaze = new SetAblaze(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("BURN_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Set Ablaze",
            contractAddress: address(setablaze)
        });
        contractIndex++;

        HeatBeacon heatbeacon = new HeatBeacon(IEngine(vm.envAddress("ENGINE")), IEffect(vm.envAddress("BURN_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Heat Beacon",
            contractAddress: address(heatbeacon)
        });
        contractIndex++;

        Q5 q5 = new Q5(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Q5",
            contractAddress: address(q5)
        });
        contractIndex++;

        Tinderclaws tinderclaws = new Tinderclaws(IEngine(vm.envAddress("ENGINE")), IEffect(vm.envAddress("BURN_STATUS")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Tinderclaws",
            contractAddress: address(tinderclaws)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(honeybribe));
        moves[1] = IMoveSet(address(setablaze));
        moves[2] = IMoveSet(address(heatbeacon));
        moves[3] = IMoveSet(address(q5));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(tinderclaws));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(7, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployVolthare(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        Electrocute electrocute = new Electrocute(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("ZAP_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Electrocute",
            contractAddress: address(electrocute)
        });
        contractIndex++;

        RoundTrip roundtrip = new RoundTrip(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Round Trip",
            contractAddress: address(roundtrip)
        });
        contractIndex++;

        MegaStarBlast megastarblast = new MegaStarBlast(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("ZAP_STATUS")), IEffect(vm.envAddress("OVERCLOCK")));
        deployedContracts[contractIndex] = DeployData({
            name: "Mega Star Blast",
            contractAddress: address(megastarblast)
        });
        contractIndex++;

        DualShock dualshock = new DualShock(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("ZAP_STATUS")), Overclock(vm.envAddress("OVERCLOCK")));
        deployedContracts[contractIndex] = DeployData({
            name: "Dual Shock",
            contractAddress: address(dualshock)
        });
        contractIndex++;

        PreemptiveShock preemptiveshock = new PreemptiveShock(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Preemptive Shock",
            contractAddress: address(preemptiveshock)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(electrocute));
        moves[1] = IMoveSet(address(roundtrip));
        moves[2] = IMoveSet(address(megastarblast));
        moves[3] = IMoveSet(address(dualshock));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(preemptiveshock));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(8, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployAurox(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        VolatilePunch volatilepunch = new VolatilePunch(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("BURN_STATUS")), IEffect(vm.envAddress("FROSTBITE_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Volatile Punch",
            contractAddress: address(volatilepunch)
        });
        contractIndex++;

        GildedRecovery gildedrecovery = new GildedRecovery(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Gilded Recovery",
            contractAddress: address(gildedrecovery)
        });
        contractIndex++;

        IronWall ironwall = new IronWall(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Iron Wall",
            contractAddress: address(ironwall)
        });
        contractIndex++;

        BullRush bullrush = new BullRush(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Bull Rush",
            contractAddress: address(bullrush)
        });
        contractIndex++;

        UpOnly uponly = new UpOnly(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Up Only",
            contractAddress: address(uponly)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(volatilepunch));
        moves[1] = IMoveSet(address(gildedrecovery));
        moves[2] = IMoveSet(address(ironwall));
        moves[3] = IMoveSet(address(bullrush));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(uponly));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(9, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployXmon(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        ContagiousSlumber contagiousslumber = new ContagiousSlumber(IEngine(vm.envAddress("ENGINE")), IEffect(vm.envAddress("SLEEP_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Contagious Slumber",
            contractAddress: address(contagiousslumber)
        });
        contractIndex++;

        VitalSiphon vitalsiphon = new VitalSiphon(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Vital Siphon",
            contractAddress: address(vitalsiphon)
        });
        contractIndex++;

        Somniphobia somniphobia = new Somniphobia(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Somniphobia",
            contractAddress: address(somniphobia)
        });
        contractIndex++;

        NightTerrors nightterrors = new NightTerrors(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")), IEffect(vm.envAddress("SLEEP_STATUS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Night Terrors",
            contractAddress: address(nightterrors)
        });
        contractIndex++;

        Dreamcatcher dreamcatcher = new Dreamcatcher(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "Dreamcatcher",
            contractAddress: address(dreamcatcher)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(contagiousslumber));
        moves[1] = IMoveSet(address(vitalsiphon));
        moves[2] = IMoveSet(address(somniphobia));
        moves[3] = IMoveSet(address(nightterrors));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(dreamcatcher));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(10, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

    function deployEkineki(DefaultMonRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);
        uint256 contractIndex = 0;

        BubbleBop bubblebop = new BubbleBop(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Bubble Bop",
            contractAddress: address(bubblebop)
        });
        contractIndex++;

        SneakAttack sneakattack = new SneakAttack(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Sneak Attack",
            contractAddress: address(sneakattack)
        });
        contractIndex++;

        NineNineNine nineNineNine = new NineNineNine(IEngine(vm.envAddress("ENGINE")));
        deployedContracts[contractIndex] = DeployData({
            name: "999",
            contractAddress: address(nineNineNine)
        });
        contractIndex++;

        Overflow overflow = new Overflow(IEngine(vm.envAddress("ENGINE")), ITypeCalculator(vm.envAddress("TYPE_CALCULATOR")));
        deployedContracts[contractIndex] = DeployData({
            name: "Overflow",
            contractAddress: address(overflow)
        });
        contractIndex++;

        SaviorComplex saviorcomplex = new SaviorComplex(IEngine(vm.envAddress("ENGINE")), StatBoosts(vm.envAddress("STAT_BOOSTS")));
        deployedContracts[contractIndex] = DeployData({
            name: "Savior Complex",
            contractAddress: address(saviorcomplex)
        });
        contractIndex++;

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
        moves[0] = IMoveSet(address(bubblebop));
        moves[1] = IMoveSet(address(sneakattack));
        moves[2] = IMoveSet(address(nineNineNine));
        moves[3] = IMoveSet(address(overflow));
        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(address(saviorcomplex));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(11, stats, moves, abilities, keys, values);

        return deployedContracts;
    }

}