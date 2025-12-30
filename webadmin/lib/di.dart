import 'package:get_it/get_it.dart';
import 'package:bitbarrel_admin/services/connection_service.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/services/data_service.dart';

final di = GetIt.instance;

void setupDependencies() {
  // Register services
  di.registerLazySingleton<ConnectionService>(() => ConnectionService());

  di.registerLazySingleton<BarrelService>(
    () => BarrelService(di<ConnectionService>()),
  );

  di.registerLazySingleton<DataService>(
    () => DataService(di<ConnectionService>(), di<BarrelService>()),
  );
}
