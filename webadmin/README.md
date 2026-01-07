# BitBarrel Web Admin Console

A modern Flutter web admin console for BitBarrel key-value store, providing a user-friendly interface to connect to BitBarrel servers, manage barrels, browse data, and execute queries.

## Features

- **Connection Management**: Connect to BitBarrel servers via WebSocket
- **Barrel Management**: Create, delete, and switch between barrels
- **Data Explorer**: Browse key-value pairs with pagination, search, and CRUD operations
- **Query Interface**: Execute prefix and range queries (CritBit mode only)
- **JSON Visualization**: View formatted JSON with syntax highlighting and collapsible nodes
- **Full CRUD**: Create, read, update, and delete key-value pairs
- **Statistics Dashboard**: View comprehensive barrel statistics and metrics
- **Modern UI**: Clean, minimalist design with responsive layout

## Requirements

- Flutter SDK (>=3.10.0)
- Dart SDK (>=3.0.0)
- BitBarrel server running (default port: 9876)

## Deployment Options

### Option 1: Integrated Server Mode (Recommended for Production)

The webadmin can be served directly from the BitBarrel server at `/admin/`:

```bash
# Build the webadmin for production (uses build.sh for correct base href)
./build.sh

# Start BitBarrel with integrated webadmin
cd ..
./bitbarrel serve --webadmin-path=./webadmin/build/web

# Access at http://localhost:8080/admin/
```

**Advantages:**
- Single port for both API and UI
- No CORS issues
- Simplified deployment (works great with Docker)
- Automatic routing

### Option 2: Separate Development Server

For development, run the webadmin as a separate Flutter development server:

```bash
# Quick start with helper script
./start.sh

# Or manually:
# Install dependencies
flutter pub get

# Run webadmin development server
flutter run -d chrome --web-port 8080

# Access at http://localhost:8080
```

**Note:** In development mode, you'll need a separate BitBarrel server running.

**Advantages:**
- Hot reload for rapid development
- Flutter DevTools integration
- Easy debugging

## Usage

1. **Access the admin console:**
   - Integrated mode: `http://localhost:8080/admin/`
   - Development mode: `http://localhost:8080`

2. **Connect to server:**
   - Enter server host (default: `localhost`)
   - Enter server port (default: `9876` for dev, `8080` for integrated mode)
   - Click "Connect"

3. **Manage your data:**
   - Create, delete, and switch between barrels
   - Browse key-value pairs with pagination
   - Execute prefix and range queries (CritBit mode)
   - View JSON with syntax highlighting

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
│   ├── barrel_stats_screen.dart   # Statistics dashboard
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
