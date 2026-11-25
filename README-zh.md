<p align="center">
  <img src="http://just-go.com.cn/assets/icon.png" width="128" height="128" alt="Just-Go 应用图标">
</p>

<h1 align="center">Just-Go</h1>

<p align="center">
  <strong>在手机上规划地铁出行，地下没信号也能用，不靠猜测。</strong><br>
  面向 iPhone 和 iPad 的轨道交通出行助手，覆盖 53 个城市的轨道网络。
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/jYbwrfAa"><img src="https://img.shields.io/badge/TestFlight-%E5%8A%A0%E5%85%A5%E6%B5%8B%E8%AF%95-0D96F6?logo=apple&logoColor=white" alt="加入 TestFlight 测试"></a>
  <a href="http://just-go.com.cn"><img src="https://img.shields.io/badge/%E5%AE%98%E7%BD%91-just--go.com.cn-2ea44f" alt="官网：just-go.com.cn"></a>
  <img src="https://img.shields.io/badge/iOS-18.0%2B-black?logo=apple&logoColor=white" alt="iOS 18.0 或更高版本">
  <img src="https://img.shields.io/badge/iPhone%20%C2%B7%20iPad-supported-lightgrey?logo=apple" alt="支持 iPhone 和 iPad">
  <a href="LICENSE"><img src="https://img.shields.io/badge/software-GPL--3.0-green" alt="软件许可证：GPL-3.0"></a>
</p>

<p align="center"><a href="README.md">English</a> | 中文</p>

| 地图 | 路线 | 路线详情 | 导航 | 车站 |
| :-: | :-: | :-: | :-: | :-: |
| <img src="http://just-go.com.cn/assets/screenshots/map.png" width="160" alt="地铁地图"> | <img src="http://just-go.com.cn/assets/screenshots/results.png" width="160" alt="路线结果"> | <img src="http://just-go.com.cn/assets/screenshots/detail.png" width="160" alt="路线详情"> | <img src="http://just-go.com.cn/assets/screenshots/guiding.png" width="160" alt="分步导航"> | <img src="http://just-go.com.cn/assets/screenshots/station.png" width="160" alt="车站页面"> |

## 为什么选择 Just-Go

| | |
| --- | --- |
| 🚇 **没有信号也能规划**<br>轨道路线在手机上计算，所用的地铁网络就内置在应用里。 | 🧭 **跟随行程的导航**<br>步骤按位置和时间自动推进，并注明是“已定位”还是“估算”。当前步骤同时显示在锁屏和灵动岛上。 |
| 🚉 **到站之前就了解车站**<br>北京、上海、广州、杭州的首末班车直接来自运营方，北京和上海另有出入口与设施信息；香港提供实时列车、出入口与设施。共 1,686 座车站。 | ♿ **需要时全程无障碍**<br>可要求无障碍通行、需要电梯或避开楼梯，每条路线都会遵循。无障碍数据覆盖 14 个城市的 603 座车站。 |
| 🌙 **不再错过末班车**<br>显示行程最晚何时出发仍能赶上每一班车，并可设置提醒。仅当运营方公布了行程中每一段的首末班车时才显示。 | 🔍 **知道什么，就说什么**<br>缺失的时刻表、车站布局、换乘通道或车门位置会显示为不可用，绝不推测。 |
| 📱 **适配每一块屏幕**<br>支持 iPhone、iPad 和 iPhone Duo，提供 English、简体中文和繁體中文。 | 🔄 **数据始终最新**<br>地铁线网随本仓库 `main` 分支更新，经由中国大陆可用的镜像下载。 |

<p align="center">
  <img src="http://just-go.com.cn/assets/screenshots/ipad.png" height="360" alt="iPad 上的 Just-Go">
  &nbsp;
  <img src="http://just-go.com.cn/assets/screenshots/duo.png" height="360" alt="iPhone Duo 外屏上的 Just-Go">
</p>

## 城市

**53 个城市内置离线地铁网络，车站超过 7,500 座：** 上海、北京、广州、成都、深圳、武汉、重庆、
南京、杭州、西安、香港、天津、苏州、郑州、合肥、青岛、宁波、沈阳、佛山、长沙、台北、长春、
济南、东莞、南昌、福州、昆明、大连、南宁、厦门、贵阳、无锡、高雄、哈尔滨、徐州、石家庄、
太原、呼和浩特、南通、常州、绍兴、温州、芜湖、洛阳、金华、兰州、许昌、乌鲁木齐、桃园、台中、
澳门、台州、滁州。

资阳、湘潭、湘西、鄂州、清远在城市目录中，仅提供官方链接。全部 58 个城市共用一份官方资源目录，
包含 776 个已审核的地图、出行、无障碍和帮助链接。

## Just-Go 不会假装知道的事

Just-Go 不提供站内导航，不宣称提供 3D 车站地图、站内路线、上车车厢、车门位置或换乘通道。换乘时，
它会显示车站和可用的官方运营方链接，并提示以站内标识为准。城市公布出入口时显示出入口。在线路线
服务测得的站台间步行距离只以距离形式给出，而不是一条路径。

## 隐私

- **行程和常用地点只保存在你的设备上。** 没有 Just-Go 账户，也没有 Just-Go 服务器。
- **位置**只在使用 App 期间申请。导航中的行程会在后台继续读取位置，以便修正进度并更新锁屏；
  此期间系统会显示定位指示，行程结束即停止。
- **地点搜索**使用 Apple 地图。
- **规划行程**时，起点和终点会发送给 Apple 地图以获取步行路线。在配置了百度地图密钥的版本中
  （包括 TestFlight 版本），它们还会发送给百度地图以获取票价、换乘距离、首末班车和骑行路线，
  地点搜索也可能经过百度地图。从当前位置出发时，起点就是你的位置。
- **车站详情**：在北京、上海、广州和杭州打开车站详情时，应用会用该站的 ID 直接向运营方请求
  （`www.bjsubway.com`、`m.shmetro.com`、`apis.gzmtr.com`、`www.hzmetro.com`）。最近一次成功
  获取的结果只保存在本机，不参与备份，以“已缓存”标注展示，并可通过“设置 → 清除缓存”删除。
- **香港实时列车**向 `rt.data.gov.hk` 请求，只包含车站和线路代码。
- **数据更新**经由 `cdn.jsdmirror.com`、`cdn.jsdelivr.net` 和 `raw.githubusercontent.com` 检查
  本仓库，最多每六小时一次；低数据模式下和出行途中不会进行，可在“设置 → 公交数据”中关闭。
- **运营方网页和文件**只在你点按后打开，查看器不保留任何内容。
- 应用链接到 Just-Go 网站上的[隐私政策](http://just-go.com.cn/privacy/)和
  [服务条款](http://just-go.com.cn/terms/)。

## 开发者

<details>
<summary><strong>从源码构建</strong></summary>

1. 克隆仓库。
2. 用 Xcode 26 或更新版本打开 `Just-Go.xcodeproj`。应用在运行时检查后调用 iOS 26 SDK 的玻璃
   效果，因此仍可在 iOS 18 上运行，但编译需要该 SDK。
3. 构建 `Just-Go` scheme。

百度地图增强为可选功能。在不纳入版本控制的 `Just-Go/Config/Secrets.xcconfig` 中填写
`BAIDU_MAPS_SECRET_AK` 和 `BAIDU_MAPS_SECRET_SK`；不填写时，应用离线规划所有路线，只是不显示票价。

项目没有 Xcode 测试目标。质量关卡是 `Scripts/` 下的 Ruby 和 shell 测试、各项校验器，以及 Debug
和 Release 两次构建；`.github/workflows/ci.yml` 会全部运行。

</details>

<details>
<summary><strong>数据更新</strong></summary>

应用会让地铁线网和城市数据包与本仓库 `main` 分支保持一致（设置 → 公交数据 → 更新）：可手动检查，
也可自动检查，自动检查最多每六小时一次，低数据模式下或出行途中不会进行。`DataPacks/manifest.json`
列出每个线网和数据包的大小与 SHA-256；只有哈希与正在使用的数据不同时才下载，同一城市的两份文件
互相校验后一起安装，否则都不安装。应用本身更新后，已下载的数据会被清除。

数据来自 `Just-Go/Config/*.xcconfig` 中的三个来源，按顺序尝试：中国大陆 jsDelivr 镜像、jsDelivr 和
`raw.githubusercontent.com`，均提供 `main` 分支的文件。`Scripts/validate_runtime_data_policy.rb`
按值锁定这三个来源。Wikimedia 永远不会作为来源。

使用仓库中已经审核并固化的输入重新生成和验证数据：

```sh
ruby Scripts/generate_city_pack_manifest.rb
ruby Scripts/import_beijing_station_information.rb --refresh
ruby Scripts/generate_official_transit_resources.rb
ruby Scripts/generate_universal_city_data.rb
ruby Scripts/validate_data_rights.rb
ruby Scripts/validate_city_packs.rb
ruby Scripts/validate_official_transit_resources.rb
ruby Scripts/validate_universal_city_data.rb
```

</details>

<details>
<summary><strong>各城市无障碍数据覆盖</strong></summary>

数据来自各城市自己的公开数据，数量锁定在 `Scripts/lib/oss_data_validators.rb` 中。

| 城市 | 网络车站 | 含无障碍数据 |
| --- | ---: | ---: |
| 西安 | 263 | 167 |
| 台北 | 152 | 119 |
| 香港 | 243 | 98 |
| 上海 | 471 | 57 |
| 北京 | 452 | 43 |
| 广州 | 434 | 41 |
| 深圳 | 380 | 29 |
| 南京 | 281 | 11 |
| 杭州 | 270 | 11 |
| 成都 | 403 | 10 |
| 武汉 | 359 | 7 |
| 天津 | 240 | 5 |
| 重庆 | 300 | 3 |
| 苏州 | 235 | 2 |

其余城市的车站数据处于来源待接入状态。轨道路线由内置地铁网络计算，不依赖任何城市数据包。

</details>

<details>
<summary><strong>车站信息与官方资源</strong></summary>

车站详情只保留三个紧凑信息类别。打开详情时，应用直接向运营方请求：北京（422 座车站）和上海
（415 座）提供首末班车、出入口和设施，广州（428 座）和杭州（259 座）提供首末班车。核对返回的
车站身份后以原生列表显示，使用临时会话、1 MB 上限和五分钟内存缓存。这些接口都不是已发布的公共
API，也未找到兼容的内容重用许可，因此内容只在乘客设备上获取、从不再分发，正式发布前仍需运营方
许可或法律审核。精确官方车站页面仍作为应用内来源和后备入口。应用遵循的接口约定发布在
[StationInfoAPI/](StationInfoAPI/README.md)。

香港全部 162 个车站使用相同的三类别结构，以政府官方实时 API 的实时列车代替首末班车；出入口和设施
来自内置的 DATA.GOV.HK 无障碍快照，并保留已核实的“不可用”状态。香港还提供来自港铁官方索引的
1 张系统图、98 张位置图、98 张车站布局图和 14 张轻铁街道图。

北京全部 450 个规范车站都有明确的车站信息审核状态：424 个拥有精确页面，18 个提供线路或运营方的
官方背景资料，3 个尚未开放客运，5 个不再是当前客运停靠点。

官方资源目录独立于城市数据包：43 个城市至少包含一个已核实官方资源，15 个城市保留带日期的
“未找到已核实资源”审核结果。这些链接不计入内置地图、离线内容或已核实换乘指引。已审核的网页、
PDF 和图片只在点按后于 Just-Go 内打开：网页使用不持久化的 WebKit 会话，文件使用上限为 50 MB 的
纯内存查看器。

</details>

<details>
<summary><strong>数据格式、来源与授权</strong></summary>

- [统一城市数据格式](DataPacks/UNIVERSAL_FORMAT.md)：[`DataPacks/universal/`](DataPacks/universal/)
  以同一套带版本号和完整性索引的 JSON 结构发布全部 58 个城市。
- 地铁网络来自 OpenStreetMap，按 ODbL 1.0 单独署名；香港数据来自 DATA.GOV.HK 并适用其重用条款；
  台北数据来自 data.taipei，适用台湾政府资料开放授权条款（OGDL-TW）。北京、上海、广州和杭州的
  运营方内容仅限链接，从不提交入库。
- 数据结构、来源、校验和和授权说明见 [DataPacks/README.md](DataPacks/README.md)、
  [DataPacks/RIGHTS.md](DataPacks/RIGHTS.md) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

</details>

## 许可证

Just-Go 原创软件源代码采用 GPL-3.0 许可证。第三方数据和媒体不包含在 GPL-3.0 授权中，其条款记录在
`DataPacks/rights_inventory.json` 和 `THIRD_PARTY_NOTICES.md`。
