// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/Constants.sol";

// Fundamental entities
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";
import {GachaRegistry, IGachaRNG} from "../src/gacha/GachaRegistry.sol";
import {ICPURNG} from "../src/rng/ICPURNG.sol";
import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {GachaTeamRegistry} from "../src/teams/GachaTeamRegistry.sol";
import {LookupTeamRegistry} from "../src/teams/LookupTeamRegistry.sol";
import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleHistory} from "../src/hooks/BattleHistory.sol";
import {SimplePM} from "../src/hooks/SimplePM.sol";

// Shared effects
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract EngineAndPeriphery is Script {

    
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        TypeCalculator typeCalc = new TypeCalculator();
        deployedContracts.push(DeployData({name: "TYPE CALCULATOR", contractAddress: address(typeCalc)}));

        Engine engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON, GAME_TIMEOUT_DURATION);
        deployedContracts.push(DeployData({name: "ENGINE", contractAddress: address(engine)}));

        SignedCommitManager commitManager = new SignedCommitManager(engine);
        deployedContracts.push(DeployData({name: "COMMIT MANAGER", contractAddress: address(commitManager)}));

        DefaultMonRegistry monRegistry = new DefaultMonRegistry();
        deployedContracts.push(DeployData({name: "DEFAULT MON REGISTRY", contractAddress: address(monRegistry)}));

        GachaRegistry gachaRegistry = new GachaRegistry(monRegistry, engine, IGachaRNG(address(0)));
        deployedContracts.push(DeployData({name: "GACHA REGISTRY", contractAddress: address(gachaRegistry)}));

        GachaTeamRegistry gachaTeamRegistry = new GachaTeamRegistry(
            LookupTeamRegistry.Args({REGISTRY: gachaRegistry, MONS_PER_TEAM: GAME_MONS_PER_TEAM, MOVES_PER_MON: GAME_MOVES_PER_MON}), gachaRegistry
        );
        deployedContracts.push(DeployData({name: "GACHA TEAM REGISTRY", contractAddress: address(gachaTeamRegistry)}));

        // DefaultRandomnessOracle defaultOracle = new DefaultRandomnessOracle();
        // deployedContracts.push(DeployData({name: "DEFAULT RANDOMNESS ORACLE", contractAddress: address(defaultOracle)}));

        OkayCPU okayCPU = new OkayCPU(GAME_MOVES_PER_MON, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "OKAY CPU", contractAddress: address(okayCPU)}));

        BetterCPU betterCPU = new BetterCPU(GAME_MOVES_PER_MON, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "BETTER CPU", contractAddress: address(betterCPU)}));

        SignedMatchmaker signedMatchmaker = new SignedMatchmaker(engine);
        deployedContracts.push(DeployData({name: "SIGNED MATCHMAKER", contractAddress: address(signedMatchmaker)}));

        BattleHistory battleHistory = new BattleHistory(engine);
        deployedContracts.push(DeployData({name: "BATTLE HISTORY", contractAddress: address(battleHistory)}));

        SimplePM simplePM = new SimplePM(engine);
        deployedContracts.push(DeployData({name: "SIMPLE PM", contractAddress: address(simplePM)}));

        deployGameFundamentals(engine);
        
        vm.stopBroadcast();
        return deployedContracts;
    }

    function deployGameFundamentals(Engine engine) public {
        // StaminaRegen staminaRegen = new StaminaRegen();
        // deployedContracts.push(DeployData({name: "STAMINA REGEN", contractAddress: address(staminaRegen)}));

        // IEffect[] memory effects = new IEffect[](1);
        // effects[0] = staminaRegen;
        // DefaultRuleset ruleset = new DefaultRuleset(engine, effects);
        // deployedContracts.push(DeployData({name: "DEFAULT RULESET", contractAddress: address(ruleset)}));

        DefaultValidator validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: GAME_MONS_PER_TEAM, MOVES_PER_MON: GAME_MOVES_PER_MON, TIMEOUT_DURATION: GAME_TIMEOUT_DURATION}));
        deployedContracts.push(DeployData({name: "DEFAULT VALIDATOR", contractAddress: address(validator)}));

        StatBoosts statBoosts = new StatBoosts();
        deployedContracts.push(DeployData({name: "STAT BOOSTS", contractAddress: address(statBoosts)}));

        Overclock overclock = new Overclock(statBoosts);
        deployedContracts.push(DeployData({name: "OVERCLOCK", contractAddress: address(overclock)}));

        SleepStatus sleepStatus = new SleepStatus();
        deployedContracts.push(DeployData({name: "SLEEP STATUS", contractAddress: address(sleepStatus)}));

        PanicStatus panicStatus = new PanicStatus();
        deployedContracts.push(DeployData({name: "PANIC STATUS", contractAddress: address(panicStatus)}));

        FrostbiteStatus frostbiteStatus = new FrostbiteStatus(statBoosts);
        deployedContracts.push(DeployData({name: "FROSTBITE STATUS", contractAddress: address(frostbiteStatus)}));

        BurnStatus burnStatus = new BurnStatus(statBoosts);
        deployedContracts.push(DeployData({name: "BURN STATUS", contractAddress: address(burnStatus)}));

        ZapStatus zapStatus = new ZapStatus();
        deployedContracts.push(DeployData({name: "ZAP STATUS", contractAddress: address(zapStatus)}));
    }
}
