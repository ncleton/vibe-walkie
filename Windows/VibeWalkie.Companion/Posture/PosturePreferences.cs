using VibeWalkie.Protocol;
namespace VibeWalkie.Companion.Posture;

public sealed record PosturePreferences(string Sensitivity = "balanced", string? CameraName = null, bool SoundEnabled = true)
{
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeWalkie", "posture-preferences.json");
    public static PosturePreferences Load()
    {
        if (!File.Exists(FilePath)) return new();
        try
        {
            var value = CanonicalJson.Deserialize<PosturePreferences>(File.ReadAllBytes(FilePath));
            if (value.Sensitivity is not ("relaxed" or "balanced" or "strict")) throw new InvalidDataException();
            return value;
        }
        catch (Exception error) { throw new InvalidDataException("Les préférences du coach sont illisibles. Restaurez posture-preferences.json ou réinitialisez-les explicitement.", error); }
    }
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        File.WriteAllBytes(temporary, CanonicalJson.SerializeToUtf8Bytes(this));
        File.Move(temporary, FilePath, overwrite: true);
    }
}
