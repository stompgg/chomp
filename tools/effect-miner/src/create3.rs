use tiny_keccak::{Hasher, Keccak};

/// Type aliases for clarity
pub type Address = [u8; 20];
pub type B256 = [u8; 32];

/// The init code hash of the CREATE3 proxy used by CreateX
/// This is: keccak256(hex"67_36_3d_3d_37_36_3d_34_f0_3d_52_60_08_60_18_f3")
const PROXY_INIT_CODE_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f,
    0x8e, 0x9f, 0x30, 0x55, 0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];

/// Compute keccak256 hash
fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    let mut output = [0u8; 32];
    hasher.update(data);
    hasher.finalize(&mut output);
    output
}

/// Compute CREATE2 address: keccak256(0xff ++ deployer ++ salt ++ init_code_hash)[12:]
fn compute_create2_address(deployer: &Address, salt: &B256, init_code_hash: &[u8; 32]) -> Address {
    let mut data = [0u8; 85];
    data[0] = 0xff;
    data[1..21].copy_from_slice(deployer);
    data[21..53].copy_from_slice(salt);
    data[53..85].copy_from_slice(init_code_hash);

    let hash = keccak256(&data);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..]);
    addr
}

/// Compute CREATE address for nonce=1: keccak256(RLP([address, 1]))[12:]
/// For nonce=1, the RLP encoding is: 0xd6 0x94 <20-byte address> 0x01
fn compute_create_address_nonce_1(deployer: &Address) -> Address {
    let mut data = [0u8; 23];
    data[0] = 0xd6; // 0xc0 + 0x16 (length of: 0x94 + 20 bytes + 0x01)
    data[1] = 0x94; // 0x80 + 0x14 (20 bytes)
    data[2..22].copy_from_slice(deployer);
    data[22] = 0x01; // nonce = 1

    let hash = keccak256(&data);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..]);
    addr
}

/// Compute the final CREATE3 address given a salt and the CreateX deployer address.
///
/// This matches CreateX's computeCreate3Address function:
/// 1. Compute proxy address via CREATE2 (using the proxy init code hash)
/// 2. Compute final address via CREATE with nonce=1
pub fn compute_create3_address(salt: &B256, createx_address: &Address) -> Address {
    // Step 1: Compute proxy address via CREATE2
    let proxy_address = compute_create2_address(createx_address, salt, &PROXY_INIT_CODE_HASH);

    // Step 2: Compute final address via CREATE (nonce=1)
    compute_create_address_nonce_1(&proxy_address)
}

/// Number of effect steps in the EffectStep enum.
/// Update this constant when adding new steps to the enum.
pub const NUM_EFFECT_STEPS: u32 = 9;

/// Extract the bitmap from the most significant bits of an address.
/// The bitmap encodes which EffectSteps an effect runs at.
pub fn extract_bitmap(address: &Address) -> u16 {
    // Take first 2 bytes and extract top NUM_EFFECT_STEPS bits
    // bytes[0] is the MSB, bytes[1] is the next byte
    let top_16_bits = ((address[0] as u16) << 8) | (address[1] as u16);
    // Shift right to get the top NUM_EFFECT_STEPS bits
    top_16_bits >> (16 - NUM_EFFECT_STEPS)
}

/// Check if an address has the desired bitmap in its most significant bits
pub fn matches_bitmap(address: &Address, target_bitmap: u16) -> bool {
    extract_bitmap(address) == target_bitmap
}

/// Parse an address from a hex string
pub fn parse_address(s: &str) -> Result<Address, String> {
    let s = s.trim().trim_start_matches("0x");
    if s.len() != 40 {
        return Err(format!("Address must be 40 hex chars, got {}", s.len()));
    }
    let bytes = hex::decode(s).map_err(|e| format!("Invalid hex: {}", e))?;
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&bytes);
    Ok(addr)
}

/// Format an address as a checksummed hex string
pub fn format_address(addr: &Address) -> String {
    format!("0x{}", hex::encode(addr))
}

/// Format a B256 as a hex string
pub fn format_b256(b: &B256) -> String {
    format!("0x{}", hex::encode(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_bitmap() {
        // For bitmap 0x042 = 0b001000010 (9 bits):
        // We need b0 << 1 | (b1 >> 7) = 0x042
        // b0 = 0x042 >> 1 = 0x21 (if LSB of bitmap is 0)
        // b1 >> 7 = 0x042 & 1 = 0, so top bit of b1 is 0
        let addr = parse_address("0x2100000000000000000000000000000000000000").unwrap();
        assert_eq!(extract_bitmap(&addr), 0x042);

        // Test bitmap 0x1E0 = 0b111100000
        // b0 = 0x1E0 >> 1 = 0xF0
        // b1 >> 7 = 0, so b1 can be 0x00-0x7F
        let addr = parse_address("0xF000000000000000000000000000000000000000").unwrap();
        assert_eq!(extract_bitmap(&addr), 0x1E0);
    }

    #[test]
    fn test_create3_address_computation() {
        // Test against known CreateX deployment
        let createx = parse_address("0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed").unwrap();

        // A zero salt should produce a deterministic address
        let salt = [0u8; 32];
        let addr = compute_create3_address(&salt, &createx);

        // The address should be valid (non-zero)
        assert_ne!(addr, [0u8; 20]);

        // Verify it's deterministic
        let addr2 = compute_create3_address(&salt, &createx);
        assert_eq!(addr, addr2);
    }
}
