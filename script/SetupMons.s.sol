// SPDX-License-Identifier: AGPL-3.0
// Created by mon_stats_to_sol.py
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {MonStats} from "../src/Structs.sol";
import {Type} from "../src/Enums.sol";

import {IEffect} from "../src/effects/IEffect.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {BigBellow} from "../src/mons/aurox/BigBellow.sol";
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
import {GraveAffliction} from "../src/mons/ghouliath/GraveAffliction.sol";
import {InfernalFlame} from "../src/mons/ghouliath/InfernalFlame.sol";
import {RiseFromTheGrave} from "../src/mons/ghouliath/RiseFromTheGrave.sol";
import {WitherAway} from "../src/mons/ghouliath/WitherAway.sol";
import {Angery} from "../src/mons/gorillax/Angery.sol";
import {RockPull} from "../src/mons/gorillax/RockPull.sol";
import {Baselight} from "../src/mons/iblivion/Baselight.sol";
import {Brightback} from "../src/mons/iblivion/Brightback.sol";
import {Loop} from "../src/mons/iblivion/Loop.sol";
import {Renormalize} from "../src/mons/iblivion/Renormalize.sol";
import {UnboundedStrike} from "../src/mons/iblivion/UnboundedStrike.sol";
import {ChainExpansion} from "../src/mons/inutia/ChainExpansion.sol";
import {HitAndDip} from "../src/mons/inutia/HitAndDip.sol";
import {Initialize} from "../src/mons/inutia/Initialize.sol";
import {Interweaving} from "../src/mons/inutia/Interweaving.sol";
import {Sanctify} from "../src/mons/inutia/Sanctify.sol";
import {ActusReus} from "../src/mons/malalien/ActusReus.sol";
import {FoulLanguage} from "../src/mons/malalien/FoulLanguage.sol";
import {TripleThink} from "../src/mons/malalien/TripleThink.sol";
import {Adaptor} from "../src/mons/nirvamma/Adaptor.sol";
import {Chronoffense} from "../src/mons/nirvamma/Chronoffense.sol";
import {HardReset} from "../src/mons/nirvamma/HardReset.sol";
import {ModalBolt} from "../src/mons/nirvamma/ModalBolt.sol";
import {Deadlift} from "../src/mons/pengym/Deadlift.sol";
import {DeepFreeze} from "../src/mons/pengym/DeepFreeze.sol";
import {PistolSquat} from "../src/mons/pengym/PistolSquat.sol";
import {PostWorkout} from "../src/mons/pengym/PostWorkout.sol";
import {CarrotHarvest} from "../src/mons/sofabbi/CarrotHarvest.sol";
import {Gachachacha} from "../src/mons/sofabbi/Gachachacha.sol";
import {GuestFeature} from "../src/mons/sofabbi/GuestFeature.sol";
import {SnackBreak} from "../src/mons/sofabbi/SnackBreak.sol";
import {DualShock} from "../src/mons/volthare/DualShock.sol";
import {MegaStarBlast} from "../src/mons/volthare/MegaStarBlast.sol";
import {PreemptiveShock} from "../src/mons/volthare/PreemptiveShock.sol";
import {Quickstorm} from "../src/mons/volthare/Quickstorm.sol";
import {RoundTrip} from "../src/mons/volthare/RoundTrip.sol";
import {ContagiousSlumber} from "../src/mons/xmon/ContagiousSlumber.sol";
import {Dreamcatcher} from "../src/mons/xmon/Dreamcatcher.sol";
import {InvokeTaboo} from "../src/mons/xmon/InvokeTaboo.sol";
import {OldVengeance} from "../src/mons/xmon/OldVengeance.sol";
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

        // Get the GachaTeamRegistry address
        GachaTeamRegistry registry = GachaTeamRegistry(vm.envAddress("GACHA_TEAM_REGISTRY"));

        // Deploy all mons and collect deployment data
        DeployData[][] memory allDeployData = new DeployData[][](13);

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
        allDeployData[12] = deployNirvamma(registry);

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

    function deployGhouliath(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new EternalGrudge());
            deployedContracts[0] = DeployData({name: "Eternal Grudge", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new InfernalFlame(ITypeCalculator(typecalculator), IEffect(vm.envAddress("BURN_STATUS"))));
            deployedContracts[1] = DeployData({name: "Infernal Flame", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new WitherAway(ITypeCalculator(typecalculator), IEffect(vm.envAddress("PANIC_STATUS"))));
            deployedContracts[2] = DeployData({name: "Wither Away", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new GraveAffliction());
            deployedContracts[3] = DeployData({name: "Grave Affliction", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new RiseFromTheGrave());
            deployedContracts[4] = DeployData({name: "Rise From The Grave", contractAddress: addrs[4]});
        }

        _registerGhouliath(registry, addrs);

        return deployedContracts;
    }

    function _registerGhouliath(GachaTeamRegistry registry, address[5] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](5);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = uint256(uint160(addrs[2]));
        moves[3] = 0x5a00200000000000000000000000000000000000000000000000000000000000;
        moves[4] = uint256(uint160(addrs[3]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(addrs[4]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(0, stats, moves, abilities, keys, values);
    }

    function deployInutia(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new ChainExpansion(ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Chain Expansion", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new Initialize());
            deployedContracts[1] = DeployData({name: "Initialize", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new HitAndDip(ITypeCalculator(typecalculator)));
            deployedContracts[2] = DeployData({name: "Hit And Dip", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Sanctify(IEffect(vm.envAddress("BLESSED_STATUS"))));
            deployedContracts[3] = DeployData({name: "Sanctify", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Interweaving());
            deployedContracts[4] = DeployData({name: "Interweaving", contractAddress: addrs[4]});
        }

        _registerInutia(registry, addrs);

        return deployedContracts;
    }

    function _registerInutia(GachaTeamRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 351,
            stamina: 5,
            speed: 229,
            attack: 171,
            defense: 189,
            specialAttack: 175,
            specialDefense: 192,
            type1: Type.Faith,
            type2: Type.None
        });
        uint256[] memory moves = new uint256[](5);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = 0x5009200000000000000000000000000000000000000000000000000000000000;
        moves[3] = uint256(uint160(addrs[2]));
        moves[4] = uint256(uint160(addrs[3]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(addrs[4]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(1, stats, moves, abilities, keys, values);
    }

    function deployMalalien(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](3);

        address[3] memory addrs;

        {
            addrs[0] = address(new TripleThink());
            deployedContracts[0] = DeployData({name: "Triple Think", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new FoulLanguage(ITypeCalculator(vm.envAddress("TYPE_CALCULATOR"))));
            deployedContracts[1] = DeployData({name: "Foul Language", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new ActusReus());
            deployedContracts[2] = DeployData({name: "Actus Reus", contractAddress: addrs[2]});
        }

        _registerMalalien(registry, addrs);

        return deployedContracts;
    }

    function _registerMalalien(GachaTeamRegistry registry, address[3] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](5);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = 0x644c300000000000000000000000000000000000000000000000000000000000;
        moves[2] = 0x504b30a000000000000000000000000000000000000000000000000000000000 | uint256(uint160(vm.envAddress("PANIC_STATUS")));
        moves[3] = 0x5a4d30a000000000000000000000000000000000000000000000000000000000 | uint256(uint160(vm.envAddress("SLEEP_STATUS")));
        moves[4] = uint256(uint160(addrs[1]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[2]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(2, stats, moves, abilities, keys, values);
    }

    function deployIblivion(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new Baselight());
            deployedContracts[0] = DeployData({name: "Baselight", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new UnboundedStrike(ITypeCalculator(typecalculator), Baselight(addrs[0])));
            deployedContracts[1] = DeployData({name: "Unbounded Strike", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new Loop(Baselight(addrs[0])));
            deployedContracts[2] = DeployData({name: "Loop", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Brightback(ITypeCalculator(typecalculator), Baselight(addrs[0])));
            deployedContracts[3] = DeployData({name: "Brightback", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Renormalize(Baselight(addrs[0]), Loop(addrs[2])));
            deployedContracts[4] = DeployData({name: "Renormalize", contractAddress: addrs[4]});
        }

        _registerIblivion(registry, addrs);

        return deployedContracts;
    }

    function _registerIblivion(GachaTeamRegistry registry, address[5] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 277,
            stamina: 5,
            speed: 256,
            attack: 199,
            defense: 164,
            specialAttack: 180,
            specialDefense: 168,
            type1: Type.Yang,
            type2: Type.Air
        });
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(addrs[1]));
        moves[1] = uint256(uint160(addrs[2]));
        moves[2] = uint256(uint160(addrs[3]));
        moves[3] = uint256(uint160(addrs[4]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(addrs[0]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(3, stats, moves, abilities, keys, values);
    }

    function deployGorillax(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](2);

        address[2] memory addrs;

        {
            addrs[0] = address(new RockPull(ITypeCalculator(vm.envAddress("TYPE_CALCULATOR"))));
            deployedContracts[0] = DeployData({name: "Rock Pull", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new Angery());
            deployedContracts[1] = DeployData({name: "Angery", contractAddress: addrs[1]});
        }

        _registerGorillax(registry, addrs);

        return deployedContracts;
    }

    function _registerGorillax(GachaTeamRegistry registry, address[2] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = 0x5f02300000000000000000000000000000000000000000000000000000000000;
        moves[2] = 0x460a200000000000000000000000000000000000000000000000000000000000;
        moves[3] = 0x2802100000000000000000000000000000000000000000000000000000000000;
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[1]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(4, stats, moves, abilities, keys, values);
    }

    function deploySofabbi(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](4);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[4] memory addrs;

        {
            addrs[0] = address(new Gachachacha(ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Gachachacha", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new GuestFeature(ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Guest Feature", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new SnackBreak());
            deployedContracts[2] = DeployData({name: "Snack Break", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new CarrotHarvest());
            deployedContracts[3] = DeployData({name: "Carrot Harvest", contractAddress: addrs[3]});
        }

        _registerSofabbi(registry, addrs);

        return deployedContracts;
    }

    function _registerSofabbi(GachaTeamRegistry registry, address[4] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = 0x7807400000000000000000000000000000000000000000000000000000000000;
        moves[3] = uint256(uint160(addrs[2]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[3]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(5, stats, moves, abilities, keys, values);
    }

    function deployPengym(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](4);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[4] memory addrs;

        {
            addrs[0] = address(new Deadlift());
            deployedContracts[0] = DeployData({name: "Deadlift", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new DeepFreeze(ITypeCalculator(typecalculator), IEffect(vm.envAddress("FROSTBITE_STATUS"))));
            deployedContracts[1] = DeployData({name: "Deep Freeze", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new PistolSquat(ITypeCalculator(typecalculator)));
            deployedContracts[2] = DeployData({name: "Pistol Squat", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new PostWorkout());
            deployedContracts[3] = DeployData({name: "Post-Workout", contractAddress: addrs[3]});
        }

        _registerPengym(registry, addrs);

        return deployedContracts;
    }

    function _registerPengym(GachaTeamRegistry registry, address[4] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](4);
        moves[0] = 0x00c6064000000000000000000000000000000000000000000000000000000000 | uint256(uint160(vm.envAddress("FROSTBITE_STATUS")));
        moves[1] = uint256(uint160(addrs[0]));
        moves[2] = uint256(uint160(addrs[1]));
        moves[3] = uint256(uint160(addrs[2]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[3]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(6, stats, moves, abilities, keys, values);
    }

    function deployEmbursa(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address burnstatus = vm.envAddress("BURN_STATUS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new HoneyBribe());
            deployedContracts[0] = DeployData({name: "Honey Bribe", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new SetAblaze(ITypeCalculator(typecalculator), IEffect(burnstatus)));
            deployedContracts[1] = DeployData({name: "Set Ablaze", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new HeatBeacon(IEffect(burnstatus)));
            deployedContracts[2] = DeployData({name: "Heat Beacon", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Q5(ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Q5", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new Tinderclaws(IEffect(burnstatus)));
            deployedContracts[4] = DeployData({name: "Tinderclaws", contractAddress: addrs[4]});
        }

        _registerEmbursa(registry, addrs);

        return deployedContracts;
    }

    function _registerEmbursa(GachaTeamRegistry registry, address[5] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = uint256(uint160(addrs[2]));
        moves[3] = uint256(uint160(addrs[3]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[4]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(7, stats, moves, abilities, keys, values);
    }

    function deployVolthare(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");
        address zapstatus = vm.envAddress("ZAP_STATUS");

        address[5] memory addrs;

        {
            addrs[0] = address(new RoundTrip(ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Round Trip", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new MegaStarBlast(ITypeCalculator(typecalculator), IEffect(zapstatus), IEffect(vm.envAddress("OVERCLOCK"))));
            deployedContracts[1] = DeployData({name: "Mega Star Blast", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new DualShock(ITypeCalculator(typecalculator), IEffect(zapstatus), Overclock(vm.envAddress("OVERCLOCK"))));
            deployedContracts[2] = DeployData({name: "Dual Shock", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Quickstorm(ITypeCalculator(typecalculator), IEffect(zapstatus)));
            deployedContracts[3] = DeployData({name: "Quickstorm", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new PreemptiveShock(ITypeCalculator(typecalculator)));
            deployedContracts[4] = DeployData({name: "Preemptive Shock", contractAddress: addrs[4]});
        }

        _registerVolthare(registry, addrs);

        return deployedContracts;
    }

    function _registerVolthare(GachaTeamRegistry registry, address[5] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](5);
        moves[0] = 0x5a4820a000000000000000000000000000000000000000000000000000000000 | uint256(uint160(vm.envAddress("ZAP_STATUS")));
        moves[1] = uint256(uint160(addrs[0]));
        moves[2] = uint256(uint160(addrs[1]));
        moves[3] = uint256(uint160(addrs[2]));
        moves[4] = uint256(uint160(addrs[3]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(addrs[4]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(8, stats, moves, abilities, keys, values);
    }

    function deployAurox(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](6);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[6] memory addrs;

        {
            addrs[0] = address(new VolatilePunch(ITypeCalculator(typecalculator), IEffect(vm.envAddress("BURN_STATUS")), IEffect(vm.envAddress("FROSTBITE_STATUS"))));
            deployedContracts[0] = DeployData({name: "Volatile Punch", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new GildedRecovery());
            deployedContracts[1] = DeployData({name: "Gilded Recovery", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new IronWall());
            deployedContracts[2] = DeployData({name: "Iron Wall", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new BullRush(ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Bull Rush", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new BigBellow());
            deployedContracts[4] = DeployData({name: "Big Bellow", contractAddress: addrs[4]});
        }
        {
            addrs[5] = address(new UpOnly());
            deployedContracts[5] = DeployData({name: "Up Only", contractAddress: addrs[5]});
        }

        _registerAurox(registry, addrs);

        return deployedContracts;
    }

    function _registerAurox(GachaTeamRegistry registry, address[6] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](5);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = uint256(uint160(addrs[2]));
        moves[3] = uint256(uint160(addrs[3]));
        moves[4] = uint256(uint160(addrs[4]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[5]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(9, stats, moves, abilities, keys, values);
    }

    function deployXmon(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](6);

        // Cache commonly used addresses
        address sleepstatus = vm.envAddress("SLEEP_STATUS");
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[6] memory addrs;

        {
            addrs[0] = address(new ContagiousSlumber(IEffect(sleepstatus)));
            deployedContracts[0] = DeployData({name: "Contagious Slumber", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new VitalSiphon(ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Vital Siphon", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new Somniphobia());
            deployedContracts[2] = DeployData({name: "Somniphobia", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new OldVengeance(ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Old Vengeance", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new InvokeTaboo(IEffect(sleepstatus)));
            deployedContracts[4] = DeployData({name: "Invoke Taboo", contractAddress: addrs[4]});
        }
        {
            addrs[5] = address(new Dreamcatcher());
            deployedContracts[5] = DeployData({name: "Dreamcatcher", contractAddress: addrs[5]});
        }

        _registerXmon(registry, addrs);

        return deployedContracts;
    }

    function _registerXmon(GachaTeamRegistry registry, address[6] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](5);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = uint256(uint160(addrs[2]));
        moves[3] = uint256(uint160(addrs[3]));
        moves[4] = uint256(uint160(addrs[4]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[5]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(10, stats, moves, abilities, keys, values);
    }

    function deployEkineki(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](5);

        // Cache commonly used addresses
        address typecalculator = vm.envAddress("TYPE_CALCULATOR");

        address[5] memory addrs;

        {
            addrs[0] = address(new BubbleBop(ITypeCalculator(typecalculator)));
            deployedContracts[0] = DeployData({name: "Bubble Bop", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new SneakAttack(ITypeCalculator(typecalculator)));
            deployedContracts[1] = DeployData({name: "Sneak Attack", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new NineNineNine());
            deployedContracts[2] = DeployData({name: "Nine Nine Nine", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Overflow(ITypeCalculator(typecalculator)));
            deployedContracts[3] = DeployData({name: "Overflow", contractAddress: addrs[3]});
        }
        {
            addrs[4] = address(new SaviorComplex());
            deployedContracts[4] = DeployData({name: "Savior Complex", contractAddress: addrs[4]});
        }

        _registerEkineki(registry, addrs);

        return deployedContracts;
    }

    function _registerEkineki(GachaTeamRegistry registry, address[5] memory addrs) internal {
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
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = uint256(uint160(addrs[1]));
        moves[2] = uint256(uint160(addrs[2]));
        moves[3] = uint256(uint160(addrs[3]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(addrs[4]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(11, stats, moves, abilities, keys, values);
    }

    function deployNirvamma(GachaTeamRegistry registry) internal returns (DeployData[] memory) {
        DeployData[] memory deployedContracts = new DeployData[](4);

        address[4] memory addrs;

        {
            addrs[0] = address(new HardReset());
            deployedContracts[0] = DeployData({name: "Hard Reset", contractAddress: addrs[0]});
        }
        {
            addrs[1] = address(new Chronoffense());
            deployedContracts[1] = DeployData({name: "Chronoffense", contractAddress: addrs[1]});
        }
        {
            addrs[2] = address(new ModalBolt(IEffect(vm.envAddress("BURN_STATUS")), IEffect(vm.envAddress("FROSTBITE_STATUS")), IEffect(vm.envAddress("ZAP_STATUS"))));
            deployedContracts[2] = DeployData({name: "Modal Bolt", contractAddress: addrs[2]});
        }
        {
            addrs[3] = address(new Adaptor());
            deployedContracts[3] = DeployData({name: "Adaptor", contractAddress: addrs[3]});
        }

        _registerNirvamma(registry, addrs);

        return deployedContracts;
    }

    function _registerNirvamma(GachaTeamRegistry registry, address[4] memory addrs) internal {
        MonStats memory stats = MonStats({
            hp: 373,
            stamina: 5,
            speed: 177,
            attack: 202,
            defense: 168,
            specialAttack: 140,
            specialDefense: 202,
            type1: Type.Math,
            type2: Type.None
        });
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(addrs[0]));
        moves[1] = 0x500b314000000000000000000000000000000000000000000000000000000000 | uint256(uint160(vm.envAddress("PANIC_STATUS")));
        moves[2] = uint256(uint160(addrs[1]));
        moves[3] = uint256(uint160(addrs[2]));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = (uint256(1) << 248) | uint256(uint160(addrs[3]));
        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);
        registry.createMon(12, stats, moves, abilities, keys, values);
    }

}