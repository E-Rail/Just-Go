# JustGo

An accessible subway navigation app for China. The goal is simple: riders with mobility, vision, hearing, cognitive, or mixed needs should be able to see the station, route, schedule, and access information they need before they travel.

## Features

- **Accessibility-First Design**: Mobility, vision, hearing, cognitive, and mixed-needs preferences
- **Glass UI**: Modern SwiftUI material-based interface
- **AMap Integration**: High-quality China subway data and routing
- **Apple Map Rendering**: Native MapKit display with AMap transit data overlays
- **Transit Data**: Metro city lists, station search, line geometry, and public transit route plans from AMap Web APIs
- **Official City Packs**: Downloadable official station accessibility, first/last train schedules, station images, and station status where public sources exist
- **Transit Route Modes**: Fastest and least-walking public transportation plans
- **Clear Data States**: The app labels official schedules, AMap routing data, unavailable live countdowns, and unverified accessibility instead of pretending missing data is known

## Requirements

- iOS 17.0+
- iPadOS 17.0+
- Xcode 16.0+
- Swift 5.9+

## Setup

1. Clone the repository
2. Open `JustGo.xcworkspace` in Xcode
3. Add your AMap Web Service API key to a local, untracked `JustGo/Config/Secrets.xcconfig` file:
   `AMAP_SECRET_API_KEY = your_web_service_key`
4. In the AMap console, make sure the key has access to the advanced `公交信息查询` API if you want first/last train schedule lookup
5. Optional: add `CITY_PACK_SECRET_BASE_URL = your_public_static_data_url` to `JustGo/Config/Secrets.xcconfig` to use your own city-pack host
6. The app falls back to jsDelivr's GitHub CDN for development and beta testing
7. Build and run

The app uses AMap Web APIs, not the native AMap iOS SDK, so it works on iOS simulators without vendor frameworks.
If `AMAP_API_KEY` is empty, the bundled subway data still loads, but live place search, route planning, and AMap schedule lookup are disabled.
Rich station accessibility, official schedules, and station-map assets are downloaded per city pack when a city is opened; they are not bundled into the app binary.
See `DataPacks/README.md` for the city-pack hosting contract.

## Architecture

The app follows Clean Architecture with MVVM:

- **Models**: SwiftData models for stations, routes, and accessibility data
- **Services**: AMap Web API integration, location, accessibility, transit data
- **ViewModels**: Business logic and state management
- **Views**: SwiftUI with glass UI components

## Supported Cities

JustGo bundles baseline subway data for every city exposed by AMap's subway feed, currently 58 cities and more than 7,000 stations. Rich official data lives in downloadable city packs with explicit capability states per city, so unsupported cities show a clear source-pending state instead of blank station detail cards.

## Accessibility Features

### Mobility
- Wheelchair-accessible route planning
- Elevator status tracking
- Step-free navigation

### Visual Impairment
- VoiceOver support
- Audio navigation
- Tactile path information

### Hearing Impairment
- Visual announcements
- Vibration alerts
- Flash notifications

### Cognitive
- Simplified UI mode
- Step-by-step guidance
- Clear visual hierarchy

## License

MIT License - see LICENSE file
