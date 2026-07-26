using System.IO;
using System.Text.Json;

namespace WooTodo.WindowsApp;

public sealed class AppSettings
{
    private readonly string path;

    private AppSettings(string path) => this.path = path;

    public double BoardLeft { get; set; } = 80;
    public double BoardTop { get; set; } = 80;
    public double BoardWidth { get; set; } = 380;
    public double BoardHeight { get; set; } = 540;
    public double Opacity { get; set; } = 0.92;
    public bool Topmost { get; set; } = true;
    public bool ClickThrough { get; set; }

    public static AppSettings Load(string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "settings.json");
        if (!File.Exists(path)) return new AppSettings(path);
        try
        {
            var loaded = JsonSerializer.Deserialize<AppSettingsData>(File.ReadAllText(path));
            return new AppSettings(path)
            {
                BoardLeft = loaded?.BoardLeft ?? 80,
                BoardTop = loaded?.BoardTop ?? 80,
                BoardWidth = Math.Max(320, loaded?.BoardWidth ?? 380),
                BoardHeight = Math.Max(360, loaded?.BoardHeight ?? 540),
                Opacity = Math.Clamp(loaded?.Opacity ?? 0.92, 0.35, 1),
                Topmost = loaded?.Topmost ?? true,
                ClickThrough = loaded?.ClickThrough ?? false,
            };
        }
        catch (JsonException)
        {
            return new AppSettings(path);
        }
    }

    public void Save()
    {
        var data = new AppSettingsData(BoardLeft, BoardTop, BoardWidth, BoardHeight, Opacity, Topmost, ClickThrough);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, overwrite: true);
    }

    private sealed record AppSettingsData(
        double BoardLeft,
        double BoardTop,
        double BoardWidth,
        double BoardHeight,
        double Opacity,
        bool Topmost,
        bool ClickThrough);
}
