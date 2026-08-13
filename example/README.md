
# Example

存放常用场景的**功能用例**（区别于 `spec/` 的原子能力验证）。

- 用例文件以 `_example.rb` 结尾，可被 `rake example` 或 `rspec example/` 直接执行。
- 复用 `spec/spec_helper.rb`（`.rspec` 中 `--require spec_helper` 对本目录同样生效）。
- 编写时从真实使用视角组织：端到端调用、典型参数组合、跨层协作场景等。

## SSH 用例（example/ssh/）

| 文件 | 说明 |
|---|---|
| `auto_demo_example.rb` | 非交互式：自动连接 WSL 执行预设命令序列（whoami/uname/ip/df/free 等），退出时自动生成原始日志 + ANSI 清洗后的纯文本日志 |
| `interactive_session_example.rb` | 交互式：连接 WSL 进入实时终端，手动敲命令，退出时自动生成 3 份日志（原始/raw + 清洗/clean + 带时间戳/timestamped） |

两个脚本均在项目根目录执行：
```
ruby example/ssh/auto_demo_example.rb
ruby example/ssh/interactive_session_example.rb
```

日志输出到 `.temp/` 目录，不污染项目根目录。