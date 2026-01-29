mod create3;
mod miner;

use alloy_primitives::Address;
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::str::FromStr;

/// Effect Address Miner - Mine CREATE3 salts for Effect contracts with specific address bitmaps
#[derive(Parser)]
#[command(name = "effect-miner")]
#[command(about = "Mine vanity addresses for Effect contracts using CREATE3")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Mine a single effect address
    Mine {
        /// Effect name (for identification)
        #[arg(short, long)]
        name: String,

        /// Target bitmap (9-bit value, e.g., 0x042 or 66)
        #[arg(short, long)]
        bitmap: String,

        /// CreateX contract address
        #[arg(short, long, default_value = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed")]
        createx: String,

        /// Maximum attempts (0 = unlimited)
        #[arg(short = 'a', long, default_value = "0")]
        max_attempts: u64,

        /// Output file (JSON)
        #[arg(short, long)]
        output: Option<PathBuf>,
    },

    /// Mine multiple effects from a config file
    MineAll {
        /// Input config file (JSON)
        #[arg(short, long)]
        config: PathBuf,

        /// CreateX contract address
        #[arg(short = 'x', long, default_value = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed")]
        createx: String,

        /// Maximum attempts per effect (0 = unlimited)
        #[arg(short = 'a', long, default_value = "0")]
        max_attempts: u64,

        /// Output file (JSON)
        #[arg(short, long)]
        output: PathBuf,
    },

    /// Verify an address has the expected bitmap
    Verify {
        /// Address to verify
        #[arg(short, long)]
        address: String,

        /// Expected bitmap
        #[arg(short, long)]
        bitmap: String,
    },

    /// Compute CREATE3 address for a given salt
    Compute {
        /// Salt (32 bytes hex)
        #[arg(short, long)]
        salt: String,

        /// CreateX contract address
        #[arg(short, long, default_value = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed")]
        createx: String,
    },

    /// Generate a config file template with all known effects
    GenerateConfig {
        /// Output file
        #[arg(short, long)]
        output: PathBuf,
    },
}

/// Input config format for mining multiple effects
#[derive(Debug, Serialize, Deserialize)]
struct MiningConfig {
    #[serde(default = "default_createx")]
    createx: String,
    effects: HashMap<String, EffectConfig>,
}

fn default_createx() -> String {
    "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed".to_string()
}

#[derive(Debug, Serialize, Deserialize)]
struct EffectConfig {
    bitmap: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
}

/// Output format for mined salts
#[derive(Debug, Serialize, Deserialize)]
struct MiningOutput {
    createx: String,
    effects: HashMap<String, EffectResult>,
}

#[derive(Debug, Serialize, Deserialize)]
struct EffectResult {
    salt: String,
    address: String,
    bitmap: String,
    attempts: u64,
}

fn parse_bitmap(s: &str) -> Result<u16, String> {
    let s = s.trim().to_lowercase();
    if s.starts_with("0x") {
        u16::from_str_radix(&s[2..], 16).map_err(|e| format!("Invalid hex bitmap: {}", e))
    } else if s.starts_with("0b") {
        u16::from_str_radix(&s[2..], 2).map_err(|e| format!("Invalid binary bitmap: {}", e))
    } else {
        s.parse::<u16>().map_err(|e| format!("Invalid decimal bitmap: {}", e))
    }
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Mine {
            name,
            bitmap,
            createx,
            max_attempts,
            output,
        } => {
            let bitmap_value = parse_bitmap(&bitmap).expect("Invalid bitmap");
            let createx_addr = Address::from_str(&createx).expect("Invalid CreateX address");

            println!("Mining salt for {} with bitmap 0x{:03X}...", name, bitmap_value);
            println!("CreateX: {}", createx);
            println!("Expected attempts: ~{}", miner::expected_attempts());

            let result = miner::mine_salt(createx_addr, bitmap_value, None, max_attempts);

            match result {
                Some(r) => {
                    println!("\nSuccess!");
                    println!("  Salt:     {:?}", r.salt);
                    println!("  Address:  {:?}", r.address);
                    println!("  Bitmap:   0x{:03X}", r.bitmap);
                    println!("  Attempts: {}", r.attempts);

                    if let Some(output_path) = output {
                        let mut effects = HashMap::new();
                        effects.insert(
                            name,
                            EffectResult {
                                salt: format!("{:?}", r.salt),
                                address: format!("{:?}", r.address),
                                bitmap: format!("0x{:03X}", r.bitmap),
                                attempts: r.attempts,
                            },
                        );
                        let output = MiningOutput {
                            createx,
                            effects,
                        };
                        let json = serde_json::to_string_pretty(&output).unwrap();
                        fs::write(&output_path, json).expect("Failed to write output file");
                        println!("\nResults written to {:?}", output_path);
                    }
                }
                None => {
                    eprintln!("Failed to find matching salt within {} attempts", max_attempts);
                    std::process::exit(1);
                }
            }
        }

        Commands::MineAll {
            config,
            createx,
            max_attempts,
            output,
        } => {
            let config_str = fs::read_to_string(&config).expect("Failed to read config file");
            let mining_config: MiningConfig =
                serde_json::from_str(&config_str).expect("Failed to parse config file");

            let createx_addr = Address::from_str(&createx).expect("Invalid CreateX address");

            let effects: Vec<(String, u16)> = mining_config
                .effects
                .iter()
                .map(|(name, cfg)| {
                    let bitmap = parse_bitmap(&cfg.bitmap).expect(&format!(
                        "Invalid bitmap for {}: {}",
                        name, cfg.bitmap
                    ));
                    (name.clone(), bitmap)
                })
                .collect();

            println!("Mining {} effects...", effects.len());
            println!("CreateX: {}", createx);
            println!("Max attempts per effect: {}", if max_attempts == 0 { "unlimited".to_string() } else { max_attempts.to_string() });
            println!();

            let results = miner::mine_multiple(createx_addr, effects, max_attempts);

            let mut output_effects = HashMap::new();
            let mut success_count = 0;
            let mut fail_count = 0;

            for (name, result) in results {
                match result {
                    Some(r) => {
                        println!("{}: {} (bitmap: 0x{:03X}, {} attempts)",
                            name, r.address, r.bitmap, r.attempts);
                        output_effects.insert(
                            name,
                            EffectResult {
                                salt: format!("{:?}", r.salt),
                                address: format!("{:?}", r.address),
                                bitmap: format!("0x{:03X}", r.bitmap),
                                attempts: r.attempts,
                            },
                        );
                        success_count += 1;
                    }
                    None => {
                        eprintln!("{}: FAILED to find matching salt", name);
                        fail_count += 1;
                    }
                }
            }

            println!();
            println!("Complete: {} succeeded, {} failed", success_count, fail_count);

            let mining_output = MiningOutput {
                createx,
                effects: output_effects,
            };
            let json = serde_json::to_string_pretty(&mining_output).unwrap();
            fs::write(&output, json).expect("Failed to write output file");
            println!("Results written to {:?}", output);
        }

        Commands::Verify { address, bitmap } => {
            let addr = Address::from_str(&address).expect("Invalid address");
            let expected_bitmap = parse_bitmap(&bitmap).expect("Invalid bitmap");
            let actual_bitmap = create3::extract_bitmap(addr);

            println!("Address: {}", address);
            println!("Expected bitmap: 0x{:03X}", expected_bitmap);
            println!("Actual bitmap:   0x{:03X}", actual_bitmap);

            if actual_bitmap == expected_bitmap {
                println!("MATCH");
            } else {
                println!("MISMATCH");
                std::process::exit(1);
            }
        }

        Commands::Compute { salt, createx } => {
            let salt_bytes = hex::decode(salt.trim_start_matches("0x"))
                .expect("Invalid salt hex");
            if salt_bytes.len() != 32 {
                eprintln!("Salt must be 32 bytes");
                std::process::exit(1);
            }
            let mut salt_arr = [0u8; 32];
            salt_arr.copy_from_slice(&salt_bytes);
            let salt = alloy_primitives::B256::from(salt_arr);

            let createx_addr = Address::from_str(&createx).expect("Invalid CreateX address");
            let address = create3::compute_create3_address(salt, createx_addr);
            let bitmap = create3::extract_bitmap(address);

            println!("Salt:    0x{}", hex::encode(salt_arr));
            println!("CreateX: {}", createx);
            println!("Address: {:?}", address);
            println!("Bitmap:  0x{:03X}", bitmap);
        }

        Commands::GenerateConfig { output } => {
            let mut effects = HashMap::new();

            // Core effects
            effects.insert("StaminaRegen".to_string(), EffectConfig {
                bitmap: "0x042".to_string(),
                description: Some("RoundEnd, AfterMove".to_string()),
            });
            effects.insert("StatBoosts".to_string(), EffectConfig {
                bitmap: "0x008".to_string(),
                description: Some("OnMonSwitchOut".to_string()),
            });
            effects.insert("Overclock".to_string(), EffectConfig {
                bitmap: "0x170".to_string(),
                description: Some("OnApply, RoundEnd, OnMonSwitchIn, OnRemove".to_string()),
            });
            effects.insert("BurnStatus".to_string(), EffectConfig {
                bitmap: "0x1E0".to_string(),
                description: Some("OnApply, RoundStart, RoundEnd, OnRemove".to_string()),
            });
            effects.insert("FrostbiteStatus".to_string(), EffectConfig {
                bitmap: "0x160".to_string(),
                description: Some("OnApply, RoundEnd, OnRemove".to_string()),
            });
            effects.insert("PanicStatus".to_string(), EffectConfig {
                bitmap: "0x1E0".to_string(),
                description: Some("OnApply, RoundStart, RoundEnd, OnRemove".to_string()),
            });
            effects.insert("SleepStatus".to_string(), EffectConfig {
                bitmap: "0x1E0".to_string(),
                description: Some("OnApply, RoundStart, RoundEnd, OnRemove".to_string()),
            });
            effects.insert("ZapStatus".to_string(), EffectConfig {
                bitmap: "0x1E0".to_string(),
                description: Some("OnApply, RoundStart, RoundEnd, OnRemove".to_string()),
            });

            // Mon abilities
            effects.insert("RiseFromTheGrave".to_string(), EffectConfig {
                bitmap: "0x044".to_string(),
                description: Some("RoundEnd, AfterDamage".to_string()),
            });
            effects.insert("IronWall".to_string(), EffectConfig {
                bitmap: "0x00C".to_string(),
                description: Some("AfterDamage, OnMonSwitchOut".to_string()),
            });
            effects.insert("UpOnly".to_string(), EffectConfig {
                bitmap: "0x004".to_string(),
                description: Some("AfterDamage".to_string()),
            });
            effects.insert("Tinderclaws".to_string(), EffectConfig {
                bitmap: "0x042".to_string(),
                description: Some("AfterMove, RoundEnd".to_string()),
            });
            effects.insert("Q5".to_string(), EffectConfig {
                bitmap: "0x080".to_string(),
                description: Some("RoundStart".to_string()),
            });
            effects.insert("PostWorkout".to_string(), EffectConfig {
                bitmap: "0x008".to_string(),
                description: Some("OnMonSwitchOut".to_string()),
            });
            effects.insert("Baselight".to_string(), EffectConfig {
                bitmap: "0x040".to_string(),
                description: Some("RoundEnd".to_string()),
            });
            effects.insert("CarrotHarvest".to_string(), EffectConfig {
                bitmap: "0x040".to_string(),
                description: Some("RoundEnd".to_string()),
            });
            effects.insert("ActusReus".to_string(), EffectConfig {
                bitmap: "0x006".to_string(),
                description: Some("AfterMove, AfterDamage".to_string()),
            });
            effects.insert("Angery".to_string(), EffectConfig {
                bitmap: "0x044".to_string(),
                description: Some("RoundEnd, AfterDamage".to_string()),
            });
            effects.insert("Dreamcatcher".to_string(), EffectConfig {
                bitmap: "0x001".to_string(),
                description: Some("OnUpdateMonState".to_string()),
            });
            effects.insert("NightTerrors".to_string(), EffectConfig {
                bitmap: "0x048".to_string(),
                description: Some("RoundEnd, OnMonSwitchOut".to_string()),
            });
            effects.insert("Somniphobia".to_string(), EffectConfig {
                bitmap: "0x042".to_string(),
                description: Some("AfterMove, RoundEnd".to_string()),
            });
            effects.insert("Initialize".to_string(), EffectConfig {
                bitmap: "0x018".to_string(),
                description: Some("OnMonSwitchIn, OnMonSwitchOut".to_string()),
            });
            effects.insert("Interweaving".to_string(), EffectConfig {
                bitmap: "0x108".to_string(),
                description: Some("OnMonSwitchOut, OnApply".to_string()),
            });
            effects.insert("ChainExpansion".to_string(), EffectConfig {
                bitmap: "0x010".to_string(),
                description: Some("OnMonSwitchIn".to_string()),
            });

            let config = MiningConfig {
                createx: default_createx(),
                effects,
            };

            let json = serde_json::to_string_pretty(&config).unwrap();
            fs::write(&output, json).expect("Failed to write config file");
            println!("Config template written to {:?}", output);
            println!("Contains {} effects", config.effects.len());
        }
    }
}
