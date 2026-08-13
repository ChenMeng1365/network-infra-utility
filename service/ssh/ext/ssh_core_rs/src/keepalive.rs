//! 保活管理器 — 周期性检查所有活动连接，发送 keepalive 心跳。
//! 对应 Erlang 端的 ssh_keepalive_mgr.erl。
//!
//! 核心设计（与 Erlang 端完全对齐）：
//!   - 定时扫描所有 Ready 状态的连接，发送 keepalive 全局请求
//!   - 连续 KEEPALIVE_MAX_FAIL（3）次失败 → 推送 conn.closed
//!   - 重连决策由 Ruby 决定（通过 conn.reconnect RPC），核心不自主重连
//!   - 活动感知：有数据流时跳过心跳（简化版：由 channel.rs 通知活动）
//!
//! RPC 方法：
//!   - keepalive.set_interval：设置心跳间隔
//!   - keepalive.get_interval：获取当前间隔
//!   - keepalive.get_status：获取所有连接的保活状态

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{Mutex, RwLock};
use tracing::{debug, warn};

use crate::codec;
use crate::conn::ConnManager;
use crate::gateway::Gateway;
use crate::proto;

/// 默认保活间隔（毫秒）
const KEEPALIVE_DEFAULT_INTERVAL_MS: u64 = 30_000;

/// 最大连续失败次数
const KEEPALIVE_MAX_FAIL: u32 = 3;

/// 保活管理器
pub struct KeepaliveMgr {
    /// 心跳间隔（毫秒）
    interval_ms: RwLock<u64>,
    /// 失败计数：conn_id → count
    fail_counts: Mutex<HashMap<String, u32>>,
    /// 最近活动时间戳：conn_id → unix_ms
    last_activity: Mutex<HashMap<String, u64>>,
    /// 上次检查时间戳：conn_id → unix_ms
    last_check: Mutex<HashMap<String, u64>>,
    /// 连接管理器引用
    conn_mgr: Arc<ConnManager>,
    /// 网关引用
    gateway: Arc<Gateway>,
}

impl KeepaliveMgr {
    pub fn new(conn_mgr: Arc<ConnManager>, gateway: Arc<Gateway>) -> Arc<Self> {
        Arc::new(Self {
            interval_ms: RwLock::new(KEEPALIVE_DEFAULT_INTERVAL_MS),
            fail_counts: Mutex::new(HashMap::new()),
            last_activity: Mutex::new(HashMap::new()),
            last_check: Mutex::new(HashMap::new()),
            conn_mgr,
            gateway,
        })
    }

    /// 启动保活循环
    pub fn start(self: &Arc<Self>) {
        let this = Arc::clone(self);
        tokio::spawn(async move {
            this.run_loop().await;
        });
    }

    /// 保活主循环
    async fn run_loop(&self) {
        loop {
            let ms = *self.interval_ms.read().await;
            tokio::time::sleep(Duration::from_millis(ms)).await;
            self.tick().await;
        }
    }

    /// 单次保活检查
    async fn tick(&self) {
        let now = codec::unix_ms();
        let conn_ids = self.conn_mgr.ready_conn_ids().await;

        // 记录检查时间
        {
            let mut checks = self.last_check.lock().await;
            for id in &conn_ids {
                checks.insert(id.clone(), now);
            }
        }

        for conn_id in &conn_ids {
            self.check_keepalive(conn_id).await;
        }

        // 清理已断开的连接
        let active_ids: std::collections::HashSet<String> = conn_ids.into_iter().collect();
        {
            let mut fails = self.fail_counts.lock().await;
            fails.retain(|k, _| active_ids.contains(k));
        }
        {
            let mut acts = self.last_activity.lock().await;
            acts.retain(|k, _| active_ids.contains(k));
        }
    }

    /// 检查单个连接的保活
    async fn check_keepalive(&self, conn_id: &str) {
        // 发送 keepalive 全局请求
        let handle = self.conn_mgr.get_handle(conn_id).await;
        if handle.is_none() {
            // 连接已断开
            return;
        }
        let handle = handle.unwrap();

        let result = handle
            .send_keepalive(true)
            .await;

        match result {
            Ok(_) => {
                // 成功——重置失败计数
                self.fail_counts.lock().await.remove(conn_id);
                debug!("keepalive ok for conn {}", conn_id);
            }
            Err(e) => {
                let mut fails = self.fail_counts.lock().await;
                let count = fails.entry(conn_id.to_string()).or_insert(0);
                *count += 1;

                if *count >= KEEPALIVE_MAX_FAIL {
                    warn!(
                        "conn {} keepalive failed {}/{}: {}, marking closed",
                        conn_id, *count, KEEPALIVE_MAX_FAIL, e
                    );
                    drop(fails);
                    self.conn_mgr
                        .mark_conn_closed(conn_id, "keepalive_failed")
                        .await;
                } else {
                    warn!(
                        "conn {} keepalive failed {}/{}: {}",
                        conn_id, *count, KEEPALIVE_MAX_FAIL, e
                    );
                }
            }
        }
    }

    /// 通知活动（由 channel.rs 在数据收发时调用）
    pub async fn notify_activity(&self, conn_id: &str) {
        let now = codec::unix_ms();
        self.last_activity.lock().await.insert(conn_id.to_string(), now);
        self.fail_counts.lock().await.remove(conn_id);
    }

    /// RPC: keepalive.set_interval
    pub async fn rpc_set_interval(&self, params: Value) -> Result<Value, String> {
        let interval_ms = proto::get_num(&params, "interval_ms")
            .ok_or("missing interval_ms")? as u64;
        *self.interval_ms.write().await = interval_ms;
        Ok(json!({"ok": true}))
    }

    /// RPC: keepalive.get_interval
    pub async fn rpc_get_interval(&self, _params: Value) -> Result<Value, String> {
        let ms = *self.interval_ms.read().await;
        Ok(json!({"interval_ms": ms}))
    }

    /// RPC: keepalive.get_status
    pub async fn rpc_get_status(&self, _params: Value) -> Result<Value, String> {
        let fails = self.fail_counts.lock().await;
        let acts = self.last_activity.lock().await;
        let checks = self.last_check.lock().await;

        let conn_ids = self.conn_mgr.all_conn_ids().await;
        let status: Vec<Value> = conn_ids
            .iter()
            .map(|id| {
                json!({
                    "conn_id": id,
                    "fail_count": fails.get(id).copied().unwrap_or(0),
                    "last_activity": acts.get(id).copied().unwrap_or(0),
                    "last_check": checks.get(id).copied().unwrap_or(0),
                })
            })
            .collect();

        Ok(json!({"connections": status}))
    }
}
