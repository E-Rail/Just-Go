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
- 面向全部 58 个目录城市的内置官方资源目录，包含 770 个已审核的乘客地图、出行、
  无障碍和帮助链接。
- 两张内置试点照片：Ian Holton 的建国门照片采用 CC BY 2.0，Qqhhss 的香港中环照片采用
  CC0 1.0。
- 从照片或文件导入的私人车站图片，经标准化后仅保存在设备上。

当前内置覆盖如下：

| 城市 | 网络车站 | 已匹配 | 无障碍 | 实时到站 | 外部地图 | 媒体 | 已核实换乘 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 北京 | 444 | 444 | 0 | 0 | 0 | 1 | 0 |
| 香港 | 162 | 162 | 98 | 162 | 0 | 1 | 0 |

其余 56 个城市数据包处于来源待接入状态，其中 44 个城市保留带署名的网络基础数据，12 个仅有目录信息。
轨道路线由内置地铁网络计算，不依赖可选城市数据包；Apple 地图用于地点搜索和步行路段。
应用不会把当前任何城市包描述为可下载内容。

## 官方资源目录

链接目录独立于城市数据包：43 个城市至少包含一个已核实官方资源，15 个城市保留带日期的
“未找到已核实资源”审核结果。770 个链接包括 275 个地图链接、447 个出行链接、6 个无障碍
链接和 42 个帮助链接。这些链接不计入内置地图、离线内容或已核实换乘指引。

北京 444 个应用内规范车站现在全部具有明确的车站信息审核状态。其中 418 个拥有精确页面：
416 个来自北京地铁当前目录、1 个是八角游乐园站保留的旧页面、1 个是 12306 的北京北站官方
车站指南。其余车站中，18 个提供当前线路或运营方的官方背景资料，3 个尚未开放客运，5 个不再
是当前客运停靠点。另有 7 个官方目录中的新车站尚未进入内置 OSM 网络快照，因此不会被静默
绑定到过时或错误的车站 ID。

香港部分来自港铁官方网站索引，包括 1 张系统图、98 张独立位置图、98 张独立车站布局图和
14 张独立轻铁街道图，并包含当前乘客服务页面。澳门的结构化数据仍待接入，但会链接到官方
路线、票价和客户服务页面。

所有资源都只会在乘客点按后于 JustGo 内打开。应用仅保存事实性 URL 元数据：网页使用不保留
网站数据的临时 WebKit 会话，PDF 和图片使用上限为 50 MB 的纯内存原生查看器。北京精确车站
页面会应用手机阅读样式，使首末班车、出入口、周边地点和服务设施适配车站详情流程，无需打开
Safari。JustGo 不会预取、持久化或再分发运营方内容。运营方会收到用户主动发起的请求，并可能
依其政策处理网络信息；无法在应用内显示的非车站资源仍提供由乘客主动选择的浏览器后备入口。
北京精确车站信息只会保留在 JustGo 内，并在失败时提供应用内重试。

北京车站页面遵循同一边界。JustGo 不会调用未公开文档的车站详情 API，不会在打开车站详情时
预取页面，也不会把运营方的时刻、出入口、设施、坐标、图片或正文提取为原生或离线数据。

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
ruby Scripts/import_beijing_station_information.rb --refresh
ruby Scripts/generate_official_transit_resources.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_city_packs.rb
ruby Scripts/validate_official_transit_resources.rb
```

数据结构、来源、校验和和授权说明见 [DataPacks/README.md](DataPacks/README.md)、
[DataPacks/RIGHTS.md](DataPacks/RIGHTS.md) 和
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 隐私与联网

- 私人车站媒体保存在 Application Support 中并排除备份，不会用于推断路线、无障碍、
  站内通道或车门位置。
- 外部运营方资源只会在用户主动操作后通过不持久化的应用内网页或文件查看器显示。JustGo
  不会预取、持久化或再分发这些内容，也不会把它们计入离线内容。运营方会收到该网络请求；不支持
  的下载仍由乘客明确选择是否改用浏览器；北京车站信息页面不提供浏览器后备入口。
- 北京车站页面只会在乘客点按精确匹配的已审核资源后向 `www.bjsubway.com` 发出请求。
  页面内的第三方服务可能收到普通网页请求元数据；JustGo 不会解析或持久化页面内容。
- 香港实时到站请求使用官方线路和车站标识访问 `rt.data.gov.hk`，不会包含私人媒体或
  乘客位置。
- 应用链接到已发布的[隐私政策](https://e-rail.github.io/justgo/docs/privacy/)和
  [服务条款](https://e-rail.github.io/justgo/docs/terms/)。

## 许可证

JustGo 原创软件源代码采用 MIT 许可证。第三方数据和媒体不包含在 MIT 授权中，其条款记录在
`DataPacks/rights_inventory.json` 和 `THIRD_PARTY_NOTICES.md`。
