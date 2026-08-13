//! 编解码工具：Base64、ID 生成、SHA-256 指纹。
//! 对应 Erlang 端的 ssh_codec.erl。

use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

/// 当前 Unix 时间戳（毫秒）
pub fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Base64 编码
pub fn encode_b64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// Base64 解码
pub fn decode_b64(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    base64::engine::general_purpose::STANDARD.decode(s)
}

/// 生成连接 ID: conn_<unix_ms>_<8hex>
pub fn gen_conn_id() -> String {
    let ts = unix_ms();
    let mut buf = [0u8; 4];
    rand::thread_rng().fill_bytes(&mut buf);
    let rand_hex: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
    format!("conn_{}_{}", ts, rand_hex)
}

/// 生成通道 ID: ch_<conn_short>_<seq>
pub fn gen_channel_id(conn_id: &str) -> String {
    let conn_short: String = conn_id.chars().take(16).collect();
    let seq = unix_ms() % 100_000;
    format!("ch_{}_{}", conn_short, seq)
}

/// 生成 SFTP 会话 ID: sftp_<conn_short>_<ts>
pub fn gen_sftp_id(conn_id: &str) -> String {
    let conn_short: String = conn_id.chars().take(16).collect();
    let ts = unix_ms();
    format!("sftp_{}_{}", conn_short, ts)
}

/// 生成端口转发规则 ID: fwd_<conn_short>_<seq>
pub fn gen_rule_id(conn_id: &str) -> String {
    let conn_short: String = conn_id.chars().take(16).collect();
    let ts = unix_ms();
    format!("fwd_{}_{}", conn_short, ts)
}

/// 计算公钥的 SHA-256 指纹（OpenSSH 格式）。
/// 输入为公钥的 DER 编码字节。
pub fn fingerprint(public_key_der: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(public_key_der);
    let hash = hasher.finalize();
    format!("SHA256:{}", encode_b64(&hash))
}

/// 生成认证 Token（32 字节随机数 Base64 编码）
pub fn gen_auth_token() -> String {
    let mut buf = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buf);
    encode_b64(&buf)
}
