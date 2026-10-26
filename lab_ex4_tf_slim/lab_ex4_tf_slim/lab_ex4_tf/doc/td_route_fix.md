# TD 6.2.1 布线冲突修复

当前工程：`src/td_project/lab_ex5_i2s_v1.0.al`。

## 为什么清理后仍然报错

保留工程中的两个 FIFO IP 时序约束后，默认物理布局可复现
`PHY-8023`：`u_scanner/mux123_syn_2[0]` 与
`u_scanner/mux741_syn_2[2]` 争用 `x20y10_local5`，随后出现
`RUN-8102`。相同冲突也能在从源码开始的独立构建中复现，所以
Clean/Reset 本身不能解决。综合报告 LUT 占用约 80.17%，没有超出
器件总容量；总容量足够也不代表局部布线一定可行。

修复采用 TD 官方 CongestionHigh 参数，已保存到 `.al` 的
`phy_1/Strategy` 与 `phy_1/UserParams`，无需安装用户目录中的策略文件。
参数包括较低的布局密度、增强全局布局、拥塞恢复及布局/布线后优化。
FIFO IP 时序约束保留，没有通过删除约束规避报错。

## 在 TD GUI 中重新编译

1. 重新打开上述 `.al`，使 TD 读取磁盘上的新参数。如果旧工程仍在
   GUI 中打开，不要用旧会话保存并覆盖这次工程配置。
2. 对 `phy_1` 和 `syn_1` 执行 Clean/Reset，再从综合开始运行到 bitgen。
3. 新物理日志应出现 `set_param place target_density 0.6`、
   `set_param place enhanced_gp on`、
   `set_param place enable_congestion_recovery on` 等参数。
   不能仅凭策略名判断设置已生效。

## 独立完整编译

在仓库根目录的 PowerShell 中运行：

```powershell
Push-Location tests
try {
    & 'F:\anlu TD6.2.1\bin\td_commands_prompt.exe' build_bitstream.tcl
} finally {
    Pop-Location
}
```

此流程从当前源码开始综合，读取主时序约束及两个 FIFO IP 约束，
从工程加载相同物理参数，输出 `tests/td_build/player_fixed.bit`。
以末尾 `PASS: fresh source-to-bitstream implementation completed` 和
本次 bit 文件时间戳共同判断成功；失败时旧 bit 文件可能仍存在。

## 显示验证与限制

本次修复仅调整编译配置，未修改音量显示、像素通路或 SDRAM RTL。
`tests/run_audio_waveform.do` 已通过，覆盖右侧生成、向左移动、
高度衰减、间隙透明、噪声门限、孤立尖峰抑制和重新启用后的旧数据屏蔽。

布线/bitgen 成功不等于时序全部通过，也不能替代上板无噪点验证。
最终时序请查看 `tests/td_build/player_fixed_pr.timing`；不要通过全局
屏蔽跨时钟路径掩盖违例。

## 最终验证记录（2026-10-21）

最终完整构建使用工程内保存的参数，保持 `route fix_hold` 默认开启，
没有在脚本中重复设置拥塞参数。综合、布局、布线和 bitgen 完成，
无 `PHY-8023` / `RUN-8102` / ERROR；终端输出构建 PASS。

- 构建日志：`tests/td_20261021_115032.log`。
- 输出：`tests/td_build/player_fixed.bit`，11:58:50 生成，642428 字节。
- SHA256：`7E74FA037E2F4CB1C6BD38FE1D99D9A52E7FE5AA747098B84A1E0A9793914A02`。
- 全局 setup WNS：−0.357 ns；hold WNS：−1.578 ns，时序尚未全部通过。
- 视频时钟域报告 setup WNS：+5.078 ns；hold WNS：+0.036 ns。
- 仍有 `PHY-7002` SDRAM 初始位置调整和 `PHY-5079` 局部时钟布线警告。
- 显示仿真日志：`tests/audio_waveform_regression.log`，0 errors、0 warnings。

本次没有进行开发板下载或实际画面测试。
