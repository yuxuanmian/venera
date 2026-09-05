import 'comparator.dart';

/// Resolves the sticky qualification used by the existing Updates list.
bool resolveHasNewUpdate({
  required bool previousHasNewUpdate,
  required bool? sourceUnread,
  required ContentChange contentChange,
}) {
  if (sourceUnread == true) return true;
  if (sourceUnread == false) return false;
  if (contentChange == ContentChange.changed) return true;
  return previousHasNewUpdate;
}
