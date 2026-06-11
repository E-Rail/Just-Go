# JustGo

JustGo is a subway confidence app for China. It helps riders understand not only which route to take, but whether that trip will be smooth, understandable, and reliable before they enter the station. JustGo combines routing, official schedules, station maps, accessibility information, exit guidance, and transparent data-source labels so every rider can travel with fewer surprises.

Accessibility is not a separate mode. It is the design standard that makes the app better for everyone: wheelchair users, elderly riders, tourists, people carrying luggage, families, first-time subway users, and daily commuters.

> Maps tell users where to go. JustGo tells users whether the trip will actually work.

## Features

- **Subway Confidence Planning**: See whether a route is likely to be smooth, confusing, walking-heavy, or data-limited before you travel
- **Human-Centered Route Modes**: Fastest, least walking, fewest transfers, least confusing, luggage friendly, elderly friendly, step-free support, and official-data-focused choices
- **Station Intelligence**: Entrances, exits, station maps, schedules, accessibility details, and useful station context
- **Transparent Data Confidence**: Clear labels for official data, Apple Maps route data, estimates, source-pending fields, and unavailable live data
- **Universal Travel Support**: Step-free information, VoiceOver support, clear guidance, and readable UI patterns designed to help everyone
- **MapKit Integration**: Native place search, place-to-place transit routing, walking steps, and exact route geometry
- **Apple Map Rendering**: Native MapKit display with route overlays
- **Official City Packs**: Downloadable city-level official station data where public sources exist

## Requirements

- iOS 17.0+
- iPadOS 17.0+
- Xcode 16.0+
- Swift 5.9+

## Setup

1. Clone the repository
2. Open `JustGo.xcworkspace` in Xcode
3. Optional: add `CITY_PACK_SECRET_BASE_URL = your_public_static_data_url` to `JustGo/Config/Secrets.xcconfig` to use your own city-pack host
4. The app falls back to jsDelivr's GitHub CDN for development and beta testing
5. Build and run

The app uses native MapKit for place search and transit routing, so no paid routing API key is required.
Rich station accessibility, official schedules, and station-map assets are downloaded per city pack when a city is opened; they are not bundled into the app binary.
See `DataPacks/README.md` for the city-pack hosting contract.

## Architecture

The app follows Clean Architecture with MVVM:

- **Models**: SwiftData models for stations, routes, and accessibility data
- **Services**: MapKit providers, official city packs, location, accessibility, and transit confidence
- **ViewModels**: Business logic and state management
- **Views**: SwiftUI with glass UI components

## Supported Cities

MapKit supports place-to-place transit planning wherever Apple Maps provides transit directions. Six cities currently have explicit official-pack choices for richer station facts: Beijing, Shanghai, Guangzhou, Shenzhen, Chengdu, and Hangzhou.

## Universal Travel Support

### Mobility
- Wheelchair-accessible route planning
- Elevator status tracking
- Step-free navigation

### Visual Support
- VoiceOver support
- Tactile path information

### Hearing Support
- Official visual-display information where available

### Clear Guidance
- Human-readable route explanations
- Before-you-go station summaries
- Clear visual hierarchy

## License

MIT License - see LICENSE file
