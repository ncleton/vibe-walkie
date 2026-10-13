using System.Runtime.InteropServices;

namespace VibeWalkie.Companion.Network;

/// <summary>Publication DNS-SD via dnsapi.dll, sans runtime Bonjour tiers.</summary>
public sealed class DnsSdPublisher : IDisposable
{
    private readonly Native.RegisterComplete _callback;
    private Native.Cancel _cancel;
    private nint _instance;
    private nint _request;
    public bool IsPublished { get; private set; }

    public DnsSdPublisher() => _callback = OnRegistered;

    public void Start(string serviceName, ushort port)
    {
        if (_request != 0) return;
        var fullName = $"{serviceName}._viberemote._tcp.local";
        _instance = Native.DnsServiceConstructInstance(fullName, null, 0, 0, port, 0, 0, 0, 0, 0);
        if (_instance == 0) throw new InvalidOperationException("DnsServiceConstructInstance failed");
        var request = new Native.RegisterRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            ServiceInstance = _instance,
            CompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
        };
        _request = Marshal.AllocHGlobal(Marshal.SizeOf<Native.RegisterRequest>());
        Marshal.StructureToPtr(request, _request, false);
        var result = Native.DnsServiceRegister(_request, ref _cancel);
        if (result != 0 && result != 997) throw new InvalidOperationException($"DnsServiceRegister failed: {result}");
    }

    private void OnRegistered(uint status, nint context, nint instance) => IsPublished = status == 0;

    public void Dispose()
    {
        if (_request != 0) Native.DnsServiceRegisterCancel(ref _cancel);
        if (_instance != 0) Native.DnsServiceFreeInstance(_instance);
        if (_request != 0) Marshal.FreeHGlobal(_request);
        _request = _instance = 0;
        IsPublished = false;
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
            public bool UnicastEnabled;
        }
        [StructLayout(LayoutKind.Sequential)] public struct Cancel { public nint Reserved; }
        [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)] public static extern nint DnsServiceConstructInstance(
            string serviceName, string? hostName, nint ipv4, nint ipv6, ushort port, ushort priority, ushort weight,
            uint propertyCount, nint propertyKeys, nint propertyValues);
        [DllImport("dnsapi.dll")] public static extern uint DnsServiceRegister(nint request, ref Cancel cancel);
        [DllImport("dnsapi.dll")] public static extern uint DnsServiceRegisterCancel(ref Cancel cancel);
        [DllImport("dnsapi.dll")] public static extern void DnsServiceFreeInstance(nint instance);
    }
}
