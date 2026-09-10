/// Public bridge types for the optional debug scan capability.
///
/// The implementation lives with the scan kernel.  This forwarding library
/// keeps the source package's API discoverable without creating a second
/// source registry or runtime.
library;

export '../scan/source_adapter.dart'
    show
        ScanCapabilities,
        ScanCapabilitiesState,
        ScanCapability,
        ScanCollectionLoader,
        ScanComicLoader,
        ScanHostRequest,
        ScanHostRequestException,
        ScanHostRequestFactory,
        ScanHttpRequest,
        ScanHttpResponse,
        ScanSourceAdapter;
