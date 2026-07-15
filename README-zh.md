# JustGo

[![Website](https://img.shields.io/badge/website-e--rail.github.io%2Fjustgo-2ea44f?logo=githubpages&logoColor=white)](https://e-rail.github.io/justgo)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey?logo=apple)](https://e-rail.github.io/justgo)
[![iOS](https://img.shields.io/badge/iOS-18.0%2B-black?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/software-MIT-green.svg)](LICENSE)

[English](README.md) | 中文

JustGo 是一款面向 iPhone 和 iPad 的轨道交通出行助手，用于路线规划、车站信息和透明的
数据可信度说明。应用结合内置地铁路线、Apple 地图地点搜索与步行路段、带有明确署名的
地铁网络几何，以及范围严格受控
的官方城市数据。缺失的时刻表、车站布局、换乘通道和车门位置会明确显示为不可用，不会推测。

## 内置内容

- Apple 地图地点搜索、步行路线和地图渲染。
- 58 个目录城市，其中 46 个包含按 ODbL 1.0 单独署名和授权的 OpenStreetMap 地铁网络基础数据，
  另有 12 个仅保留城市目录信息。
- 北京和香港两个内置离线城市数据基础包。
- 香港港铁和轻铁的线路、车站、无障碍及实时查询标识，来源为 DATA.GOV.HK，并适用其
  自定义重用条款。
- 通过香港政府交通 API 获取港铁和轻铁实时到站信息，并处理超时、缓存、请求合并和限流。
- 仅在乘客主动点按后打开的官方运营方网页链接。
- 两张内置试点照片：Ian Holton 的建国门照片采用 CC BY 2.0，Qqhhss 的香港中环照片采用
  CC0 1.0。
- 从照片或文件导入的私人车站图片，经标准化后仅保存在设备上。

当前内置覆盖如下：

| 城市 | 网络车站 | 已匹配 | 无障碍 | 实时到站 | 布局链接 | 媒体 | 已核实换乘 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 北京 | 444 | 444 | 0 | 0 | 0 | 1 | 0 |
| 香港 | 162 | 162 | 98 | 162 | 98 | 1 | 0 |

其余 56 个目录城市处于来源待接入状态，其中 44 个保留带署名的网络基础数据，12 个仅有目录信息。
轨道路线由内置地铁网络计算，不依赖可选城市数据包；Apple 地图用于地点搜索和步行路段。
应用不会把当前任何城市包描述为可下载内容。
澳门仍为来源待接入状态，仅提供澳门轻轨官方网站的点击跳转链接。

## 站内指引

应用保留了站内图引擎、检查点扫描、持久化和 Live Go 接入，以便未来承载经核实的数据。
当前版本包含 0 个经核实的换乘上下文，也不宣称提供通用 3D 地图、站内路线、上车车厢、
车门位置或换乘通道。没有经核实指引时，Live Go 会保留普通换乘步骤并明确说明不可用。

## 设置

1. 克隆仓库。
2. 在 Xcode 中打开 `JustGo.xcodeproj`。
3. 构建 `JustGo` scheme。

Release 构建默认只使用内置基础数据；只有配置第一方城市数据源后才会启用远程更新。
Release 不会回退到 GitHub、jsDelivr 或 Wikimedia。Debug 构建可使用明确配置的开发源；
可通过 `CITY_PACK_SECRET_MAINLAND_MIRROR_URL` 配置第一方中国大陆镜像，本仓库默认未配置镜像。

使用仓库中已经审核并固化的输入重新生成和验证数据：

```sh
ruby Scripts/generate_city_pack_manifest.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_city_packs.rb
```

数据结构、来源、校验和和授权说明见 [DataPacks/README.md](DataPacks/README.md)、
[DataPacks/RIGHTS.md](DataPacks/RIGHTS.md) 和
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 隐私与联网

- 私人车站媒体保存在 Application Support 中并排除备份，不会用于推断路线、无障碍、
  站内通道或车门位置。
- 外部运营方资源只会在用户主动操作后打开。JustGo 不会内嵌、预取、缓存这些网页，
  也不会把它们计入离线内容。
- 香港实时到站请求使用官方线路和车站标识访问 `rt.data.gov.hk`，不会包含私人媒体或
  乘客位置。
- 应用链接到已发布的[隐私政策](https://e-rail.github.io/justgo/docs/privacy/)和
  [服务条款](https://e-rail.github.io/justgo/docs/terms/)。

## 许可证

JustGo 原创软件源代码采用 MIT 许可证。第三方数据和媒体不包含在 MIT 授权中，其条款记录在
`DataPacks/rights_inventory.json` 和 `THIRD_PARTY_NOTICES.md`。
