//! JSON-RPC 2.0 协议编解码与分帧。
//! 对应 Erlang 端的 ssh_ipc_proto.erl。
//!
//! 协议规定：
//!   - 消息格式：JSON-RPC 2.0，每条消息以 \n 分隔
//!   - 有 id 的消息为 request（Ruby→Rust）或 response（双向）
//!   - 无 id 的消息为 notification（推送，Rust→Ruby）
//!   - 最大消息 2MB

use serde_json::{Map, Value};

/// 协议版本
pub const PROTOCOL_VER: &str = "1.0";
/// 消息分隔符
pub const MSG_DELIMITER: u8 = b'\n';
/// 最大消息大小（2MB）
pub const MAX_MSG_SIZE: usize = 2 * 1024 * 1024;

/// 编码 JSON-RPC 请求（带 id 和 method）
pub fn encode_request(id: i64, method: &str, params: &Value) -> String {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    })
    .to_string()
}

/// 编码 JSON-RPC 成功响应
pub fn encode_response(id: i64, result: &Value) -> String {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
    .to_string()
}

/// 编码 JSON-RPC 错误响应
pub fn encode_error(id: i64, code: i64, message: &str) -> String {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message
        }
    })
    .to_string()
}

/// 编码推送通知（无 id）
pub fn encode_push(method: &str, params: &Value) -> String {
    serde_json::json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params
    })
    .to_string()
}

/// 给消息追加帧分隔符
pub fn frame(msg: &str) -> Vec<u8> {
    let mut data = msg.as_bytes().to_vec();
    data.push(MSG_DELIMITER);
    data
}

/// 从缓冲区中分割出完整帧。
/// 返回 (完整帧列表, 剩余不完整数据)
pub fn unframe(buffer: &[u8]) -> (Vec<Vec<u8>>, Vec<u8>) {
    let mut frames = Vec::new();
    let mut start = 0;

    for (i, &byte) in buffer.iter().enumerate() {
        if byte == MSG_DELIMITER {
            // 检查前面是否有 \r（处理 \r\n 的情况）
            let end = if i > start && buffer[i - 1] == b'\r' {
                i - 1
            } else {
                i
            };
            if end > start {
                frames.push(buffer[start..end].to_vec());
            }
            start = i + 1;
        }
    }

    let rest = if start < buffer.len() {
        buffer[start..].to_vec()
    } else {
        Vec::new()
    };

    (frames, rest)
}

/// 消息分类
#[derive(Debug, Clone)]
pub enum Message {
    /// Ruby→Rust 请求（有 id 和 method）
    Request { id: i64, method: String, params: Value },
    /// 对 Rust→Ruby 反向请求的响应（有 id，无 method）
    Response { id: i64, result: Option<Value>, error: Option<Value> },
    /// 推送通知（无 id，有 method）
    Notification { method: String, params: Value },
}

/// 解码一条 JSON-RPC 消息
pub fn decode(data: &[u8]) -> Result<Message, String> {
    let text = std::str::from_utf8(data).map_err(|e| format!("utf8 error: {}", e))?;
    let val: Value = serde_json::from_str(text).map_err(|e| format!("json error: {}", e))?;

    let obj = val.as_object().ok_or("not a json object")?;

    // 校验 jsonrpc 版本
    let ver = obj
        .get("jsonrpc")
        .and_then(|v| v.as_str())
        .ok_or("missing jsonrpc field")?;
    if ver != "2.0" {
        return Err(format!("unsupported jsonrpc version: {}", ver));
    }

    let id = obj.get("id");

    match id {
        Some(id_val) => {
            let id_num = id_val.as_i64().ok_or("id is not an integer")?;

            if obj.contains_key("method") {
                // 有 id 和 method → Ruby→Rust 请求
                let method = obj
                    .get("method")
                    .and_then(|v| v.as_str())
                    .ok_or("method not a string")?
                    .to_string();
                let params = obj.get("params").cloned().unwrap_or(Value::Null);
                Ok(Message::Request {
                    id: id_num,
                    method,
                    params,
                })
            } else {
                // 有 id 无 method → 反向 RPC 的响应
                let result = obj.get("result").cloned();
                let error = obj.get("error").cloned();
                Ok(Message::Response {
                    id: id_num,
                    result,
                    error,
                })
            }
        }
        None => {
            // 无 id → 推送通知
            let method = obj
                .get("method")
                .and_then(|v| v.as_str())
                .ok_or("notification missing method")?
                .to_string();
            let params = obj.get("params").cloned().unwrap_or(Value::Null);
            Ok(Message::Notification { method, params })
        }
    }
}

/// 从 Value 中提取字符串字段（兼容 String key）
pub fn get_str<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(|v| v.as_str())
}

/// 从 Value 中提取数值字段
pub fn get_num(params: &Value, key: &str) -> Option<f64> {
    params.get(key).and_then(|v| v.as_f64())
}

/// 从 Value 中提取布尔字段
pub fn get_bool(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|v| v.as_bool())
}

/// 构建成功响应的 params（Erlang 风格 {ok, #{}}
pub fn ok_result(fields: Map<String, Value>) -> Value {
    Value::Object(fields)
}

/// 构建简单 ok 响应
pub fn ok_true() -> Value {
    serde_json::json!({"ok": true})
}

/// 构建错误对象
pub fn error_obj(message: &str) -> Value {
    serde_json::json!({"message": message})
}
