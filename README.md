# MotoS30侧键魔方 v1.0.3

作者：JIN

Motorola Edge S30（代号 `xpeng`）/ Android 16 专用 KernelSU 模块（模块 id：`xpengsidekey`）。
将**左侧唯一专用侧键**（Smart Key / 一键触达）绑定为单击/双击/长按三种自定义功能，
通过 KernelSU 管理器内置 WebUI 配置，全程 systemless，卸载 100% 复原。

> 实机验证（2026-08，xpeng / SDK 36）：侧键设备 `gpio-keys`，scancode `217`（KEY_SEARCH），
> 同设备另有 KEY_VOLUMEUP(115)；生效 keylayout 为 `/system/usr/keylayout/Generic.kl`。
> 本模块默认值即基于此实测结果。

## 目录结构

```
XpengSideKey/
├── module.prop              模块信息
├── customize.sh             安装校验(xpeng/Android16)、复核按键、生成 overlay
├── post-fs-data.sh          挂载前按配置重生成 keylayout overlay
├── service.sh               启动守护进程
├── uninstall.sh             仅停止守护进程（复原交给 KernelSU）
├── sepolicy.rule            最小 SELinux 规则（su 域读 /dev/input）
├── META-INF/...             Recovery 手动刷入兜底引导
├── webroot/
│   ├── index.html / style.css / app.js    MD3 风格 WebUI（无外部依赖）
│   └── bridge.sh            WebUI <-> shell 桥（白名单动作、b64 参数、JSON 返回）
├── xpengsidekey/            模块私有目录（卸载即删）
│   ├── config.prop          配置（WebUI 读写）
│   ├── daemon.sh            getevent 监听 + 单/双击/长按状态机
│   ├── actions.sh           预设动作执行（多版本回退链）
│   ├── tools.sh             共享函数库/检测/学习/日志轮转
│   └── logs/ run/           日志与运行态
└── system/
    └── usr/keylayout/gpio-keys.kl   keylayout overlay（卸载自动消失）
```

## 快速开始

1. KernelSU 管理器 → 模块 → 从存储安装 `XpengSideKey-v1.0.3.zip` → 重启
2. 管理器 → 模块页找到本模块 → 点「WebUI」按钮打开配置界面
3. 「绑定」页可为 单击/双击/长按 选择功能，保存后即时生效
4. 若按键无响应，用「学习按键」捕获真实键值并保存

## 元模块与挂载（meta module）

新版 KernelSU（含 ResukiSU）将模块挂载能力外包给可选的"元模块"（官方参考实现 `meta-overlayfs`）：

- **未装元模块（纯脚本模式）**：守护进程、单击/双击/长按、预设与自定义命令、WebUI 全部正常；
  仅键位重映射（屏蔽系统默认键行为）休眠不生效。安装时与 WebUI 中均会给出状态提示。
- **装 meta-overlayfs 后**：重启即自动启用键位映射，无需改模块配置
  （post-fs-data.sh 会在 metamount.sh 挂载之前重新生成 overlay）。
- 本模块绝不直写 /system；是否安装元模块由你决定，随时可逆。

## 触发说明

| 触发 | 判定 | 默认绑定 |
|---|---|---|
| 单击 | 松开后 `click_gap_ms`(默认300ms) 内无再次按下 | 微信扫一扫 |
| 双击 | 间隔内两次按下 | 微信付款码 |
| 长按 | 按住超过 `long_press_ms`(默认550ms) | 响铃/振动/静音循环 |

## 预设功能

响铃/振动/静音循环、免打扰开关、截屏、微信扫一扫、微信付款码、
支付宝扫一扫、支付宝付款码、打开相机、语音助手、每触发独立自定义命令，
另有 6 个全局自定义功能槽位（custom_1~6）。

## 备份/还原

- 导出：设置页「导出」→ 文本框 → 复制保存（或另存 .prop 文件）
- 导入：粘贴文本（或选择文件）→「导入」→ 即时生效（键位映射需重启）
- 「恢复默认」仅重置绑定/时序/反馈，保留按键识别与自定义槽位

## 卸载与复原

KernelSU 管理器滑动卸载即可：

- `system/usr/keylayout/gpio-keys.kl` overlay 随模块移除 → 原始 Generic.kl 无损生效
- 配置/日志/守护进程文件全部位于模块目录 → 自动删除
- `uninstall.sh` 仅停止守护进程，无任何系统文件操作
- 守护进程进程随 `daemon.pid` kill，无残留服务

验证复原：

```sh
ls /data/adb/modules/xpengsidekey 2>/dev/null        # 应不存在
pgrep -f xpengsidekey                                # 应无输出
dumpsys input | grep -A2 gpio-keys                   # KeyLayoutFile 应回到 Generic.kl
```

## 故障排查

1. **按键无响应**：WebUI 状态是否「守护运行中」→「学习按键」校准键值 → 绑定页「立即测试」
2. **功能不生效但守护正常**：查看日志（设置页）；微信/支付宝 Activity 路径随版本变化，
   模块自动回退，最终回退为打开应用本体
3. **WebUI 打不开**：确认模块已启用且重启过一次；检查 `webroot/index.html` 存在
4. **双击被识别成两次单击**：增大「单击判定间隔」
5. **诊断**：关于页「运行诊断」一键执行 getevent/dumpsys/kl/avc 检查

## 已知限制

- 未安装元模块时键位重映射处于休眠（见"元模块与挂载"），其余功能不受影响
- 键位映射（屏蔽系统默认行为）修改后需重启手机；其余设置即时生效
- 部分应用限制后台调起时，回退链会退化为“打开应用本体”，属 Android 16 正常行为
- `dmesg` 在 user build 受限，诊断中 avc 输出可能为空（不代表无问题）
- 单击有 `click_gap_ms` 的固有延迟（等待是否构成双击）

## 安全设计

- 全部动作命令仅 root(su) 域执行，不注册广播/Provider，无 HTTP 服务
- WebUI 桥接：动作白名单 + base64 参数 + 配置键白名单 + 值校验
- 敏感自定义命令在 WebUI 执行前二次确认
- 日志按 `log_max_kb`（默认 256KB）自动轮转
