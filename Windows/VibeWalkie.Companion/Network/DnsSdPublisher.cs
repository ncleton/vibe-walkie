using System.Runtime.InteropServices;

namespace VibeWalkie.Companion.Network;

/// <summary>Publication DNS-SD native, confirmée par le callback Windows.</summary>
public sealed class DnsSdPublisher : IAsyncDisposable
{
    private const uint DnsRequestPending = 9506;
    private readonly Native.RegisterComplete _callback;
    private TaskCompletionSource<uint> _operation = NewOperation();
    private GCHandle _lifetime;
    private nint _instance;
    private nint _request;
    private bool _registered;
    public bool IsPublished { get; private set; }

    public DnsSdPublisher() => _callback = OnCompleted;
    private static TaskCompletionSource<uint> NewOperation() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    public async Task StartAsync(string serviceName, ushort port)
    {
        if (_request != 0) throw new InvalidOperationException("Une publication réseau est déjà en cours. Relancez le compagnon.");
        var fullName = $"{serviceName}._viberemote._tcp.local";
        _instance = Native.DnsServiceConstructInstance(fullName, $"{Environment.MachineName}.local", 0, 0, port, 0, 0, 0, 0, 0);
        if (_instance == 0) throw Failure("création", Marshal.GetLastWin32Error());
        var request = new Native.RegisterRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            ServiceInstance = _instance,
            CompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
        };
        _request = Marshal.AllocHGlobal(Marshal.SizeOf<Native.RegisterRequest>());
        Marshal.StructureToPtr(request, _request, false);
        // Keep both the unmanaged request and callback alive through completion.
        // A null cancel handle is documented and avoids a movable managed ref.
        _lifetime = GCHandle.Alloc(this);
        var result = Native.DnsServiceRegister(_request, 0);
        LocalDiagnostics.StartupStage("dns_register_result_" + result);
        if (result != 0 && result != DnsRequestPending)
        {
            ReleaseResources();
            throw Failure("enregistrement", checked((int)result));
        }
        uint status;
        try { status = await _operation.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
        catch (TimeoutException error) { throw new InvalidOperationException("Windows ne confirme pas la publication réseau. Vérifiez le service Client DNS et autorisez Vibe Walkie sur les réseaux privés dans le pare-feu, puis relancez le compagnon.", error); }
        LocalDiagnostics.StartupStage("dns_register_completed_" + status);
        if (status != 0) throw Failure("enregistrement", checked((int)status));
        _registered = IsPublished = true;
    }

    private void OnCompleted(uint status, nint context, nint instance)
    {
        // The callback owns the returned copy, independently of our input.
        if (instance != 0 && instance != _instance) Native.DnsServiceFreeInstance(instance);
        _operation.TrySetResult(status);
    }

    public async ValueTask DisposeAsync()
    {
        if (_request == 0) return;
        IsPublished = false;
        // Never free a request or callback while Windows may still use it.
        var status = await _operation.Task.WaitAsync(TimeSpan.FromSeconds(10));
        _registered |= status == 0;
        if (_registered)
        {
            _operation = NewOperation();
            var result = Native.DnsServiceDeRegister(_request, 0);
            LocalDiagnostics.StartupStage("dns_unregister_result_" + result);
            if (result != 0 && result != DnsRequestPending) throw Failure("retrait", checked((int)result));
            status = await _operation.Task.WaitAsync(TimeSpan.FromSeconds(10));
            LocalDiagnostics.StartupStage("dns_unregister_completed_" + status);
            if (status != 0) throw Failure("retrait", checked((int)status));
        }
        ReleaseResources();
    }

    private static InvalidOperationException Failure(string operation, int status) => new(
        $"Publication réseau Windows impossible ({operation}, code {status}). Vérifiez le service Client DNS et autorisez Vibe Walkie sur les réseaux privés dans le pare-feu, puis relancez le compagnon.");

    private void ReleaseResources()
    {
        if (_instance != 0) Native.DnsServiceFreeInstance(_instance);
        if (_request != 0) Marshal.FreeHGlobal(_request);
        _request = _instance = 0;
        _registered = IsPublished = false;
        if (_lifetime.IsAllocated) _lifetime.Free();
    }

    private static class Native
    {
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate void RegisterComplete(uint status, nint context, nint instance);
        [StructLayout(LayoutKind.Sequential)] public struct RegisterRequest
        {
            public uint Version;
            public uint InterfaceIndex;
            public nint ServiceInstance;
            public nint CompletionCallback;
            public nint QueryContext;
            public nint Credentials;
            [MarshalAs(UnmanagedType.Bool)] public bool UnicastEnabled;
        }
        [DllImport("dnsapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)] public static extern nint DnsServiceConstructInstance(
            string serviceName, string hostName, nint ipv4, nint ipv6, ushort port, ushort priority, ushort weight,
            uint propertyCount, nint propertyKeys, nint propertyValues);
        [DllImport("dnsapi.dll", ExactSpelling = true)] public static extern uint DnsServiceRegister(nint request, nint cancel);
        [DllImport("dnsapi.dll", ExactSpelling = true)] public static extern uint DnsServiceDeRegister(nint request, nint cancel);
        [DllImport("dnsapi.dll", ExactSpelling = true)] public static extern void DnsServiceFreeInstance(nint instance);
    }
}
