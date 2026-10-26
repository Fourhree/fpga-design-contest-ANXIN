# TD 布线冲突修复（2026-10-21）

`PHY-8023` / `RUN-8102` 的修复、GUI 重编译步骤和验证限制见
[`../doc/td_route_fix.md`](../doc/td_route_fix.md)。拥塞优化参数已保存到
工程 `.al`，重新打开工程后生效。以下保留历史构建记录，以本次新日志
和新生成的 bit 文件时间戳为准。

# 当前缩略图与任意尺寸 BMP 回归（2026-10-10）

当前工程的图片功能请使用以下回归；操作与尺寸限制见
[`doc/thumbnail_display.md`](../doc/thumbnail_display.md)。

```powershell
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_thumbnail_regression.do -l thumbnail_regression.log
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_thumbnail_full_frame.do -l thumbnail_full_frame.log
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_sdram_address_contract.do -l sdram_address_contract.log
```

KEY2 短按松开启停自动轮播。
KEY1 下一张；KEY2 长按 1 秒上一张；先按住 KEY2 再按 KEY1 循环切换：四宫格缩略图 → 缩放全屏 → 原尺寸全屏。
支持未压缩 24 位 BMP，从文件头读取宽高，每张最多 307200 个像素。
宽高无需固定为 640×480，例如 320×960 或 800×384 均在容量范围内。
缩略图和缩放全屏使用最近邻采样并拉伸到目标区域；原尺寸全屏不缩放，
超出屏幕的部分裁剪，图片未覆盖的区域显示黑色。

当前回归覆盖动态解码、行填充、图片方向、写入末尾掩码、三种显示模式、
按键消抖与组合键、帧边界切换，以及真实加密 SDRAM 控制器的四字访问协议。
完整 640×480 显示测试逐像素检查缩略图与缩放全屏共 614400 个输出。

下文保留历次开发记录；旧 `tb_player_controls.sv` 使用早期接口，
`run_storage_regression.do` / `run_regression.do` 中的旧图片控制用例不适用于当前顶层。
最新构建仍需查看时序报告，生成 bit 文件不等于全工程时序通过。

当前源代码构建记录：TD 6.2.168116 于 2026-10-10 13:48:22 完成综合、
布局布线及位流生成。输出 [`td_build/player_fixed.bit`](td_build/player_fixed.bit)，
大小 629624 字节，SHA256：
`752D1A90A5677A36DFAEBAFCEF6B294FEA9F51A3E30C0738D0E328DEF5DCA638`。
最终 loader 修改后的紧凑回归通过；完整帧和真实 SDRAM 控制器测试使用当前
未再修改的 reader/layout，均已通过。

最终全局 setup WNS 为 −5.773 ns，hold WNS 为 +0.003 ns，无 hold 违例。
视频时钟域 setup 通过（含跨域路径 +1.535 ns）；存储同域 setup 为 −2.000 ns。
SD 域 WAV/FAT 路径、存储域 loader 写逻辑和跨域复位恢复仍有 setup 违例，
另有 SDRAM 局部时钟布线警告。报告见
[`td_build/player_fixed_pr.timing`](td_build/player_fixed_pr.timing)，构建日志见
[`td_20261010_count_pipeline.log`](td_20261010_count_pipeline.log)。
尚未下载到开发板验证；需要继续解决时序违例并上板确认，才能保证硬件稳定运行。

# 历史图片控制与 HDMI 音频回归

在本目录使用 ModelSim 运行：

```powershell
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_regression.do -l regression.log
```

用例覆盖：

- HDMI ACR 的保留字节、CTS/N 字节顺序，以及数据岛首像素的包边界位。
- 四张 BMP 扫描和首次提交；Key1 下一张；Key2 短按启停轮播、长按上一张、首尾循环、持续按住只触发一次。
- 图片加载超时后保留图片目录和原有画面；首次加载失败后也能通过按键或轮播尝试下一张。
- 真实 SPI 初始化、读取数据令牌超时、CMD17 错误、512 字节扇区读取，以及错误后的下一次读取恢复。
- 完整 HDMI 音频链经过实际 `video_timing_data` / `video_delay`，在 800×525 时序下持续发送 PCM、音频包和 ACR；切图后仍输出，垂直消隐没有视频前导/保护符，且无 FIFO 溢出或握手错误。

图片控制仿真使用真实 `sd_card_bmp` 和 `bmp_read`，模拟 SD 扇区接口及 SDRAM 写完成事件；按键时钟参数缩小到 1000 Hz。独立 SPI 用例使用真实 SD 状态机和 SPI 引脚上的卡模型，数据令牌等待上限缩小为 16 字节。音频仿真保持实际 25 MHz 像素时钟、48 kHz 采样率及默认音符/提示音时长，运行 25 帧（420 ms）；运行时间可能需要数分钟。

只运行存储与按键测试（另含帧写入测试）：

```powershell
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_storage_regression.do -l storage_regression.log
```

该回归还包含 `tb_bmp_header_validation`：通过完整扇区字节接口检查扫描和直接加载两条路径，覆盖 DIB 大小、平面数、像素偏移范围和最小文件长度的边界。新增严格校验后，18 项头部检查及原有按键、SPI 恢复、帧写入测试均通过。

帧写入用例使用真实 `frame_fifo_write` 和 FIFO 占用量模型，检查完整 640×480 帧的每个翻转地址、FIFO 边界，以及截断帧后的请求/应答重启。它不模拟 SDRAM 芯片电气时序。

独立顶层综合检查：

```powershell
& 'F:\anlu TD6.2.1\bin\td_commands_prompt.exe' check_synthesis.tcl
```

综合输出写入 `td_check`。从当前源代码完整生成独立下载文件：

```powershell
& 'F:\anlu TD6.2.1\bin\td_commands_prompt.exe' build_bitstream.tcl
```

输出为 `td_build/player_fixed.bit`，不替换 GUI 工程原有运行目录。请在下载器中明确选择这个文件。

2026-10-07 13:56 下载文件验证记录（早于新增 BMP 严格头部校验；要在板上使用新校验，需重新运行构建脚本并下载）：

- 格式、按键、SPI 故障恢复和帧写入测试通过。
- 实际视频时序音频测试通过：20159 个 PCM 采样、5039 个音频包、410 个 ACR 包；覆盖切图及默认旋律推进。
- 最终下载文件生成时间为 13:56:09，大小 629624 字节；SHA256 为 `423542DA0B8F7D3F1CCA05AD015DA29F24F20A815C2AA12EB47C5DFEF01CF048`。
- 最终布局布线中 SD、存储、视频和串行器各自时钟域的建立/保持检查通过。全局建立裕量仍为 -6.565 ns，剩余违例涉及 SDRAM 相移时钟路径及系统时钟到存储域；另有 SDRAM 时钟使用局部布线的警告。没有将这些路径统一屏蔽，不能称为全工程时序通过。

上板操作：Key1 下一张；Key2 短按并松开启停轮播（默认间隔 3 秒），按住至少 1 秒上一张。Key1 按下确认时间为 2 ms，松开需稳定 20 ms 后重新接受按下；Key2 消抖为 10 ms。

2026-10-08 图片响应优化：找到第一张有效 BMP 后暂停目录扫描，立即加载并显示首图，再继续搜索其余图片。四张图片分别常驻 SDRAM 的四个不重叠帧区（每帧 307200 个 32 位字，共 1228800 个字），发现后在后台加载；有效缓存只在完整源数据和 SDRAM 写完成均确认后置位。Key1、上一张和轮播访问已缓存图片时只切换显示地址，不再重读 TF 卡；尚未缓存或此前加载失败的图片仍走原有读取和重试流程。SD SPI 频率保持原值。此次按用户要求不运行仿真，旧控制用例对双缓冲及每次切图重读的假设不再适用于缓存模式；实际响应时间需上板确认。

本次 TD 完整构建成功，下载文件 `td_build/player_fixed.bit` 更新于 2026-10-08 19:39:51，大小 629624 字节，SHA256 为 `5468C89F239B0E676D48B7CB8CB9A106BE5C502C0C60F624903670CAF763CA8A`。最终全局 setup WNS 为 -6.565 ns（SD 域 -1.626 ns），hold WNS 为 +0.014 ns；仍存在建立时序违例和原有约束警告，不能视为时序全部通过。未进行仿真或上板测量。

数码管状态：`0` 为 SD 初始化；`d` 为扫描；`F` 为未找到图片；`8/9/A/b` 为加载第 1～4 张；`E` 为加载失败；`1～4` 为已提交显示的图片。实际声音和按键响应仍需下载此文件后确认；如异常，请记录停留状态和是否显示首图。

2026-10-08 20:22 FAT32 簇号/文件大小接入：

- `sd_card_bmp.v` 的图片目录改为 `img_cluster0～3`、`img_size0～3`，首图、下一张、上一张、轮播、跳过失败图片及后台缓存均同时设置 `load_cluster` 和 `load_file_size`。按键消抖、四帧缓存、完整帧提交、HDMI/音频控制继续使用原逻辑。
- 新增 `bmp_source_reader`、`bmp_fat_reader`，并将 FAT32 扫描器、文件流读取器、SD 扇区适配器加入 GUI `.al` 工程源文件列表。FAT32 卷缓存目录项中的簇号/文件大小，文件读取按 FAT 链跨簇推进，支持非连续图片数据；根目录查找可跨扇区和簇，读取错误和超时传回播放器的原重试流程。卷参数随图片目录保留，SD 局部复位后可继续重试。
- FAT32 图片放在根目录，选择目录顺序前四个扩展名为 BMP 的普通文件（8.3 扩展名为大写 `BMP`，不强制 `PIC1～4` 名称），解析 640×480、24 位、未压缩 BMP，按原 BGR 顺序送出 RGB 数据，跳过行填充。支持扇区大小 512 字节、每簇 1～128 个扇区；簇链读取最多 8192 个簇。只读取根目录，不递归子目录。非 FAT32 旧卡自动回到原始连续扇区扫描/读取方式，发现首图后仍暂停扫描、优先加载。
- TD 6.2.168116 从当前源代码完成综合、布局布线与 bit 生成，无编译错误或新增模块黑盒；此次按用户要求未运行仿真，未进行板上验证，编译成功不代表功能已实测。
- 下载文件 `td_build/player_fixed.bit` 更新于 2026-10-08 20:22:39，大小 629624 字节，SHA256 为 `1CD4D1DF0ED3C7D22F37B3C8DDA9BE7FE50CCE61480EF999AEC1CB975531280C`。最终 setup WNS 为 -6.565 ns（SD 域 -1.348 ns），hold WNS 为 +0.032 ns；原有建立时序违例、约束警告及 SDRAM 局部时钟布线警告仍存在，不能视为全工程时序通过。详情见 `td_build/player_fixed_pr.timing`。

2026-10-08 20:37 仲裁成功判断更新（基于当前直接实例化 FAT32 扫描器的 `sd_card_bmp.v`）：

- 复位及开始新扫描时清零 `use_streamer`、`scan_success`；扫描器独立完成脉冲 `scan_done_i` 到来后，只有 `scan_resource_valid != 0` 且错误码为成功或资源不齐（允许找到 1～3 张）才切换到流读取。SD 读取失败不切换。使用扫描器脉冲，避免与播放器锁存的 `scan_done` 多驱动。
- 补齐仲裁返回路径；未选中的模块不接收字节有效/完成脉冲，流读取启动和扇区请求均受成功标志控制。补齐当前文件中未驱动的簇号/大小加载参数与目录数量，并复用 `bmp_fat_reader` 提供头部校验、三字节 RGB 组装、SDRAM 请求/应答及完成状态。扫描器输出用 wire 连接，事务读取器与适配器支持 SD 局部复位；按键和四帧缓存控制保持原逻辑。当前使用直接 FAT32 链路，20:22 记录中的原始扇区回退封装未被实例化。
- TD 从源代码完成综合、布局布线和 bit 生成，输出 `td_build/player_fixed.bit`，更新时间 2026-10-08 20:37:32，大小 629624 字节，SHA256 为 `8E7F0E646C3BE275011B94EC974491902C25744F6781E48694F384F51D8A1697`。全局 setup WNS -6.565 ns（SD 域 -0.410 ns），hold WNS +0.102 ns；原有时序和约束警告仍在。按用户要求未仿真，尚未上板验证。

2026-10-08 21:55 BMP 像素流 / media loader 接入（以下记录对应当前实现，取代此前缓冲控制说明）：

- `sd_card_bmp` 移除旧 SDRAM 写端口和双缓冲显示管理，输出 `loader_pixel_valid`、24 位 `loader_pixel_rgb`、`loader_frame_commit`，并按扫描到的有效目录顺序加载最多四张图片。簇号、文件大小、FAT 链读取、失败重试及 SD 局部恢复保留。
- `bmp_fat_reader.ready` 表示空闲，复位、失败和终止时也会置位，不能作为帧提交。新增独立 `frame_commit`：确认完整 307200 像素及文件读取成功后发出脉冲；最后像素与提交同周期时，跨域模块将提交标记延后一周期，保证像素先入队。
- SD 域实际为 100 MHz，存储域为 125 MHz。新增 `media_pixel_cdc`，使用异步 FIFO 按顺序传递开始、RGB、提交和错误标记，加载完成用 toggle 返回 SD 域。`media_frame_loader` 与 `media_frame_reader` 增加 SDRAM 读写仲裁，loader 翻转 BMP 行地址，四张完整图片常驻独立 SDRAM 帧区。
- `media_player_control` 只切换到 `image_complete` 图片；首张成功加载后即可显示，其余后台加载。Key1 下一张（按下消抖 2 ms）；Key2 短按松开启停 3 秒轮播、长按 1 秒上一张。HDMI 时序和音频链路继续连接。
- GUI `.al` 和独立 TD 构建脚本已加入新模块及缺失的 `fifo_prefetch_2` 依赖。TD 6.2.168116 综合、布局布线、bit 生成完成，无端口错误、声明顺序错误或模块黑盒错误。本次没有运行仿真，也没有上板验证。
- 下载文件 `td_build/player_fixed.bit`：生成于 2026-10-08 21:55:38，629624 字节，SHA256 `92FD8DD480507BB4DF19F5AE3E485775F0EA9D0E4C4F6A937626547CF44226D5`。最终 setup WNS -6.565 ns、hold WNS +0.014 ns；SD 同域 setup WNS -1.235 ns，存储同域 setup WNS -2.055 ns。仍有建立时序违例及约束/SDRAM 局部时钟布线警告，不能称为全工程时序通过，详见 `td_build/player_fixed_pr.timing`。
