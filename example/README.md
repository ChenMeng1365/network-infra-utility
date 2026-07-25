
# Example

存放常用场景的**功能用例**（区别于 `spec/` 的原子能力验证）。

- 用例文件以 `_spec.rb` 结尾，可被 `rake example` 或 `rspec example/` 直接执行。
- 复用 `spec/spec_helper.rb`（`.rspec` 中 `--require spec_helper` 对本目录同样生效）。
- 编写时从真实使用视角组织：端到端调用、典型参数组合、跨层协作场景等。
