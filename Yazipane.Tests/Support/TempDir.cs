namespace Yazipane.Tests.Support;

/// <summary>テストごとの一時フォルダ。Dispose で中身ごと消す。</summary>
internal sealed class TempDir : IDisposable
{
    public string Root { get; } = Directory.CreateTempSubdirectory("yazipane-test-").FullName;

    /// <summary>一時フォルダの中のパス（作らない）</summary>
    public string PathOf(string relative) => Path.Combine(Root, relative);

    /// <summary>一時フォルダの中にフォルダを作る</summary>
    public string Dir(string relative) => Directory.CreateDirectory(PathOf(relative)).FullName;

    /// <summary>一時フォルダの中にファイルを書く（途中のフォルダも作る）</summary>
    public string File(string relative, string text)
    {
        var path = PathOf(relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        System.IO.File.WriteAllText(path, text);
        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Root, recursive: true);
        }
        catch (IOException)
        {
            // ほかのプロセスがまだ使っていて消せなければ、OS の一時フォルダの掃除に任せる
        }
    }
}
