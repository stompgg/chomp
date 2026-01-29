use crate::create3::{compute_create3_address, extract_bitmap, matches_bitmap};
use alloy_primitives::{Address, B256};
use rand::Rng;
use rayon::prelude::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

/// Result of a successful mining operation
#[derive(Debug, Clone)]
pub struct MiningResult {
    pub salt: B256,
    pub address: Address,
    pub bitmap: u16,
    pub attempts: u64,
}

/// Mine a salt that produces an address with the target bitmap in its MSB 9 bits
///
/// # Arguments
/// * `createx_address` - The CreateX factory contract address
/// * `target_bitmap` - The desired 9-bit bitmap value
/// * `base_salt` - Optional base salt to start from (useful for deterministic mining)
/// * `max_attempts` - Maximum number of attempts before giving up (0 = unlimited)
///
/// # Returns
/// * `Some(MiningResult)` if a matching salt is found
/// * `None` if max_attempts is reached without finding a match
pub fn mine_salt(
    createx_address: Address,
    target_bitmap: u16,
    base_salt: Option<B256>,
    max_attempts: u64,
) -> Option<MiningResult> {
    let found = Arc::new(AtomicBool::new(false));
    let attempts = Arc::new(AtomicU64::new(0));

    // Use base_salt or generate random starting points for each thread
    let base = base_salt.unwrap_or_else(|| {
        let mut rng = rand::thread_rng();
        let mut bytes = [0u8; 32];
        rng.fill(&mut bytes);
        B256::from(bytes)
    });

    // Determine chunk size for parallel iteration
    let chunk_size = 10_000u64;
    let max_chunks = if max_attempts == 0 {
        u64::MAX / chunk_size
    } else {
        (max_attempts + chunk_size - 1) / chunk_size
    };

    let result: Option<MiningResult> = (0..max_chunks)
        .into_par_iter()
        .find_map_any(|chunk_idx| {
            if found.load(Ordering::Relaxed) {
                return None;
            }

            let start = chunk_idx * chunk_size;
            let end = if max_attempts == 0 {
                start + chunk_size
            } else {
                std::cmp::min(start + chunk_size, max_attempts)
            };

            for i in start..end {
                if found.load(Ordering::Relaxed) {
                    return None;
                }

                // Generate salt by XORing base with counter
                let mut salt_bytes = base.0;
                let counter_bytes = i.to_be_bytes();
                for (j, &b) in counter_bytes.iter().enumerate() {
                    salt_bytes[24 + j] ^= b;
                }
                let salt = B256::from(salt_bytes);

                let address = compute_create3_address(salt, createx_address);

                attempts.fetch_add(1, Ordering::Relaxed);

                if matches_bitmap(address, target_bitmap) {
                    found.store(true, Ordering::Relaxed);
                    return Some(MiningResult {
                        salt,
                        address,
                        bitmap: extract_bitmap(address),
                        attempts: attempts.load(Ordering::Relaxed),
                    });
                }
            }

            None
        });

    result
}

/// Mine salts for multiple effects in parallel
///
/// # Arguments
/// * `createx_address` - The CreateX factory contract address
/// * `effects` - List of (effect_name, target_bitmap) tuples
/// * `max_attempts_per_effect` - Maximum attempts per effect (0 = unlimited)
///
/// # Returns
/// * Vector of (effect_name, Option<MiningResult>) tuples
pub fn mine_multiple(
    createx_address: Address,
    effects: Vec<(String, u16)>,
    max_attempts_per_effect: u64,
) -> Vec<(String, Option<MiningResult>)> {
    effects
        .into_par_iter()
        .map(|(name, bitmap)| {
            // Use effect name as part of base salt for reproducibility
            let mut base_bytes = [0u8; 32];
            let name_bytes = name.as_bytes();
            let copy_len = std::cmp::min(name_bytes.len(), 20);
            base_bytes[..copy_len].copy_from_slice(&name_bytes[..copy_len]);
            let base_salt = B256::from(base_bytes);

            let result = mine_salt(createx_address, bitmap, Some(base_salt), max_attempts_per_effect);
            (name, result)
        })
        .collect()
}

/// Estimate the expected number of attempts to find a matching address
/// For a 9-bit bitmap, we expect to try ~512 addresses on average
pub fn expected_attempts() -> u64 {
    512 // 2^9
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn test_mine_salt() {
        let createx = Address::from_str("0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed").unwrap();

        // Mine for bitmap 0x042 (StaminaRegen: RoundEnd + AfterMove)
        let result = mine_salt(createx, 0x042, None, 100_000);

        assert!(result.is_some(), "Should find a salt within 100k attempts");
        let result = result.unwrap();
        assert_eq!(result.bitmap, 0x042);
        println!(
            "Found salt {:?} -> address {:?} in {} attempts",
            result.salt, result.address, result.attempts
        );
    }

    #[test]
    fn test_mine_multiple() {
        let createx = Address::from_str("0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed").unwrap();

        let effects = vec![
            ("StaminaRegen".to_string(), 0x042u16),
            ("StatBoosts".to_string(), 0x008u16),
        ];

        let results = mine_multiple(createx, effects, 100_000);

        for (name, result) in results {
            assert!(result.is_some(), "Should find salt for {}", name);
            let r = result.unwrap();
            println!("{}: salt={:?}, address={:?}", name, r.salt, r.address);
        }
    }
}
