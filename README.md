# JustGo

An accessible subway navigation app for China, designed with accessibility-first principles.

## Features

- **Accessibility-First Design**: Full support for mobility, visual, hearing, and cognitive disabilities
- **Glass UI**: Modern SwiftUI material-based interface
- **AMap Integration**: High-quality China subway data and routing
- **Apple Map Rendering**: Native MapKit display with AMap transit data overlays
- **AMap Live Transit**: Metro city lists, station search, line geometry, and public transit route plans from AMap Web APIs
- **Transit Route Modes**: Fastest and least-walking public transportation plans
- **Voice Navigation**: Turn-by-turn audio guidance for blind users
- **Visual Alerts**: Flash and vibration alerts for deaf users

## Requirements

- iOS 17.0+
- iPadOS 17.0+
- Xcode 16.0+
- Swift 5.9+

## Setup

1. Clone the repository
2. Open `JustGo.xcworkspace` in Xcode
3. Add your AMap Web API key to the `AMapAPIKey` value in `JustGo/JustGo-Info.plist`
4. Build and run

The app uses AMap Web APIs, not the native AMap iOS SDK, so it works on iOS simulators without vendor frameworks.

## Architecture

The app follows Clean Architecture with MVVM:

- **Models**: SwiftData models for stations, routes, and accessibility data
- **Services**: AMap Web API integration, location, accessibility, transit data
- **ViewModels**: Business logic and state management
- **Views**: SwiftUI with glass UI components

## Supported Cities

JustGo bundles AMap subway data for every city exposed by AMap's subway feed, currently 58 cities and more than 7,000 stations. At runtime it refreshes the selected city from AMap when the network is available, and uses the bundled data as a full offline baseline.

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
