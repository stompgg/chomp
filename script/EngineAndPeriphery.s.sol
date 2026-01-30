// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Fundamental entities
import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {DefaultRuleset} from "../src/DefaultRuleset.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {PlayerCPU} from "../src/cpu/PlayerCPU.sol";
import {RandomCPU} from "../src/cpu/RandomCPU.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {StaminaRegen} from "../src/effects/StaminaRegen.sol";
import {GachaRegistry, IGachaRNG} from "../src/gacha/GachaRegistry.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {ICPURNG} from "../src/rng/ICPURNG.sol";
import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {GachaTeamRegistry} from "../src/teams/GachaTeamRegistry.sol";
import {LookupTeamRegistry} from "../src/teams/LookupTeamRegistry.sol";
import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHistory} from "../src/hooks/BattleHistory.sol";

// Important effects
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";

// CREATE3 deployment
import {CreateX} from "../src/lib/CreateX.sol";
import {EffectDeployer} from "../src/lib/EffectDeployer.sol";
import {EffectBitmap} from "../src/lib/EffectBitmap.sol";

struct DeployData {
    string name;
    address contractAddress;
}

/// @notice Pre-mined salts for CREATE3 effect deployment
/// @dev These salts produce addresses with correct EffectStep bitmaps when deployed via CreateX.
///      Generate with: effect-miner mine-all --config effects.json --output salts.json
struct EffectSalts {
    bytes32 staminaRegen;    // Bitmap 0x042: RoundEnd, AfterMove
    bytes32 statBoosts;      // Bitmap 0x008: OnMonSwitchOut
    bytes32 overclock;       // Bitmap 0x170: OnApply, RoundEnd, OnMonSwitchIn, OnRemove
    bytes32 burnStatus;      // Bitmap 0x1E0: OnApply, RoundStart, RoundEnd, OnRemove
    bytes32 frostbiteStatus; // Bitmap 0x160: OnApply, RoundEnd, OnRemove
    bytes32 panicStatus;     // Bitmap 0x1E0: OnApply, RoundStart, RoundEnd, OnRemove
    bytes32 sleepStatus;     // Bitmap 0x1E0: OnApply, RoundStart, RoundEnd, OnRemove
    bytes32 zapStatus;       // Bitmap 0x1E0: OnApply, RoundStart, RoundEnd, OnRemove
}

contract EngineAndPeriphery is Script {

    uint256 constant NUM_MONS = 4;
    uint256 constant NUM_MOVES = 4;
    uint256 constant TIMEOUT_DURATION = 60;

    /// @notice Canonical CreateX address (same on all EVM chains)
    address constant CREATEX_ADDRESS = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @notice Effect bitmap constants
    uint16 constant BITMAP_STAMINA_REGEN = 0x042;
    uint16 constant BITMAP_STAT_BOOSTS = 0x008;
    uint16 constant BITMAP_OVERCLOCK = 0x170;
    uint16 constant BITMAP_BURN_STATUS = 0x1E0;
    uint16 constant BITMAP_FROSTBITE_STATUS = 0x160;
    uint16 constant BITMAP_PANIC_STATUS = 0x1E0;
    uint16 constant BITMAP_SLEEP_STATUS = 0x1E0;
    uint16 constant BITMAP_ZAP_STATUS = 0x1E0;

    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        TypeCalculator typeCalc = new TypeCalculator();
        deployedContracts.push(DeployData({name: "TYPE CALCULATOR", contractAddress: address(typeCalc)}));

        Engine engine = new Engine();
        deployedContracts.push(DeployData({name: "ENGINE", contractAddress: address(engine)}));

        DefaultCommitManager commitManager = new DefaultCommitManager(engine);
        deployedContracts.push(DeployData({name: "COMMIT MANAGER", contractAddress: address(commitManager)}));

        DefaultMonRegistry monRegistry = new DefaultMonRegistry();
        deployedContracts.push(DeployData({name: "DEFAULT MON REGISTRY", contractAddress: address(monRegistry)}));

        GachaRegistry gachaRegistry = new GachaRegistry(monRegistry, engine, IGachaRNG(address(0)), 23 hours);
        deployedContracts.push(DeployData({name: "GACHA REGISTRY", contractAddress: address(gachaRegistry)}));

        GachaTeamRegistry gachaTeamRegistry = new GachaTeamRegistry(
            LookupTeamRegistry.Args({REGISTRY: gachaRegistry, MONS_PER_TEAM: NUM_MONS, MOVES_PER_MON: NUM_MOVES}), gachaRegistry
        );
        deployedContracts.push(DeployData({name: "GACHA TEAM REGISTRY", contractAddress: address(gachaTeamRegistry)}));

        DefaultRandomnessOracle defaultOracle = new DefaultRandomnessOracle();
        deployedContracts.push(DeployData({name: "DEFAULT RANDOMNESS ORACLE", contractAddress: address(defaultOracle)}));

        RandomCPU cpu = new RandomCPU(NUM_MOVES, engine, ICPURNG(address(0)));
        deployedContracts.push(DeployData({name: "RANDOM CPU", contractAddress: address(cpu)}));

        PlayerCPU playerCPU = new PlayerCPU(NUM_MOVES, engine, ICPURNG(address(0)));
        deployedContracts.push(DeployData({name: "PLAYER CPU", contractAddress: address(playerCPU)}));

        OkayCPU okayCPU = new OkayCPU(NUM_MOVES, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "OKAY CPU", contractAddress: address(okayCPU)}));

        DefaultMatchmaker matchmaker = new DefaultMatchmaker(engine);
        deployedContracts.push(DeployData({name: "DEFAULT MATCHMAKER", contractAddress: address(matchmaker)}));

        BattleHistory battleHistory = new BattleHistory(engine);
        deployedContracts.push(DeployData({name: "BATTLE HISTORY", contractAddress: address(battleHistory)}));

        deployGameFundamentals(engine);
        
        vm.stopBroadcast();
        return deployedContracts;
    }

    function deployGameFundamentals(Engine engine) public {
        StaminaRegen staminaRegen = new StaminaRegen(engine);
        deployedContracts.push(DeployData({name: "STAMINA REGEN", contractAddress: address(staminaRegen)}));

        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(engine, effects);
        deployedContracts.push(DeployData({name: "DEFAULT RULESET", contractAddress: address(ruleset)}));

        DefaultValidator validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: NUM_MONS, MOVES_PER_MON: NUM_MOVES, TIMEOUT_DURATION: TIMEOUT_DURATION}));
        deployedContracts.push(DeployData({name: "DEFAULT VALIDATOR", contractAddress: address(validator)}));

        StatBoosts statBoosts = new StatBoosts(engine);
        deployedContracts.push(DeployData({name: "STAT BOOSTS", contractAddress: address(statBoosts)}));

        Overclock overclock = new Overclock(engine, statBoosts);
        deployedContracts.push(DeployData({name: "OVERCLOCK", contractAddress: address(overclock)}));

        SleepStatus sleepStatus = new SleepStatus(engine);
        deployedContracts.push(DeployData({name: "SLEEP STATUS", contractAddress: address(sleepStatus)}));

        PanicStatus panicStatus = new PanicStatus(engine);
        deployedContracts.push(DeployData({name: "PANIC STATUS", contractAddress: address(panicStatus)}));

        FrostbiteStatus frostbiteStatus = new FrostbiteStatus(engine, statBoosts);
        deployedContracts.push(DeployData({name: "FROSTBITE STATUS", contractAddress: address(frostbiteStatus)}));

        BurnStatus burnStatus = new BurnStatus(engine, statBoosts);
        deployedContracts.push(DeployData({name: "BURN STATUS", contractAddress: address(burnStatus)}));

        ZapStatus zapStatus = new ZapStatus(engine);
        deployedContracts.push(DeployData({name: "ZAP STATUS", contractAddress: address(zapStatus)}));
    }

    /// @notice Deploy effects via CREATE3 with bitmap-encoded addresses
    /// @dev Uses pre-mined salts to deploy effects at addresses that have the correct
    ///      EffectStep bitmap encoded in their most significant bits.
    /// @param engine The engine contract
    /// @param salts Pre-mined salts for each effect (from effect-miner)
    /// @return staminaRegen The deployed StaminaRegen effect
    function deployGameFundamentalsCreate3(Engine engine, EffectSalts memory salts)
        public
        returns (StaminaRegen staminaRegen)
    {
        CreateX createX = CreateX(CREATEX_ADDRESS);

        // Deploy StatBoosts first (dependency for other effects)
        StatBoosts statBoosts = StatBoosts(
            EffectDeployer.deploy(
                createX,
                salts.statBoosts,
                abi.encodePacked(type(StatBoosts).creationCode, abi.encode(engine)),
                BITMAP_STAT_BOOSTS
            )
        );
        deployedContracts.push(DeployData({name: "STAT BOOSTS", contractAddress: address(statBoosts)}));

        // Deploy StaminaRegen
        staminaRegen = StaminaRegen(
            EffectDeployer.deploy(
                createX,
                salts.staminaRegen,
                abi.encodePacked(type(StaminaRegen).creationCode, abi.encode(engine)),
                BITMAP_STAMINA_REGEN
            )
        );
        deployedContracts.push(DeployData({name: "STAMINA REGEN", contractAddress: address(staminaRegen)}));

        // Deploy Overclock (depends on StatBoosts)
        Overclock overclock = Overclock(
            EffectDeployer.deploy(
                createX,
                salts.overclock,
                abi.encodePacked(type(Overclock).creationCode, abi.encode(engine, statBoosts)),
                BITMAP_OVERCLOCK
            )
        );
        deployedContracts.push(DeployData({name: "OVERCLOCK", contractAddress: address(overclock)}));

        // Deploy status effects
        SleepStatus sleepStatus = SleepStatus(
            EffectDeployer.deploy(
                createX,
                salts.sleepStatus,
                abi.encodePacked(type(SleepStatus).creationCode, abi.encode(engine)),
                BITMAP_SLEEP_STATUS
            )
        );
        deployedContracts.push(DeployData({name: "SLEEP STATUS", contractAddress: address(sleepStatus)}));

        PanicStatus panicStatus = PanicStatus(
            EffectDeployer.deploy(
                createX,
                salts.panicStatus,
                abi.encodePacked(type(PanicStatus).creationCode, abi.encode(engine)),
                BITMAP_PANIC_STATUS
            )
        );
        deployedContracts.push(DeployData({name: "PANIC STATUS", contractAddress: address(panicStatus)}));

        FrostbiteStatus frostbiteStatus = FrostbiteStatus(
            EffectDeployer.deploy(
                createX,
                salts.frostbiteStatus,
                abi.encodePacked(type(FrostbiteStatus).creationCode, abi.encode(engine, statBoosts)),
                BITMAP_FROSTBITE_STATUS
            )
        );
        deployedContracts.push(DeployData({name: "FROSTBITE STATUS", contractAddress: address(frostbiteStatus)}));

        BurnStatus burnStatus = BurnStatus(
            EffectDeployer.deploy(
                createX,
                salts.burnStatus,
                abi.encodePacked(type(BurnStatus).creationCode, abi.encode(engine, statBoosts)),
                BITMAP_BURN_STATUS
            )
        );
        deployedContracts.push(DeployData({name: "BURN STATUS", contractAddress: address(burnStatus)}));

        ZapStatus zapStatus = ZapStatus(
            EffectDeployer.deploy(
                createX,
                salts.zapStatus,
                abi.encodePacked(type(ZapStatus).creationCode, abi.encode(engine)),
                BITMAP_ZAP_STATUS
            )
        );
        deployedContracts.push(DeployData({name: "ZAP STATUS", contractAddress: address(zapStatus)}));

        // Create ruleset with staminaRegen
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(engine, effects);
        deployedContracts.push(DeployData({name: "DEFAULT RULESET", contractAddress: address(ruleset)}));

        DefaultValidator validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: NUM_MONS, MOVES_PER_MON: NUM_MOVES, TIMEOUT_DURATION: TIMEOUT_DURATION}));
        deployedContracts.push(DeployData({name: "DEFAULT VALIDATOR", contractAddress: address(validator)}));
    }
}
