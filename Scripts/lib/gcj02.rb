# frozen_string_literal: true

# WGS-84 → GCJ-02 conversion, shared by every importer that writes coordinates into the app.
#
# Apple's basemap uses GCJ-02 across the whole of Greater China — the mainland, Hong Kong, Macau
# and Taiwan alike — so anything the app draws or measures against must be converted. Mixing
# frames within one city is the failure this module exists to prevent: an unconverted coordinate
# lands roughly 600 m from its converted neighbours.
module GCJ02
  A = 6_378_245.0
  EE = 0.006_693_421_622_965_943
  PI = Math::PI

  module_function

  # The obfuscation is only defined over China's bounding region; outside it the identity is
  # correct and applying the polynomial would introduce error.
  def outside_china?(latitude, longitude)
    longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
  end

  def transform_latitude(x, y)
    -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(x.abs) +
      (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3 +
      (20 * Math.sin(y * PI) + 40 * Math.sin(y / 3 * PI)) * 2 / 3 +
      (160 * Math.sin(y / 12 * PI) + 320 * Math.sin(y * PI / 30)) * 2 / 3
  end

  def transform_longitude(x, y)
    300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(x.abs) +
      (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3 +
      (20 * Math.sin(x * PI) + 40 * Math.sin(x / 3 * PI)) * 2 / 3 +
      (150 * Math.sin(x / 12 * PI) + 300 * Math.sin(x / 30 * PI)) * 2 / 3
  end

  def from_wgs84(latitude, longitude)
    return [latitude, longitude] if outside_china?(latitude, longitude)

    delta_latitude = transform_latitude(longitude - 105, latitude - 35)
    delta_longitude = transform_longitude(longitude - 105, latitude - 35)
    radians = latitude / 180 * PI
    magic = 1 - EE * Math.sin(radians)**2
    sqrt_magic = Math.sqrt(magic)
    delta_latitude = delta_latitude * 180 / ((A * (1 - EE)) / (magic * sqrt_magic) * PI)
    delta_longitude = delta_longitude * 180 / (A / sqrt_magic * Math.cos(radians) * PI)
    [latitude + delta_latitude, longitude + delta_longitude]
  end
end
