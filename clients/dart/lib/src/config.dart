/// Client configuration for BitBarrel connection
class BitBarrelConfig {
  /// Server hostname or IP address
  final String host;

  /// Server port
  final int port;

  /// Connection timeout duration
  final Duration connectTimeout;

  /// Request timeout duration
  final Duration requestTimeout;

  /// WebSocket URI path (default: '/ws')
  final String path;

  const BitBarrelConfig({
    required this.host,
    required this.port,
    this.connectTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 3),
    this.path = '/ws',
  });

  /// Creates a WebSocket URI from the configuration
  Uri get uri => Uri(
        scheme: 'ws',
        host: host,
        port: port,
        path: path,
      );

  /// Default configuration for localhost:9876
  factory BitBarrelConfig.localhost() => const BitBarrelConfig(
        host: 'localhost',
        port: 9876,
      );
}
