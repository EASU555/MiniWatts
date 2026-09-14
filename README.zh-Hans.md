# MiniWatts

[English](README.md) · **简体中文**

[![Build](https://github.com/EASU555/MiniWatts/actions/workflows/build.yml/badge.svg?branch=feature%2Flive-activity)](https://github.com/EASU555/MiniWatts/actions/workflows/build.yml?query=branch%3Afeature%2Flive-activity)

> **个人版 Build 19。** 本仓库衍生自
> [ResistanceTo/MiniWatts](https://github.com/ResistanceTo/MiniWatts)，完整保留原项目署名和
> 许可证。个人版增加了可配置的灵动岛读数、指定部件温度、系统发热状态和画中画悬浮监视器。
> 这些增强功能由本 Fork 独立维护，不代表原作者认可或为其提供支持。

一个用 Apple 私有 API 做的 iPhone 电池与充电信息 app。它读取手机自己的电源管理传感器——也就是 iOS 用来控制充电的那一套——显示充电器正在输出多少、其中有多少真正进到电芯、剩下的以多少热量散掉，以及这期间手机里每一个温度传感器的读数。

| 功率 | 温度 | 充电器 | 历史 |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="功率"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="温度"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="充电器"> | <img src="docs/screenshots/history.jpg" width="200" alt="历史"> |

手动开启实时活动后，无论当前是否连接充电器，都可以在灵动岛和锁定屏幕显示充电功率、
SoC 温度、电池温度或最高部件温度。你可以在设置中选择紧凑状态的主要读数，长按灵动岛
则会同时显示四项。

设置中还增加了需要手动启动的系统画中画悬浮监视器。它把实时数据绘制成视频画面，
每秒刷新一次，可显示充电功率、SoC、电池、充电器和最高部件温度。功率与温度可以独立
开关；两者都开启时，可以同屏显示，也可以分页轮播。悬浮窗口打开期间，画中画后台模式
会维持传感器采样。

Build 19 还会使用静音后台音频会话，尝试在 App 离开前台后继续频繁更新实时活动。实际
调度仍由 iOS 控制，系统可能限制刷新、暂停、移除或最终结束实时活动。持续后台采样会增加
耗电；不再监测时，请关闭实时活动和悬浮监视器。

> **只能自签安装。** 用了私有 API，所以永远上不了 App Store，需要你自己签名安装。它不含任何网络代码：读到的数据不会离开你的手机。

## 安装

从本 Fork 的 [Releases](https://github.com/EASU555/MiniWatts/releases) 下载
`MiniWatts-1.0.1-build19-unsigned.ipa`，用你自己的 Apple ID 签名安装——[Sideloadly](https://sideloadly.io)、
[AltStore](https://altstore.io)、[SideStore](https://sidestore.io) 和 Xcode 都可以。
免费 Apple ID 可用，但应用 7 天后过期，需要重新签名。

运行要求：iPhone，iOS 17 或更高版本。

## 它做不到的事

只能显示 iOS 真正交给沙盒应用的数据。电池健康度和循环次数被从注册表里过滤掉了；配件电量（Watch、AirPods）返回的是空列表；无线充电不暴露输入电流，所以用 MagSafe 时只能看到进入电芯的部分；放电功率没有对应传感器，只能按电量百分比估算。充电暂停只能靠行为推断，推断出来的应用会标注 `inferred`。

## 构建

Xcode 26 或更高版本，iOS 17 部署目标，无第三方依赖。

```bash
./scripts/build-ipa.sh                             # 不签名，Releases 发布的就是这个
TEAM_ID=ABCDE12345 ./scripts/build-ipa.sh signed   # 签名，装自己的设备
```

[`CLAUDE.md`](CLAUDE.md) 是这个项目的工程笔记：沙盒具体封了哪些 API、结论是怎么验证出来的、每个传感器最后查明是什么，以及这个项目已经踩过的 Swift 6 隔离陷阱。

## 许可

Apache 2.0，见 [LICENSE](LICENSE)。读取 PMU 的方法衍生自
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor)（MIT），
`BatteryCenterBridge` 有两处细节参考自 [Batsie](https://github.com/leptos-null/Batsie)。
两者都记录在 [NOTICE](NOTICE) 中，上游的 MIT 声明也逐字保留在那里。

MiniWatts 原始项目版权归 ZhaoHe Studio（2026）所有。个人 Fork 的修改范围记录在
[NOTICE](NOTICE) 和本仓库提交历史中。

私有 API 可能在任何一次 iOS 更新中变化或消失。
