using Yazipane.Tests.Support;

namespace Yazipane.Tests.Common;

public sealed class LogTests : IDisposable
{
    private readonly TempDir _temp = new();

    public void Dispose() => _temp.Dispose();

    // ---- Enable / Write ----

    [Fact]
    public void ログを書けない場合も例外を外に出さない()
    {
        // フォルダの代わりにファイルを渡すと、フォルダを作れずログは無効になる
        var file = _temp.File("not-a-dir", "");

        Log.Enable(file, "test");
        Log.Write("message");
    }

    // ---- Prune ----

    [Fact]
    public void Prune_新しいものをkeep件だけ残す()
    {
        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (var i = 0; i < 5; i++)
        {
            _temp.File($@"logs\session{i}\launcher-1.log", "x");
            Directory.SetCreationTimeUtc(_temp.PathOf($@"logs\session{i}"), baseTime.AddMinutes(i));
        }

        Log.Prune(_temp.PathOf("logs"), 2);

        var left = Directory.GetDirectories(_temp.PathOf("logs")).Select(Path.GetFileName).Order().ToList();
        Assert.Equal(["session3", "session4"], left);
    }

    [Fact]
    public void Prune_フォルダが無くても例外を外に出さない()
    {
        Log.Prune(_temp.PathOf("missing"), 2);
    }
}
