# BitBarrel Web Admin Console

A modern Flutter web admin console for BitBarrel key-value store, providing a user-friendly interface to connect to BitBarrel servers, manage barrels, browse data, and execute queries.

## Features

- **Connection Management**: Connect to BitBarrel servers via WebSocket
- **Barrel Management**: Create, delete, and switch between barrels
- **Data Explorer**: Browse key-value pairs with pagination, search, and CRUD operations
- **Query Interface**: Execute prefix and range queries (CritBit mode only)
- **JSON Visualization**: View formatted JSON with syntax highlighting and collapsible nodes
- **Full CRUD**: Create, read, update, and delete key-value pairs
- **Modern UI**: Clean, minimalist design with responsive layout

## Requirements

- Flutter SDK (>=3.10.0)
- Dart SDK (>=3.0.0)
- BitBarrel server running (default port: 9876)

## Setup

1. **Install Flutter dependencies:**
```bash
flutter pub get
```

2. **Start BitBarrel server** (if not already running):
```bash
cd ..
./bitbarrel --port 9876 serve
```

3. **Run the admin console in development mode:**
```bash
flutter run -d chrome --web-port 8080
```

## Usage

1. Open the admin console at `http://localhost:8080`
2. Enter the server host (default: `localhost`) and port (default: `9876`)
3. Click "Connect"
4. Manage barrels from the dashboard
5. Select a barrel to explore its data

## Project Structure

```
lib/
├── main.dart                      # Application entry point
├── app.dart                       # Root app widget with routing
├── di.dart                        # Dependency injection setup
├── screens/                       # UI screens
│   ├── connection_screen.dart     # Server connection
│   ├── dashboard_screen.dart      # Barrel management
│   ├── barrel_explorer_screen.dart # Data explorer with CRUD
│   └── query_screen.dart          # Prefix/range query interface
├── services/                      # Business logic
│   ├── connection_service.dart    # Connection management
│   ├── barrel_service.dart        # Barrel operations
│   └── data_service.dart          # Data CRUD and query operations
├── models/                        # Data models
│   ├── connection_state.dart      # Connection states
│   ├── barrel.dart                # Barrel model
│   └── key_value_item.dart        # Key-value pair model
├── widgets/                       # Reusable widgets
│   ├── json_viewer.dart           # JSON visualization with syntax highlighting
│   └── key_value_editor.dart      # Key-value create/edit dialog
└── theme/
    └── app_theme.dart             # UI theme configuration
```

## Architecture

The admin console uses:
- **watch_it** for reactive state management
- **get_it** for dependency injection
- **go_router** for navigation
- **Material 3** design with custom theme

State is managed through observable services that update the UI automatically when data changes.

## Building for Production

```bash
flutter build web --release
```

The built application will be in `build/web/` directory.

## Development

Run tests:
```bash
flutter test
```

Analyze code:
```bash
flutter analyze
```

Format code:
```bash
dart format .
```
