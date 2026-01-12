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
  static const int rangeKeys = 0x24;
  static const int prefixKeys = 0x25;

  // Barrel operations
  static const int createBarrel = 0x10;
  static const int openBarrel = 0x11;
  static const int useBarrel = 0x12;
  static const int closeBarrel = 0x13;
  static const int listBarrels = 0x14;
  static const int dropBarrel = 0x15;
  static const int getBarrelConfig = 0x16;
  static const int setBarrelConfig = 0x17;
  static const int getBarrelStats = 0x18;

  // Pub/Sub operations
  static const int subscribe = 0x40;
  static const int unsubscribe = 0x41;
  static const int publish = 0x42;
  static const int listSubscribers = 0x43;
  static const int history = 0x44;
  static const int listTopics = 0x45;
  static const int presence = 0x46;

  // PubSubEvent push notification
  static const int pubsubEvent = 0xFF;

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
    rangeKeys,
    prefixKeys,
    createBarrel,
    openBarrel,
    useBarrel,
    closeBarrel,
    listBarrels,
    dropBarrel,
    getBarrelConfig,
    setBarrelConfig,
    getBarrelStats,
    subscribe,
    unsubscribe,
    publish,
    listSubscribers,
    history,
    listTopics,
    presence,
    pubsubEvent,
  };

  /// Check if a byte is a valid command
  static bool isValid(int cmd) => allValues.contains(cmd);
}
