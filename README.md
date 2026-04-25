# JustGo

An accessible subway navigation app for China, designed with accessibility-first principles.

## Features

- **Accessibility-First Design**: Full support for mobility, visual, hearing, and cognitive disabilities
- **Glass UI**: Modern SwiftUI material-based interface
- **AMap Integration**: High-quality China subway data and routing
- **Offline Mode**: Downloadable city packs for underground use
- **Real-Time Updates**: Live train arrivals and service alerts
- **Voice Navigation**: Turn-by-turn audio guidance for blind users
- **Visual Alerts**: Flash and vibration alerts for deaf users

## Requirements

- iOS 17.0+
- iPadOS 17.0+
- Xcode 16.0+
- Swift 5.9+

## Setup

1. Clone the repository
2. Open `JustGo.xcodeproj` in Xcode
3. Add your AMap API key to the `AMapAPIKey` value in `JustGo/JustGo-Info.plist`
4. Build and run

## Architecture

The app follows Clean Architecture with MVVM:

- **Models**: SwiftData models for stations, routes, and accessibility data
- **Services**: AMap integration, location, accessibility, offline data
- **ViewModels**: Business logic and state management
- **Views**: SwiftUI with glass UI components

## Supported Cities

- Beijing (北京)
- Shanghai (上海)
- Guangzhou (广州)
- Shenzhen (深圳)
- Chengdu (成都)
- Hangzhou (杭州)
- Wuhan (武汉)
- Nanjing (南京)

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
