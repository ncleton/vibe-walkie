using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace VibeWalkie.Companion.Security;

public sealed class CertificateIdentity
{
    private const string Subject = "CN=Vibe Walkie Companion";
    private const string FriendlyName = "Vibe Walkie TLS";
    private const string KeyName = "VibeWalkie.Companion.TLS.P256";

    public X509Certificate2 LoadOrCreate()
    {
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadWrite);
        var existing = store.Certificates
            .Find(X509FindType.FindBySubjectDistinguishedName, Subject, validOnly: false)
            .OfType<X509Certificate2>()
            .Where(static certificate => certificate.HasPrivateKey && certificate.NotAfter > DateTime.UtcNow)
            .OrderByDescending(static certificate => certificate.NotAfter)
            .FirstOrDefault();
        if (existing is not null) return existing;

        if (store.Certificates.Find(X509FindType.FindBySubjectDistinguishedName, Subject, validOnly: false).Count > 0 || CngKey.Exists(KeyName))
            throw new InvalidOperationException("L’identité TLS existante est expirée ou incomplète. Restaurez son certificat et sa clé, ou réinitialisez explicitement les appairages. Elle ne sera pas remplacée automatiquement.");
        var creation = new CngKeyCreationParameters
        {
            ExportPolicy = CngExportPolicies.None,
            KeyUsage = CngKeyUsages.Signing,
            Provider = CngProvider.MicrosoftSoftwareKeyStorageProvider,
            KeyCreationOptions = CngKeyCreationOptions.None,
        };
        using var key = CngKey.Create(CngAlgorithm.ECDsaP256, KeyName, creation);
        using var algorithm = new ECDsaCng(key) { HashAlgorithm = CngAlgorithm.Sha256 };
        var request = new CertificateRequest(Subject, algorithm, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(5));
        certificate.FriendlyName = FriendlyName;
        store.Add(certificate);
        return certificate;
    }

    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToBase64String(SHA256.HashData(certificate.RawData));
}
