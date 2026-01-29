// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {CreateX} from "../src/lib/CreateX.sol";
import {EffectDeployer} from "../src/lib/EffectDeployer.sol";
import {EffectBitmap} from "../src/lib/EffectBitmap.sol";
import {IEngine} from "../src/IEngine.sol";
import {IEffect} from "../src/effects/IEffect.sol";

// Effects
import {StaminaRegen} from "../src/effects/StaminaRegen.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";

/// @title DeployEffectsCreate3
/// @notice Deploy Effect contracts via CREATE3 with bitmap-encoded addresses
/// @dev Salts should be pre-mined using the effect-miner CLI tool.
///      Run: effect-miner mine-all --config effects.json --output salts.json
///
///      Effect bitmaps encode which EffectSteps they run at:
///        - StaminaRegen:     0x042 (RoundEnd, AfterMove)
///        - StatBoosts:       0x008 (OnMonSwitchOut)
///        - Overclock:        0x170 (OnApply, RoundEnd, OnMonSwitchIn, OnRemove)
///        - BurnStatus:       0x1E0 (OnApply, RoundStart, RoundEnd, OnRemove)
///        - FrostbiteStatus:  0x160 (OnApply, RoundEnd, OnRemove)
///        - PanicStatus:      0x1E0 (OnApply, RoundStart, RoundEnd, OnRemove)
///        - SleepStatus:      0x1E0 (OnApply, RoundStart, RoundEnd, OnRemove)
///        - ZapStatus:        0x1E0 (OnApply, RoundStart, RoundEnd, OnRemove)
contract DeployEffectsCreate3 is Script {
    /// @notice Canonical CreateX address (same on all EVM chains)
    address constant CREATEX_ADDRESS = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @notice Effect bitmap constants
    uint16 constant BITMAP_STAMINA_REGEN = 0x042;     // RoundEnd, AfterMove
    uint16 constant BITMAP_STAT_BOOSTS = 0x008;       // OnMonSwitchOut
    uint16 constant BITMAP_OVERCLOCK = 0x170;         // OnApply, RoundEnd, OnMonSwitchIn, OnRemove
    uint16 constant BITMAP_BURN_STATUS = 0x1E0;       // OnApply, RoundStart, RoundEnd, OnRemove
    uint16 constant BITMAP_FROSTBITE_STATUS = 0x160;  // OnApply, RoundEnd, OnRemove
    uint16 constant BITMAP_PANIC_STATUS = 0x1E0;      // OnApply, RoundStart, RoundEnd, OnRemove
    uint16 constant BITMAP_SLEEP_STATUS = 0x1E0;      // OnApply, RoundStart, RoundEnd, OnRemove
    uint16 constant BITMAP_ZAP_STATUS = 0x1E0;        // OnApply, RoundStart, RoundEnd, OnRemove

    struct EffectSalts {
        bytes32 staminaRegen;
        bytes32 statBoosts;
        bytes32 overclock;
        bytes32 burnStatus;
        bytes32 frostbiteStatus;
        bytes32 panicStatus;
        bytes32 sleepStatus;
        bytes32 zapStatus;
    }

    struct DeployedEffects {
        StaminaRegen staminaRegen;
        StatBoosts statBoosts;
        Overclock overclock;
        BurnStatus burnStatus;
        FrostbiteStatus frostbiteStatus;
        PanicStatus panicStatus;
        SleepStatus sleepStatus;
        ZapStatus zapStatus;
    }

    /// @notice Deploy all core effects via CREATE3
    /// @param engine The engine contract that effects will interact with
    /// @param salts Pre-mined salts for each effect (from effect-miner)
    /// @return effects Struct containing all deployed effect addresses
    function deployEffects(IEngine engine, EffectSalts memory salts) public returns (DeployedEffects memory effects) {
        CreateX createX = CreateX(CREATEX_ADDRESS);

        // Deploy StatBoosts first (dependency for other effects)
        effects.statBoosts = StatBoosts(
            EffectDeployer.deploy(
                createX,
                salts.statBoosts,
                abi.encodePacked(type(StatBoosts).creationCode, abi.encode(engine)),
                BITMAP_STAT_BOOSTS
            )
        );
        console.log("StatBoosts deployed at:", address(effects.statBoosts));

        // Deploy StaminaRegen
        effects.staminaRegen = StaminaRegen(
            EffectDeployer.deploy(
                createX,
                salts.staminaRegen,
                abi.encodePacked(type(StaminaRegen).creationCode, abi.encode(engine)),
                BITMAP_STAMINA_REGEN
            )
        );
        console.log("StaminaRegen deployed at:", address(effects.staminaRegen));

        // Deploy Overclock (depends on StatBoosts)
        effects.overclock = Overclock(
            EffectDeployer.deploy(
                createX,
                salts.overclock,
                abi.encodePacked(type(Overclock).creationCode, abi.encode(engine, effects.statBoosts)),
                BITMAP_OVERCLOCK
            )
        );
        console.log("Overclock deployed at:", address(effects.overclock));

        // Deploy status effects
        effects.sleepStatus = SleepStatus(
            EffectDeployer.deploy(
                createX,
                salts.sleepStatus,
                abi.encodePacked(type(SleepStatus).creationCode, abi.encode(engine)),
                BITMAP_SLEEP_STATUS
            )
        );
        console.log("SleepStatus deployed at:", address(effects.sleepStatus));

        effects.panicStatus = PanicStatus(
            EffectDeployer.deploy(
                createX,
                salts.panicStatus,
                abi.encodePacked(type(PanicStatus).creationCode, abi.encode(engine)),
                BITMAP_PANIC_STATUS
            )
        );
        console.log("PanicStatus deployed at:", address(effects.panicStatus));

        effects.frostbiteStatus = FrostbiteStatus(
            EffectDeployer.deploy(
                createX,
                salts.frostbiteStatus,
                abi.encodePacked(type(FrostbiteStatus).creationCode, abi.encode(engine, effects.statBoosts)),
                BITMAP_FROSTBITE_STATUS
            )
        );
        console.log("FrostbiteStatus deployed at:", address(effects.frostbiteStatus));

        effects.burnStatus = BurnStatus(
            EffectDeployer.deploy(
                createX,
                salts.burnStatus,
                abi.encodePacked(type(BurnStatus).creationCode, abi.encode(engine, effects.statBoosts)),
                BITMAP_BURN_STATUS
            )
        );
        console.log("BurnStatus deployed at:", address(effects.burnStatus));

        effects.zapStatus = ZapStatus(
            EffectDeployer.deploy(
                createX,
                salts.zapStatus,
                abi.encodePacked(type(ZapStatus).creationCode, abi.encode(engine)),
                BITMAP_ZAP_STATUS
            )
        );
        console.log("ZapStatus deployed at:", address(effects.zapStatus));
    }

    /// @notice Preview what addresses effects would be deployed to
    /// @param salts Pre-mined salts for each effect
    function previewAddresses(EffectSalts memory salts) public view {
        CreateX createX = CreateX(CREATEX_ADDRESS);

        console.log("Preview of effect addresses:");
        console.log("----------------------------");

        address addr;
        uint16 bitmap;

        addr = EffectDeployer.computeAddress(createX, salts.staminaRegen);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("StaminaRegen:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.statBoosts);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("StatBoosts:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.overclock);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("Overclock:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.burnStatus);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("BurnStatus:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.frostbiteStatus);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("FrostbiteStatus:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.panicStatus);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("PanicStatus:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.sleepStatus);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("SleepStatus:", addr, "bitmap:", bitmap);

        addr = EffectDeployer.computeAddress(createX, salts.zapStatus);
        bitmap = EffectBitmap.extractBitmap(addr);
        console.log("ZapStatus:", addr, "bitmap:", bitmap);
    }

    /// @notice Example run function - replace salts with actual mined values
    function run() external {
        // IMPORTANT: Replace these with actual mined salts from effect-miner!
        // These are placeholder values and will NOT produce correct bitmaps.
        EffectSalts memory salts = EffectSalts({
            staminaRegen: bytes32(0),    // Mine with: effect-miner mine --name StaminaRegen --bitmap 0x042
            statBoosts: bytes32(0),      // Mine with: effect-miner mine --name StatBoosts --bitmap 0x008
            overclock: bytes32(0),       // Mine with: effect-miner mine --name Overclock --bitmap 0x170
            burnStatus: bytes32(0),      // Mine with: effect-miner mine --name BurnStatus --bitmap 0x1E0
            frostbiteStatus: bytes32(0), // Mine with: effect-miner mine --name FrostbiteStatus --bitmap 0x160
            panicStatus: bytes32(0),     // Mine with: effect-miner mine --name PanicStatus --bitmap 0x1E0
            sleepStatus: bytes32(0),     // Mine with: effect-miner mine --name SleepStatus --bitmap 0x1E0
            zapStatus: bytes32(0)        // Mine with: effect-miner mine --name ZapStatus --bitmap 0x1E0
        });

        // Preview addresses before deployment
        previewAddresses(salts);

        // Uncomment to deploy:
        // vm.startBroadcast();
        // IEngine engine = IEngine(address(0)); // Replace with actual engine address
        // deployEffects(engine, salts);
        // vm.stopBroadcast();
    }
}
