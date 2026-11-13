import 'scan/models.dart';

const _picacgCollectionEvidenceSchema = '{"chapterCount":"epsCount"}';
const _picacgComicEvidenceSchema = '{"updatedAt":"updated_at@day"}';
const _knownPicacgComicRevisions = {'1.0.10', '1.0.11'};

/// Whether a collection observation may persist a 014 schedule recovery input.
///
/// The original per-comic contract remains unchanged.  Collection observations
/// are deliberately narrower: only the known Picacg count-only evidence that
/// introduced the 016 protocol may enter the per-comic recovery marker.
bool isRecoverableScheduleObservation(ScanItemResult result) {
  if (!result.isSuccess || result.observation!.sourceUnread != null) {
    return false;
  }
  if (result.producer == ScanProducer.comic) return true;
  return isPicacgCollectionCountObservation(result);
}

bool isPicacgCollectionCountObservation(ScanItemResult result) =>
    result.producer == ScanProducer.collection &&
    result.sourceKey == 'picacg' &&
    result.evidenceSchema == _picacgCollectionEvidenceSchema;

/// Known per-comic evidence from before or during the 016 rollout.
///
/// Definitions are checked as a version/label pair rather than against the
/// current runtime revision, so an unconsumed 1.0.10 observation survives the
/// switch to the 1.0.11 collection primary.
bool isKnownPicacgComicObservation(ScanItemResult result) =>
    result.producer == ScanProducer.comic &&
    result.sourceKey == 'picacg' &&
    result.evidenceSchema == _picacgComicEvidenceSchema &&
    _knownPicacgComicRevisions.contains(result.definitionRevision);
