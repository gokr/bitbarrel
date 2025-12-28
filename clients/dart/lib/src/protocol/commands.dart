/// Command byte constants for the BitBarrel protocol
class Command {
  // Prevent instantiation
  Command._();

  // Data operations
  static const int get = 0x01;
  static const int set = 0x02;
  static const int delete = 0x03;
  static const int exists = 0x04;
  static const int count = 0x05;
  static const int listKeys = 0x06;
  static const int ping = 0x09;

  // Query operations
  static const int traverse = 0x20;
  static const int rangeQuery = 0x21;
  static const int prefixQuery = 0x22;
  static const int rangeCount = 0x23;

  // Barrel operations
  static const int createBarrel = 0x10;
  static const int openBarrel = 0x11;
  static const int useBarrel = 0x12;
  static const int closeBarrel = 0x13;
  static const int listBarrels = 0x14;
  static const int dropBarrel = 0x15;
  static const int getBarrelConfig = 0x16;
  static const int setBarrelConfig = 0x17;

  /// All valid command values
  static const Set<int> allValues = {
    get,
    set,
    delete,
    exists,
    count,
    listKeys,
    ping,
    traverse,
    rangeQuery,
    prefixQuery,
    rangeCount,
    createBarrel,
    openBarrel,
    useBarrel,
    closeBarrel,
    listBarrels,
    dropBarrel,
    getBarrelConfig,
    setBarrelConfig,
  };

  /// Check if a byte is a valid command
  static bool isValid(int cmd) => allValues.contains(cmd);
}
