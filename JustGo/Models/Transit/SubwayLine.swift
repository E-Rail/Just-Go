import SwiftData

@Model
final class SubwayLine {
    @Attribute(.unique) var lineID: String
    var name: String
    var nameEn: String?
    var colorHex: String
    var cityID: String
    var sortOrder: Int

    @Relationship(deleteRule: .nullify)
    var stations: [Station]

    init(
        lineID: String,
        name: String,
        nameEn: String? = nil,
        colorHex: String,
        cityID: String,
        sortOrder: Int = 0
    ) {
        self.lineID = lineID
        self.name = name
        self.nameEn = nameEn
        self.colorHex = colorHex
        self.cityID = cityID
        self.sortOrder = sortOrder
        self.stations = []
    }
}
