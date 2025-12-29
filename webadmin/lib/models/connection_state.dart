import 'package:equatable/equatable.dart';

/// Represents the state of a connection to BitBarrel server
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class ConnectionState extends Equatable {
  final ConnectionStatus status;
  final String? host;
  final int? port;
  final String? errorMessage;

  const ConnectionState({
    required this.status,
    this.host,
    this.port,
    this.errorMessage,
  });

  factory ConnectionState.disconnected() {
    return const ConnectionState(status: ConnectionStatus.disconnected);
  }

  factory ConnectionState.connecting({required String host, required int port}) {
    return ConnectionState(
      status: ConnectionStatus.connecting,
      host: host,
      port: port,
    );
  }

  factory ConnectionState.connected({required String host, required int port}) {
    return ConnectionState(
      status: ConnectionStatus.connected,
      host: host,
      port: port,
    );
  }

  factory ConnectionState.error({required String errorMessage}) {
    return ConnectionState(
      status: ConnectionStatus.error,
      errorMessage: errorMessage,
    );
  }

  bool get isConnected => status == ConnectionStatus.connected;
  bool get isConnecting => status == ConnectionStatus.connecting;
  bool get hasError => status == ConnectionStatus.error;

  @override
  List<Object?> get props => [status, host, port, errorMessage];
}
