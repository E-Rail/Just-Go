# JustGo

[![Website](https://img.shields.io/badge/website-e--rail.github.io%2Fjustgo-2ea44f?logo=githubpages&logoColor=white)](https://e-rail.github.io/justgo)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey?logo=apple)](https://e-rail.github.io/justgo)
[![iOS](https://img.shields.io/badge/iOS-18.0%2B-black?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0071e3?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Stars](https://img.shields.io/github/stars/E-Rail/JustGo?style=flat&logo=github)](https://github.com/E-Rail/JustGo/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/E-Rail/JustGo?logo=git&logoColor=white)](https://github.com/E-Rail/JustGo/commits)

**网站：** [e-rail.github.io/justgo](https://e-rail.github.io/justgo)

JustGo 是一款面向中国城市轨道交通的“出行信心”应用。它不只告诉你该坐哪条路线，还会在进站前帮助你判断这趟行程是否顺畅、是否容易理解、是否可靠。JustGo 将路线规划、官方时刻表、车站地图、无障碍信息、出入口指引和透明的数据来源标签结合在一起，让每一次出行少一点意外。

无障碍不是一个单独模式，而是 JustGo 的设计基准。它让轮椅使用者、老年乘客、游客、携带行李的人、带孩子出行的家庭、第一次坐地铁的人和日常通勤者都能获得更清楚、更安心的体验。

> 地图告诉你往哪里走。JustGo 告诉你这趟行程到底能不能顺利完成。

## 功能

- **地铁出行信心规划**：出发前了解路线是否顺畅、是否容易迷路、是否步行较多，或是否存在数据不足
- **以人为中心的路线模式**：最快、少步行、少换乘、少迷路、适合行李、适合老人、无障碍优先，以及官方数据优先等选择
- **车站信息**：出入口、车站地图、时刻表、无障碍详情和实用车站上下文
- **透明的数据可信度**：清楚标注官方数据、Apple 地图路线数据、估算数据、来源待接入字段和不可用的实时数据
- **通用出行支持**：无台阶信息、VoiceOver 支持、清晰指引和易读界面，帮助所有乘客
- **MapKit 集成**：原生地点搜索、点到点公交路线、步行步骤和准确路线几何
- **Apple 地图渲染**：使用原生 MapKit 显示地图和路线覆盖层
- **官方城市数据包**：在有公开官方来源的城市，下载城市级官方车站数据

## 要求

- iOS 18.0+
- iPadOS 18.0+
- Xcode 16.0+
- Swift 5.9+

## 设置

1. 克隆仓库
2. 在 Xcode 中打开 `JustGo.xcworkspace`
3. 可选：在 `JustGo/Config/Secrets.xcconfig` 中添加 `CITY_PACK_SECRET_BASE_URL = your_public_static_data_url`，以使用你自己的城市数据包托管地址
4. 开发和 beta 测试时，应用会回退到 jsDelivr 的 GitHub CDN
5. 构建并运行

应用使用原生 MapKit 进行地点搜索和公交路线规划，因此不需要付费路线 API 密钥。
丰富的车站无障碍信息、官方时刻表和车站地图资源会在打开城市时按城市数据包下载，不会打包进应用二进制文件。
城市数据包托管契约见 `DataPacks/README.md`。

## 架构

应用采用 Clean Architecture 与 MVVM：

- **Models**：车站、路线和无障碍数据的 SwiftData 模型
- **Services**：MapKit 提供方、官方城市数据包、定位、无障碍和出行可信度服务
- **ViewModels**：业务逻辑和状态管理
- **Views**：基于 SwiftUI 和玻璃质感组件的界面

## 支持城市

只要 Apple 地图提供公交路线，MapKit 就可以支持点到点公交规划。当前清单中已有 9 个城市提供官方数据包下载，用于补充更丰富的车站信息：北京、上海、广州、深圳、成都、重庆、西安、苏州和杭州。

## 通用出行支持

### 行动能力
- 轮椅无障碍路线规划
- 电梯状态追踪
- 无台阶导航

### 视觉支持
- VoiceOver 支持
- 盲道信息

### 听觉支持
- 在可用时显示官方视觉提示信息

### 清晰指引
- 易读的路线说明
- 出发前车站摘要
- 清楚的视觉层级

## 许可证

MIT License - 详见 LICENSE 文件
