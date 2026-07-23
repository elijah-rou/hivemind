use chacha20poly1305::{
    aead::{rand_core::RngCore, Aead, KeyInit, OsRng, Payload},
    XChaCha20Poly1305, XNonce,
};
use hkdf::Hkdf;
use sha2::Sha256;

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 24;
pub const TAG_LEN: usize = 16;
pub const ENCRYPTED_OVERHEAD: usize = 1 + NONCE_LEN + TAG_LEN; // flags + nonce + tag

pub struct EncryptionState {
    pub enabled: bool,
    pub worker_key: [u8; KEY_LEN],
}

impl EncryptionState {
    pub fn from_hex(hex: &str) -> Result<Self, &'static str> {
        if hex.len() != 64 {
            return Err("key must be 64 hex chars (32 bytes)");
        }
        let mut psk = [0u8; KEY_LEN];
        hex_decode(hex, &mut psk).map_err(|_| "invalid hex")?;

        let hk = Hkdf::<Sha256>::new(Some(b"hivemind-v1"), &psk);
        let mut worker_key = [0u8; KEY_LEN];
        hk.expand(b"hivemind-agent-v1", &mut worker_key)
            .map_err(|_| "hkdf expand failed")?;

        Ok(Self {
            enabled: true,
            worker_key,
        })
    }

    pub fn disabled() -> Self {
        Self {
            enabled: false,
            worker_key: [0u8; KEY_LEN],
        }
    }
}

/// Encrypt plaintext. Returns Vec containing [nonce(24)][ciphertext][tag(16)].
pub fn encrypt_frame(key: &[u8; KEY_LEN], plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let mut nonce_bytes = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = XNonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(
            nonce,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .expect("encryption failed");

    let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    out
}

/// Decrypt encrypted_data = [nonce(24)][ciphertext][tag(16)].
/// Returns plaintext or error.
pub fn decrypt_frame(
    key: &[u8; KEY_LEN],
    encrypted_data: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, &'static str> {
    if encrypted_data.len() < NONCE_LEN + TAG_LEN {
        return Err("frame too short");
    }

    let nonce = XNonce::from_slice(&encrypted_data[..NONCE_LEN]);
    let ciphertext_and_tag = &encrypted_data[NONCE_LEN..];

    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(
            nonce,
            Payload {
                msg: ciphertext_and_tag,
                aad,
            },
        )
        .map_err(|_| "authentication failed")
}

fn hex_decode(hex: &str, out: &mut [u8]) -> Result<(), ()> {
    if hex.len() != out.len() * 2 {
        return Err(());
    }
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).map_err(|_| ())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_PSK: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

    #[test]
    fn encrypt_decrypt_round_trip() {
        let state = EncryptionState::from_hex(TEST_PSK).unwrap();
        let plaintext = b"hello hivemind frame data";
        let aad = &[0x20, 0x00, 0x00, 0x00, 0x01];

        let encrypted = encrypt_frame(&state.worker_key, plaintext, aad);
        assert!(encrypted.len() > plaintext.len());

        let decrypted = decrypt_frame(&state.worker_key, &encrypted, aad).unwrap();
        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }

    #[test]
    fn wrong_key_fails() {
        let state = EncryptionState::from_hex(TEST_PSK).unwrap();
        let plaintext = b"secret";
        let aad = &[0x01];

        let encrypted = encrypt_frame(&state.worker_key, plaintext, aad);

        // Derive a different key
        let mut wrong_key = [0u8; KEY_LEN];
        wrong_key[0] = 0xFF;
        let result = decrypt_frame(&wrong_key, &encrypted, aad);
        assert!(result.is_err());
    }

    #[test]
    fn wrong_aad_fails() {
        let state = EncryptionState::from_hex(TEST_PSK).unwrap();
        let plaintext = b"data";
        let aad1 = &[0x01];
        let aad2 = &[0x02];

        let encrypted = encrypt_frame(&state.worker_key, plaintext, aad1);
        let result = decrypt_frame(&state.worker_key, &encrypted, aad2);
        assert!(result.is_err());
    }

    #[test]
    fn hkdf_worker_key_is_deterministic() {
        // Cross-language agreement is owned by tests/wire/contract-v6.json consumers.
        let state = EncryptionState::from_hex(TEST_PSK).unwrap();

        // Deterministic: same PSK always produces same key
        let state2 = EncryptionState::from_hex(TEST_PSK).unwrap();
        assert_eq!(state.worker_key, state2.worker_key);

        // Key is non-zero and derived (not just the raw PSK)
        assert_ne!(state.worker_key, [0u8; KEY_LEN]);
        assert_ne!(
            &state.worker_key[..16],
            &[
                0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
                0x0e, 0x0f
            ]
        );
    }

    #[test]
    fn invalid_hex_rejected() {
        assert!(EncryptionState::from_hex("tooshort").is_err());
        assert!(EncryptionState::from_hex(
            "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"
        )
        .is_err());
    }
}
