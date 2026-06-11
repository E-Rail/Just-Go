final class SubwayLine: Identifiable {
    var lineID: String
    var id: String { lineID }
    var name: String
    var nameEn: String?
    var colorHex: String
    var cityID: String
    var stations: [Station]

    init(
        lineID: String,
        name: String,
        nameEn: String? = nil,
        colorHex: String,
        cityID: String
    ) {
        self.lineID = lineID
        self.name = name
        self.nameEn = nameEn
        self.colorHex = colorHex
        self.cityID = cityID
        self.stations = []
    }
}
