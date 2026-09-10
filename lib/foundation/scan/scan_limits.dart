/// All resource limits for the debug scan kernel live here.
///
/// Keeping the limits in one value object makes the production defaults
/// auditable and lets unit tests exercise the same code with deliberately
/// smaller bounds.
class ScanLimits {
  const ScanLimits({
    this.maxWorkers = 4,
    this.maxWorksPerSource = 2,
    this.workQueueCapacity = 32,
    this.requestTimeout = const Duration(seconds: 30),
    this.jsCallTimeout = const Duration(seconds: 90),
    this.maxScanResponseBytes = 4 * 1024 * 1024,
    this.maxPageItems = 256,
    this.maxPageJsonBytes = 2 * 1024 * 1024,
    this.maxCursorJsonBytes = 8 * 1024,
    this.maxCursorDepth = 8,
    this.maxPagesPerScope = 4096,
    this.maxItemsPerScope = 100000,
    this.maxIdScalars = 1024,
    this.maxFailureMessageBytes = 2048,
    this.maxSourceCodeBytes = 256,
    this.maxExceptionTypeBytes = 128,
    this.maxFailureJsonBytes = 4096,
    this.maxObservationJsonBytes = 32768,
  });

  static const safeIntegerMax = 9007199254740991;

  final int maxWorkers;
  final int maxWorksPerSource;
  final int workQueueCapacity;
  final Duration requestTimeout;
  final Duration jsCallTimeout;
  final int maxScanResponseBytes;
  final int maxPageItems;
  final int maxPageJsonBytes;
  final int maxCursorJsonBytes;
  final int maxCursorDepth;
  final int maxPagesPerScope;
  final int maxItemsPerScope;
  final int maxIdScalars;
  final int maxFailureMessageBytes;
  final int maxSourceCodeBytes;
  final int maxExceptionTypeBytes;
  final int maxFailureJsonBytes;
  final int maxObservationJsonBytes;

  void validate() {
    if (maxWorkers < 1 ||
        maxWorksPerSource < 1 ||
        workQueueCapacity < 1 ||
        requestTimeout <= Duration.zero ||
        jsCallTimeout <= Duration.zero ||
        maxScanResponseBytes < 1 ||
        maxPageItems < 1 ||
        maxPageJsonBytes < 1 ||
        maxCursorJsonBytes < 1 ||
        maxCursorDepth < 1 ||
        maxPagesPerScope < 1 ||
        maxItemsPerScope < 1 ||
        maxIdScalars < 1 ||
        maxFailureMessageBytes < 1 ||
        maxSourceCodeBytes < 1 ||
        maxExceptionTypeBytes < 1 ||
        maxFailureJsonBytes < 1 ||
        maxObservationJsonBytes < 1) {
      throw ArgumentError('scan limits must be positive');
    }
  }
}
