# frozen_string_literal: true

module OfficialTransitCityReviews
  VERIFIED_AT = "2026-07-15"

  # Each resource tuple is: kind, title, target URL, provider, optional source-page URL.
  # Root pages are retained only when they contain rider information or are the operator's
  # passenger-facing entry point. A blank resource list is an explicit dated review result.
  CITY_REVIEWS = [
    ["1100", "北京", "Beijing", "北京", [
      ["operatorInformation", "Beijing Subway passenger information", "https://www.bjsubway.com/station/xltcx/", "Beijing Subway"],
      ["operatorInformation", "Beijing MTR passenger information", "https://www.mtr.bj.cn/service/line/", "Beijing MTR"]
    ]],
    ["4401", "广州", "Guangzhou", "廣州", [["journeyPlanner", "Guangzhou Metro passenger services", "https://cs.gzmtr.com/ckfw/", "Guangzhou Metro", "https://www.gzmtr.com/"]]],
    ["3100", "上海", "Shanghai", "上海", [["journeyPlanner", "Shanghai Metro passenger services", "https://service.shmetro.com/", "Shanghai Shentong Metro", "https://www.shhqcbd.gov.cn/ywdt/mtjj/593689373274181.html"]]],
    ["1200", "天津", "Tianjin", "天津", [["fareInformation", "Tianjin Rail Transit fare information", "https://www.tjgdjt.com/yunying/content_2256.htm", "Tianjin Rail Transit Group"]]],
    ["5000", "重庆", "Chongqing", "重慶", [["operatorInformation", "Chongqing Rail Transit passenger information", "https://www.cqmetro.cn/", "Chongqing Rail Transit"]]],
    ["2101", "沈阳", "Shenyang", "瀋陽", [["operatorInformation", "Shenyang Metro passenger information", "https://www.symtc.com/", "Shenyang Metro"]]],
    ["3201", "南京", "Nanjing", "南京", [["operatorInformation", "Nanjing public transport information", "https://english.nanjing.gov.cn/LivinginNanjing/Transportation/202405/t20240508_4660988.html", "Nanjing Municipal Government"]]],
    ["4201", "武汉", "Wuhan", "武漢", [["operatorInformation", "Wuhan Metro passenger information", "https://www.wuhanrt.com/", "Wuhan Metro"]]],
    ["5101", "成都", "Chengdu", "成都", [["customerService", "Chengdu Rail Transit passenger assistance", "https://www.chengdurail.com/ckfw/ajbz.htm", "Chengdu Rail Transit"]]],
    ["6101", "西安", "Xi'an", "西安", [["systemMap", "Xi'an rail network information", "https://jtj.xa.gov.cn/zmhd/xxcx/1.html", "Xi'an Municipal Transportation Bureau"]]],
    ["1301", "石家庄", "Shijiazhuang", "石家莊", [["systemMap", "Shijiazhuang Metro routes", "https://www.sjzmetro.cn/service/routes.html", "Shijiazhuang Metro"]]],
    ["1401", "太原", "Taiyuan", "太原", [], "No HTTPS official rider-resource page could be verified for Taiyuan Metro on 2026-07-15."],
    ["4101", "郑州", "Zhengzhou", "鄭州", [["journeyPlanner", "Zhengzhou Metro passenger portal", "https://www.zzmetro.com/portal/", "Zhengzhou Metro"]]],
    ["4103", "洛阳", "Luoyang", "洛陽", [["journeyPlanner", "Luoyang Metro passenger services", "https://www.lysubway.com.cn/service.html", "Luoyang Rail Transit"]]],
    ["4110", "许昌", "Xuchang", "許昌", [["operatorInformation", "Zhengzhou-Xuchang Line passenger information", "https://www.zhengzhou.gov.cn/news1/8107305.jhtml", "Zhengzhou Municipal Government"]]],
    ["5120", "资阳", "Ziyang", "資陽", [["customerService", "Chengdu-Ziyang Line passenger assistance", "https://www.chengdurail.com/ckfw/ajbz.htm", "Chengdu Rail Transit", "https://www.chengdurail.com/gywm.htm"]]],
    ["2102", "大连", "Dalian", "大連", [["journeyPlanner", "Dalian public transport journey query", "https://www.dltransgrp.com/hb-air-web/html/wxgo/query.jsp", "Dalian Public Transport Construction and Investment Group"]]],
    ["2201", "长春", "Changchun", "長春", [], "No HTTPS official rider-resource page could be verified for Changchun Rail Transit on 2026-07-15."],
    ["2301", "哈尔滨", "Harbin", "哈爾濱", [], "No HTTPS official rider-resource page could be verified for Harbin Metro on 2026-07-15."],
    ["1501", "呼和浩特", "Hohhot", "呼和浩特", [["operatorInformation", "Hohhot Metro passenger information", "https://www.hhhtmetro.com/", "Hohhot Metro"]]],
    ["3202", "无锡", "Wuxi", "無錫", [], "No HTTPS official rider-resource page could be verified for Wuxi Metro on 2026-07-15."],
    ["3205", "苏州", "Suzhou", "蘇州", [["operatorInformation", "Suzhou Rail Transit passenger information", "https://www.sz-mtr.com/", "Suzhou Rail Transit"]]],
    ["3203", "徐州", "Xuzhou", "徐州", [["journeyPlanner", "Xuzhou Metro passenger query", "https://www.xzdtjt.com/", "Xuzhou Metro"]]],
    ["3204", "常州", "Changzhou", "常州", [["systemMap", "Changzhou Metro passenger information", "https://cweb.czmetro.net.cn/", "Changzhou Metro"]]],
    ["3701", "济南", "Jinan", "濟南", [
      ["fareInformation", "Jinan Metro fare and ticket rules", "https://www.jinan.gov.cn/col/col118356/art/2026/art_400e5952d76847d0b988287943ae2647.html", "Jinan Municipal Government"],
      ["stationFacilities", "Jinan Metro station facilities", "https://www.jinan.gov.cn/col/col118356/art/2026/art_24327a304b1648be8c66f81cc840a870.html", "Jinan Municipal Government"]
    ]],
    ["3702", "青岛", "Qingdao", "青島", [["operatorInformation", "Qingdao Metro passenger information", "https://www.qd-metro.com/", "Qingdao Metro"]]],
    ["3401", "合肥", "Hefei", "合肥", [], "No specific HTTPS official rider-resource page could be verified for Hefei Rail Transit on 2026-07-15."],
    ["3402", "芜湖", "Wuhu", "蕪湖", [["operatorInformation", "Wuhu Rail Transit passenger information", "https://www.wuhurailtransit.com/", "Wuhu Yunda Rail Transit"]]],
    ["3411", "滁州", "Chuzhou", "滁州", [], "No HTTPS official rider-resource page could be verified for the Chuzhou rail service on 2026-07-15."],
    ["3301", "杭州", "Hangzhou", "杭州", [["systemMap", "Hangzhou Metro network map", "https://www.hzmetro.com/map.aspx", "Hangzhou Metro"]]],
    ["3302", "宁波", "Ningbo", "寧波", [["operatorInformation", "Ningbo Rail Transit passenger information", "https://www.nbmetro.com/", "Ningbo Rail Transit"]]],
    ["3306", "绍兴", "Shaoxing", "紹興", [["journeyPlanner", "Shaoxing Metro passenger services", "https://www.sxsmtr.com/index.php?a=show&c=index&catid=61&id=594&m=content", "Shaoxing Rail Transit Group"]]],
    ["3303", "温州", "Wenzhou", "溫州", [], "No HTTPS official rider-resource page could be verified for Wenzhou Rail Transit on 2026-07-15."],
    ["3307", "金华", "Jinhua", "金華", [], "No HTTPS operator passenger page could be verified for Jinhua Rail Transit on 2026-07-15."],
    ["3310", "台州", "Taizhou", "台州", [["journeyPlanner", "Taizhou Rail Transit journey query", "https://www.tz-mtr.com/operation-service/search/", "Taizhou Rail Transit", "https://www.tz-mtr.com/"]]],
    ["3501", "福州", "Fuzhou", "福州", [], "The reviewed Fuzhou Metro rider page was HTTP-only, so no HTTPS resource was accepted on 2026-07-15."],
    ["3502", "厦门", "Xiamen", "廈門", [
      ["systemMap", "Xiamen Metro stations and lines", "https://www.xmgdjt.com.cn/Modules/ControlHtml/MetroOperation.aspx?SelectedTitle=%E7%AB%99%E7%82%B9%E7%BA%BF%E8%B7%AF", "Xiamen Rail Transit Group", "https://www.xmgdjt.com.cn/HTML/7b4b6733-4823-4587-b5f5-b7ae87dc5544.html"],
      ["fareInformation", "Xiamen Metro fare table", "https://www.xmgdjt.com.cn/Modules/ControlHtml/MetroOperation.aspx?SelectedTitle=%E7%A5%A8%E4%BB%B7%E8%A1%A8", "Xiamen Rail Transit Group", "https://www.xmgdjt.com.cn/HTML/7b4b6733-4823-4587-b5f5-b7ae87dc5544.html"],
      ["customerService", "Xiamen Metro lost property", "https://www.xmgdjt.com.cn/Modules/ControlHtml/MetroOperation.aspx?SelectedTitle=%E5%A4%B1%E7%89%A9%E6%8B%9B%E9%A2%86", "Xiamen Rail Transit Group", "https://www.xmgdjt.com.cn/HTML/7b4b6733-4823-4587-b5f5-b7ae87dc5544.html"]
    ]],
    ["4301", "长沙", "Changsha", "長沙", [["journeyPlanner", "Changsha Metro passenger portal", "https://opp.hncsmtr.com/", "Changsha Metro"]]],
    ["4303", "湘潭", "Xiangtan", "湘潭", [["systemMap", "Changsha-Xiangtan West Ring Line station information", "https://www.hncsmtr.com/webapp/dt/stationAroundInfo.jsp", "Changsha Metro", "https://www.hncsmtr.com/webfiles/905/918/index.jsp?jsp.desc=false&jsp.offset=0"]]],
    ["4331", "湘西", "Xiangxi", "湘西", [], "No HTTPS official rider-resource page could be verified for the Xiangxi Maglev service on 2026-07-15."],
    ["4403", "深圳", "Shenzhen", "深圳", [
      ["systemMap", "Shenzhen rail network information", "https://jtys.sz.gov.cn/ydmh/jtcx/dtcx_180970/dtxl/content/post_12601090.html", "Shenzhen Municipal Transport Bureau"],
      ["journeyPlanner", "Shenzhen Metro passenger services", "https://www.szmc.net/shentieyunying/yunyingfuwu/", "Shenzhen Metro", "https://www.szmc.net/"],
      ["operatorInformation", "MTR Shenzhen passenger information", "https://www.mtrsz.com.cn/frontend/default/src/channel/index.html", "MTR Shenzhen"]
    ]],
    ["4406", "佛山", "Foshan", "佛山", [["stationFacilities", "Foshan Metro station information", "https://www.fmetro.net/xlyy/ckfw/zdxq/gx/content_3535", "Foshan Metro"]]],
    ["4419", "东莞", "Dongguan", "東莞", [], "No HTTPS official rider-resource page could be verified for Dongguan Rail Transit on 2026-07-15."],
    ["4501", "南宁", "Nanning", "南寧", [], "No HTTPS official rider-resource page could be verified for Nanning Rail Transit on 2026-07-15."],
    ["3601", "南昌", "Nanchang", "南昌", [["timetable", "Nanchang Metro operating services", "https://www.ncmtr.com/yyfw_1.html", "Nanchang Rail Transit Group"]]],
    ["5201", "贵阳", "Guiyang", "貴陽", [], "No HTTPS official rider-resource page could be verified for Guiyang Rail Transit on 2026-07-15."],
    ["5301", "昆明", "Kunming", "昆明", [], "No HTTPS official rider-resource page could be verified for Kunming Metro on 2026-07-15."],
    ["6201", "兰州", "Lanzhou", "蘭州", [["journeyPlanner", "Lanzhou Rail Transit passenger services", "https://www.lzgdjt.com/lzgd/serve.jsp", "Lanzhou Rail Transit"]]],
    ["3206", "南通", "Nantong", "南通", [["systemMap", "Nantong Rail Transit passenger services", "https://service.ntrailway.com/", "Nantong Rail Transit"]]],
    ["6501", "乌鲁木齐", "Urumqi", "烏魯木齊", [
      ["fareInformation", "Urumqi Metro fare information", "https://www.urumqimtr.com/pwxx", "Urumqi Metro"],
      ["timetable", "Urumqi Metro timetable", "https://www.urumqimtr.com/lcskb", "Urumqi Metro"],
      ["systemMap", "Urumqi Metro network map", "https://www.urumqimtr.com/dtxlt", "Urumqi Metro"],
      ["serviceStatus", "Urumqi Metro operating notices", "https://www.urumqimtr.com/yygg", "Urumqi Metro"]
    ]],
    ["8100", "香港", "Hong Kong", "香港", [
      ["serviceStatus", "MTR service status", "https://www.mtr.com.hk/en/customer/main/service_status.html", "MTR Corporation Limited"],
      ["journeyPlanner", "MTR journey planner", "https://www.mtr.com.hk/en/customer/jp/index.php", "MTR Corporation Limited"],
      ["timetable", "MTR service hours and first/last trains", "https://www.mtr.com.hk/en/customer/services/train_service_index.html", "MTR Corporation Limited"],
      ["fareInformation", "MTR tickets and fares", "https://www.mtr.com.hk/en/customer/tickets/index.php", "MTR Corporation Limited"],
      ["accessibility", "MTR barrier-free facilities search", "https://www.mtr.com.hk/en/customer/services/free_search.php", "MTR Corporation Limited"],
      ["stationFacilities", "MTR station facilities", "https://www.mtr.com.hk/en/customer/services/more_station_facilities.html", "MTR Corporation Limited"],
      ["customerService", "MTR customer service", "https://www.mtr.com.hk/en/customer/main/contact_us.html", "MTR Corporation Limited"],
      ["operatorInformation", "MTR train services", "https://www.mtr.com.hk/en/customer/services/domestic_train_services.html", "MTR Corporation Limited"]
    ]],
    ["8200", "澳门", "Macau", "澳門", [
      ["journeyPlanner", "Macao LRT routes", "https://www.mlm.com.mo/en/route.html", "Macao Light Rapid Transit Corporation"],
      ["fareInformation", "Macao LRT fares", "https://www.mlm.com.mo/en/general_ticket.html", "Macao Light Rapid Transit Corporation"],
      ["customerService", "Macao LRT customer service", "https://www.mlm.com.mo/en/contact_info.html", "Macao Light Rapid Transit Corporation"]
    ]],
    ["4207", "鄂州", "Ezhou", "鄂州", [], "No HTTPS official rider-resource page could be verified for Ezhou rail service on 2026-07-15."],
    ["4418", "清远", "Qingyuan", "清遠", [
      ["timetable", "Qingyuan Maglev passenger information", "https://www.gdqycf.com/", "Qingyuan Maglev Transport"],
      ["operatorInformation", "Guangzhou-Qingyuan intercity information", "https://www.gz.gov.cn/zwfw/zxfw/jtfw/content/post_10666883.html", "Guangzhou Municipal Government"]
    ]],
    ["7101", "台北", "Taipei", "臺北", [["journeyPlanner", "Taipei Metro route planner", "https://web.metro.taipei/pages2026/WebRoutePlan", "Taipei Rapid Transit Corporation"]]],
    ["7102", "高雄", "Kaohsiung", "高雄", [["operatorInformation", "Kaohsiung Metro passenger information", "https://www.krtc.com.tw/", "Kaohsiung Rapid Transit Corporation"]]],
    ["7106", "桃园", "Taoyuan", "桃園", [
      ["journeyPlanner", "Taoyuan Metro timetable and route planner", "https://www.tymetro.com.tw/tymetro-new/tw/_pages/travel-guide/timetable-search_.php", "Taoyuan Metro Corporation"],
      ["accessibility", "Taoyuan Metro accessible services", "https://www.tymetro.com.tw/tymetro-new/tw/_pages/travel-guide/accessible.html", "Taoyuan Metro Corporation"]
    ]],
    ["7104", "台中", "Taichung", "臺中", [
      ["serviceStatus", "Taichung Metro service information", "https://www.tmrt.com.tw/", "Taichung Mass Rapid Transit Corporation"],
      ["systemMap", "Taichung Metro station information", "https://www.tmrt.com.tw/metro-life/station-information", "Taichung Mass Rapid Transit Corporation"],
      ["accessibility", "Taichung Metro accessible services", "https://www.tmrt.com.tw/our-services/accessibility-service", "Taichung Mass Rapid Transit Corporation"]
    ]]
  ].freeze
end
