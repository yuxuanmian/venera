import 'package:sqlite3/sqlite3.dart';

Set<String> writeRecoveryRows<T>(
  Database database,
  Map<String, T> rows,
  void Function(T) write,
) {
  final failed = <String>{};
  for (final entry in rows.entries) {
    database.execute('SAVEPOINT recovery_row');
    try {
      write(entry.value);
    } on SqliteException {
      database.execute('ROLLBACK TO recovery_row');
      failed.add(entry.key);
    }
    database.execute('RELEASE recovery_row');
  }
  return failed;
}
