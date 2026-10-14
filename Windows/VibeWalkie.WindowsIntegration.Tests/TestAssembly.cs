using Xunit;

// The production server uses one control port and the native tests share the
// real foreground desktop. Isolate their lifetimes rather than changing them.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
