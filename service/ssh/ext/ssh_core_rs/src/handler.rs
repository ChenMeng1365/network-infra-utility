//! russh Handler 实现 — SSH 协议事件回调，桥接到 IPC 推送。
//! 对应 dssh/src/handler.rs + Erlang 端 channel_stm 的数据推送逻辑。
//!
//! 架构说明：
//!   russh 0.61.2 的 Handler trait 使用 `&mut self`（引用），方法返回
//!   `Result<(), Self::Error>`。handler 持有 Arc<ConnShared>，通过共享状态
//!   将通道数据推送到 channel.rs 的接收循环，将连接事件推送到 conn.rs 的事件循环。

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;

use russh::client;
use russh::keys::HashAlg;
use russh::keys::PublicKey;
use russh::ChannelId;
use serde_json::json;
use tokio::sync::{mpsc, RwLock};
use tracing::{debug, warn};

use crate::gateway::Gateway;

/// 连接级事件（从 handler 转发到连接管理器的事件循环）
#[derive(Debug)]
pub enum ConnEvent {
    /// 连接被远端关闭
    Disconnected,
}

/// 单个通道的数据接收器。
/// channel.rs 在 open 时通过 register_channel_tx 注册，
/// handler 的 data/extended_data 回调通过此 tx 推送数据到 channel.rs 的接收循环。
pub type ChannelDataTx = mpsc::UnboundedSender<ChannelData>;

/// 来自 SSH 通道的数据消息
#[derive(Debug)]
pub enum ChannelData {
    /// 标准输出数据
    Stdout { data: Vec<u8> },
    /// 扩展数据（stderr 等）
    Extended { data: Vec<u8>, ext: u32 },
    /// 通道 EOF/关闭
    Eof { reason: String },
}

/// 连接级共享状态——由 handler 持有 Arc，在 &mut self 回调中共享
pub struct ConnShared {
    /// conn_id（用于推送和日志）
    pub conn_id: String,
    /// 主机地址（用于 hostkey.resolve）
    pub host: String,
    /// 端口（用于 hostkey.resolve）
    pub port: u16,
    /// IPC 网关（用于 check_server_key 反向 RPC）
    pub gateway: Arc<Gateway>,
    /// 通道数据发送器映射：russh ChannelId → channel.rs 的接收端
    channel_txs: RwLock<HashMap<ChannelId, ChannelDataTx>>,
    /// 连接级事件发送器（连接关闭等）
    conn_event_tx: mpsc::UnboundedSender<ConnEvent>,
    /// 服务器主机密钥指纹（check_server_key 回调中写入，authenticate 中读取）
    server_fingerprint: RwLock<Option<String>>,
}

impl ConnShared {
    pub fn new(
        conn_id: String,
        host: String,
        port: u16,
        gateway: Arc<Gateway>,
        conn_event_tx: mpsc::UnboundedSender<ConnEvent>,
    ) -> Arc<Self> {
        Arc::new(Self {
            conn_id,
            host,
            port,
            gateway,
            channel_txs: RwLock::new(HashMap::new()),
            conn_event_tx,
            server_fingerprint: RwLock::new(None),
        })
    }

    /// 注册通道数据发送器（channel.rs 在 channel.open 时调用）
    pub async fn register_channel_tx(&self, russh_ch_id: ChannelId, tx: ChannelDataTx) {
        self.channel_txs.write().await.insert(russh_ch_id, tx);
    }

    /// 注销通道数据发送器（channel.rs 在 channel.close 时调用）
    pub async fn unregister_channel_tx(&self, russh_ch_id: ChannelId) {
        self.channel_txs.write().await.remove(&russh_ch_id);
    }

    /// 向指定通道推送数据
    async fn send_channel_data(&self, channel: ChannelId, msg: ChannelData) {
        let txs = self.channel_txs.read().await;
        if let Some(tx) = txs.get(&channel) {
            if tx.send(msg).is_err() {
                debug!("conn {} channel {}: data rx dropped", self.conn_id, channel);
            }
        }
    }

    /// 获取服务器指纹（authenticate 完成后可读取）
    pub async fn get_server_fingerprint(&self) -> Option<String> {
        self.server_fingerprint.read().await.clone()
    }
}

/// russh Handler 实现
pub struct SshHandler {
    /// 共享状态 Arc——在 &mut self 回调中共享
    pub shared: Arc<ConnShared>,
}

impl SshHandler {
    pub fn new(shared: Arc<ConnShared>) -> Self {
        Self { shared }
    }
}

/// server key 验证超时（毫秒）
const HOSTKEY_RESOLVE_TIMEOUT_MS: u64 = 30_000;

/// russh 0.61.2 Handler trait 使用原生 AFIT（`fn -> impl Future` 返回类型）。
/// 不启用 async-trait 特性，方法用 `fn -> impl Future { async { ... } }` 风格实现。
impl client::Handler for SshHandler {
    type Error = russh::Error;

    fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> impl Future<Output = Result<bool, Self::Error>> + Send {
        async {
            let fingerprint = server_public_key
                .fingerprint(HashAlg::Sha256)
                .to_string();
            debug!(
                "conn {}: server key fingerprint: {}",
                self.shared.conn_id, fingerprint
            );

            // 存储指纹到共享状态（authenticate 完成后读取返回给 Ruby）
            *self.shared.server_fingerprint.write().await = Some(fingerprint.clone());

            // 通过反向 RPC 询问 Ruby 是否接受此主机密钥
            let resp = self
                .shared
                .gateway
                .synchronous_push(
                    "hostkey.resolve",
                    json!({
                        "host": self.shared.host,
                        "port": self.shared.port,
                        "fingerprint": fingerprint,
                    }),
                    HOSTKEY_RESOLVE_TIMEOUT_MS,
                )
                .await;

            let accepted = match resp {
                Ok(result) => {
                    let action = result
                        .get("action")
                        .and_then(|v| v.as_str())
                        .unwrap_or("reject");
                    match action {
                        "accept" => true,
                        "once" => true,
                        "reject" => false,
                        _ => {
                            warn!(
                                "conn {}: hostkey.resolve returned unknown action: {}, reject",
                                self.shared.conn_id, action
                            );
                            false
                        }
                    }
                }
                Err(e) => {
                    warn!(
                        "conn {}: hostkey.resolve failed: {}, reject (safe default)",
                        self.shared.conn_id, e
                    );
                    false
                }
            };

            if !accepted {
                warn!(
                    "conn {}: server key rejected by Ruby",
                    self.shared.conn_id
                );
            }
            Ok(accepted)
        }
    }

    fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        _session: &mut client::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        async move {
            tracing::trace!(
                "conn {} channel {}: {} bytes data",
                self.shared.conn_id,
                channel,
                data.len()
            );
            self.shared
                .send_channel_data(
                    channel,
                    ChannelData::Stdout { data: data.to_vec() },
                )
                .await;
            Ok(())
        }
    }

    fn extended_data(
        &mut self,
        channel: ChannelId,
        ext: u32,
        data: &[u8],
        _session: &mut client::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        async move {
            tracing::trace!(
                "conn {} channel {}: {} bytes extended data (ext={})",
                self.shared.conn_id,
                channel,
                data.len(),
                ext
            );
            self.shared
                .send_channel_data(
                    channel,
                    ChannelData::Extended { data: data.to_vec(), ext },
                )
                .await;
            Ok(())
        }
    }

    fn channel_close(
        &mut self,
        channel: ChannelId,
        _session: &mut client::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        async move {
            debug!("conn {} channel {}: close", self.shared.conn_id, channel);
            self.shared
                .send_channel_data(
                    channel,
                    ChannelData::Eof { reason: "channel_closed".to_string() },
                )
                .await;
            Ok(())
        }
    }

    fn channel_eof(
        &mut self,
        channel: ChannelId,
        _session: &mut client::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        async move {
            debug!("conn {} channel {}: eof", self.shared.conn_id, channel);
            self.shared
                .send_channel_data(
                    channel,
                    ChannelData::Eof { reason: "eof".to_string() },
                )
                .await;
            Ok(())
        }
    }

    fn disconnected(
        &mut self,
        reason: russh::client::DisconnectReason<Self::Error>,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        async move {
            warn!("conn {} disconnected by remote: {:?}", self.shared.conn_id, reason);
            let _ = self.shared.conn_event_tx.send(ConnEvent::Disconnected);
            match reason {
                russh::client::DisconnectReason::ReceivedDisconnect(_) => Ok(()),
                russh::client::DisconnectReason::Error(e) => Err(e),
            }
        }
    }
}
