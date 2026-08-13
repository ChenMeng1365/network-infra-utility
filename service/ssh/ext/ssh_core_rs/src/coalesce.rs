//! 高频数据合并器 — 8ms tick 或 16KB watermark 刷新 batch。
//! 对应 Erlang 端的 ssh_ipc_coalesce.erl。
//!
//! 核心设计（与 Erlang 端完全对齐）：
//!   - 每个通道的数据通过 enqueue() 添加到 buffer
//!   - 每 COALESCE_TICK_MS（8ms）定时刷出一个 channel.data.batch 推送
//!   - 当 buffer 总大小达到 COALESCE_WATERMARK_BYTES（16KB）时立即刷新
//!   - flush_channel() 用于通道关闭时单独 flush 该通道的剩余数据

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::sync::Mutex;
use tokio::time::{interval, Duration};
use tracing::trace;

use crate::codec;
use crate::gateway::Gateway;

/// 合并 tick 间隔（毫秒）
const COALESCE_TICK_MS: u64 = 8;

/// 合并 watermark（字节）
const COALESCE_WATERMARK_BYTES: usize = 16 * 1024;

/// 缓冲区中单个通道的数据
struct ChannelBuffer {
    /// 累积的数据块
    data: Vec<u8>,
}

/// 合并器状态
struct CoalesceState {
    /// channel_id → buffer
    buffer: HashMap<String, ChannelBuffer>,
    /// 缓冲区总大小
    total_size: usize,
}

/// 合并器
pub struct Coalescer {
    state: Mutex<CoalesceState>,
    gateway: Arc<Gateway>,
}

impl Coalescer {
    pub fn new(gateway: Arc<Gateway>) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(CoalesceState {
                buffer: HashMap::new(),
                total_size: 0,
            }),
            gateway,
        })
    }

    /// 启动定时 flush 循环
    pub fn start(self: &Arc<Self>) {
        let this = Arc::clone(self);
        tokio::spawn(async move {
            let mut ticker = interval(Duration::from_millis(COALESCE_TICK_MS));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

            loop {
                ticker.tick().await;
                this.flush().await;
            }
        });
    }

    /// 入队数据（由 channel.rs 调用）
    pub async fn enqueue(&self, channel_id: &str, data: Vec<u8>) {
        let mut state = self.state.lock().await;

        let entry = state
            .buffer
            .entry(channel_id.to_string())
            .or_insert(ChannelBuffer { data: Vec::new() });
        entry.data.extend_from_slice(&data);
        state.total_size += data.len();

        // 达到 watermark 立即 flush
        if state.total_size >= COALESCE_WATERMARK_BYTES {
            drop(state);
            self.flush().await;
        }
    }

    /// 刷出所有通道的累积数据为 channel.data.batch 推送
    pub async fn flush(&self) {
        let mut state = self.state.lock().await;
        if state.buffer.is_empty() {
            return;
        }

        // 取出 buffer
        let buffer = std::mem::take(&mut state.buffer);
        state.total_size = 0;
        drop(state);

        // 构建 batch items
        let items: Vec<Value> = buffer
            .into_iter()
            .map(|(ch_id, buf)| {
                let b64 = codec::encode_b64(&buf.data);
                json!({
                    "id": ch_id,
                    "data": b64
                })
            })
            .collect();

        if !items.is_empty() {
            trace!("coalesce flush: {} channels", items.len());
            self.gateway
                .push_batch(json!({ "items": items }))
                .await;
        }
    }

    /// 单独 flush 指定通道的剩余数据（通道关闭时调用）
    pub async fn flush_channel(&self, channel_id: &str) {
        let mut state = self.state.lock().await;

        if let Some(buf) = state.buffer.remove(channel_id) {
            state.total_size = state.total_size.saturating_sub(buf.data.len());

            let b64 = codec::encode_b64(&buf.data);
            drop(state);

            // 单独推送该通道的数据
            self.gateway
                .push_batch(json!({
                    "items": [{
                        "id": channel_id,
                        "data": b64
                    }]
                }))
                .await;
        }
    }
}
